require "minitest/autorun"
require "json"
require "socket"
require "namegender"

# A stand-in for the NameGender API: a plain TCPServer on 127.0.0.1 that
# records every request and answers with canned JSON in the current API shape.
class StandInAPI
  Request = Struct.new(:method, :path, :headers, :raw_body, :body)

  attr_reader :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @overrides = {}
    @lock = Mutex.new
    @thread = Thread.new do
      loop do
        socket = @server.accept
        begin
          handle(socket)
        rescue StandardError
          # A broken request must not take the server down for later tests.
        end
      end
    end
    @thread.report_on_exception = false
  end

  def base_url
    "http://127.0.0.1:#{port}/api/v1"
  end

  def requests
    @lock.synchronize { @requests.dup }
  end

  # Replace the response for one path with [status, raw body string].
  def override(path, status, raw)
    @lock.synchronize { @overrides[path] = [status, raw] }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def handle(socket)
    request_line = socket.gets("\r\n") or return
    method, path, = request_line.split(" ")
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      key, value = line.chomp("\r\n").split(":", 2)
      headers[key.downcase] = value.strip
    end
    length = headers["content-length"].to_i
    raw = length.positive? ? socket.read(length).force_encoding(Encoding::UTF_8) : nil
    body = raw && JSON.parse(raw)
    @lock.synchronize { @requests << Request.new(method, path, headers, raw, body) }

    status, payload = begin
      @lock.synchronize { @overrides[path] } || respond(path, body)
    rescue StandardError => e
      [500, { "error" => "stand_in_failed", "message" => "#{e.class}: #{e.message}" }]
    end
    payload = JSON.generate(payload) unless payload.is_a?(String)
    reason = { 200 => "OK", 402 => "Payment Required" }.fetch(status, "Status")
    socket.write(
      "HTTP/1.1 #{status} #{reason}\r\n" \
      "Content-Type: application/json; charset=utf-8\r\n" \
      "Content-Length: #{payload.bytesize}\r\n" \
      "Connection: close\r\n\r\n"
    )
    socket.write(payload)
  ensure
    socket&.close
  end

  def result(query, name)
    {
      "query" => query, "name" => name, "gender" => "female", "country" => "TR",
      "probability" => 0.99, "sample_size" => 120_431, "took_ms" => 3,
      "confidence" => "high", "source" => "database", "matched_as" => "name",
      "credits_charged" => 1, "credits_remaining" => 998,
      "data_version" => "2026.09", "request_id" => "req_1"
    }
  end

  def respond(path, body)
    case path
    when "/api/v1/gender"
      [200, result(body["name"], body["name"])]
    when "/api/v1/gender/email"
      [200, result(body["email"], "Ayşe").merge("matched_as" => "email")]
    when "/api/v1/gender/username"
      [200, result(body["username"], "Ayşe").merge("matched_as" => "username")]
    when "/api/v1/gender/bulk"
      results = Array(body["names"]).map { |n| result(n, n).reject { |k, _| k.start_with?("credits_") } }
      [200, {
        "results" => results,
        "summary" => { "total" => results.size, "female" => results.size, "male" => 0, "unknown" => 0 },
        "credits" => { "charged" => results.size, "remaining" => 998 - results.size },
        "data_version" => "2026.09", "request_id" => "req_2"
      }]
    when "/api/v1/gender/countries"
      [200, {
        "name" => body["name"],
        "basis" => {
          "counted_sources" => 12, "counted_countries" => 11, "attested_countries" => 40,
          "note" => "Shares compare only countries that publish counted birth statistics."
        },
        "registrations" => [
          { "country" => "TR", "count" => 812_000, "share" => 97.4 },
          { "country" => "DE", "count" => 21_000, "share" => 2.6 }
        ],
        "attested_in" => %w[AZ CY NL],
        "credits_charged" => 1, "credits_remaining" => 997,
        "data_version" => "2026.09", "request_id" => "req_3"
      }]
    when "/api/v1/me"
      [200, {
        "email" => "dev@example.com", "credits_remaining" => 997, "purchased_credits" => 1000,
        "free_today" => 12, "free_daily_limit" => 100, "lifetime_requests" => 4321,
        "data_version" => "2026.09"
      }]
    else
      [402, { "error" => "no_credits", "message" => "Out of credits.", "request_id" => "req_9" }]
    end
  end
end

class ClientTest < Minitest::Test
  KEY = "ng_test_key_123"

  def setup
    @api = StandInAPI.new
    @client = NameGender::Client.new(KEY, base_url: @api.base_url)
  end

  def teardown
    @api.stop
  end

  def last_request
    requests = @api.requests
    assert_equal 1, requests.size, "expected exactly one request"
    requests.first
  end

  def assert_request(method, path, body)
    req = last_request
    assert_equal method, req.method
    assert_equal path, req.path
    assert_equal "Bearer #{KEY}", req.headers["authorization"]
    if body.nil?
      assert_nil req.raw_body
    else
      assert_equal "application/json", req.headers["content-type"]
      assert_equal body, req.body
    end
    req
  end

  def test_requires_an_api_key
    assert_raises(ArgumentError) { NameGender::Client.new("") }
    assert_raises(ArgumentError) { NameGender::Client.new(nil) }
  end

  def test_trailing_slash_in_base_url_is_ignored
    NameGender::Client.new(KEY, base_url: @api.base_url + "/").account
    assert_request "GET", "/api/v1/me", nil
  end

  def test_name_without_country
    result = @client.name("Ayşe")
    assert_request "POST", "/api/v1/gender", { "name" => "Ayşe" }
    assert_equal "female", result["gender"]
    assert_equal 0.99, result["probability"]
    assert_equal 120_431, result["sample_size"]
    assert_equal "req_1", result["request_id"]
    %w[query name gender country probability sample_size took_ms confidence source
       matched_as credits_charged credits_remaining data_version request_id].each do |field|
      assert result.key?(field), "result is missing #{field}"
    end
  end

  def test_name_with_country_and_options
    @client.name("Andrea", country: "IT", ai_fallback: true, best_guess: false)
    assert_request "POST", "/api/v1/gender",
                   { "name" => "Andrea", "country" => "IT", "ai_fallback" => true, "best_guess" => false }
  end

  def test_non_ascii_name_round_trips
    result = @client.name("Ayşe", country: "TR")
    req = assert_request "POST", "/api/v1/gender", { "name" => "Ayşe", "country" => "TR" }
    assert_includes req.raw_body, "Ayşe"
    assert_equal "Ayşe", result["name"]
    assert_equal "Ayşe", result["query"]
    assert_equal Encoding::UTF_8, result["name"].encoding
  end

  def test_email
    result = @client.email("ayse.yilmaz@example.com")
    assert_request "POST", "/api/v1/gender/email", { "email" => "ayse.yilmaz@example.com" }
    assert_equal "email", result["matched_as"]
    assert_equal "ayse.yilmaz@example.com", result["query"]
  end

  def test_email_with_country_and_options
    @client.email("ayse@example.com", country: "TR", best_guess: true)
    assert_request "POST", "/api/v1/gender/email",
                   { "email" => "ayse@example.com", "country" => "TR", "best_guess" => true }
  end

  def test_username
    result = @client.username("ayse_1990", ai_fallback: true)
    assert_request "POST", "/api/v1/gender/username", { "username" => "ayse_1990", "ai_fallback" => true }
    assert_equal "username", result["matched_as"]
    assert_equal "Ayşe", result["name"]
  end

  def test_username_with_country
    @client.username("ayse_1990", country: "TR")
    assert_request "POST", "/api/v1/gender/username", { "username" => "ayse_1990", "country" => "TR" }
  end

  def test_bulk
    result = @client.bulk(%w[Ayşe Mehmet], country: "TR", best_guess: true)
    assert_request "POST", "/api/v1/gender/bulk",
                   { "names" => %w[Ayşe Mehmet], "country" => "TR", "type" => "name", "best_guess" => true }
    assert_equal %w[Ayşe Mehmet], result["results"].map { |r| r["name"] }
    assert_equal 2, result["summary"]["total"]
    assert_equal 2, result["credits"]["charged"]
  end

  def test_bulk_with_one_name_sends_an_array
    @client.bulk(["Ayşe"])
    assert_request "POST", "/api/v1/gender/bulk", { "names" => ["Ayşe"], "type" => "name" }
  end

  def test_bulk_with_a_single_string_sends_an_array
    result = @client.bulk("Ayşe")
    assert_request "POST", "/api/v1/gender/bulk", { "names" => ["Ayşe"], "type" => "name" }
    assert_equal 1, result["results"].size
  end

  def test_bulk_type_passes_through
    @client.bulk(["ayse@example.com"], type: "email")
    assert_request "POST", "/api/v1/gender/bulk", { "names" => ["ayse@example.com"], "type" => "email" }
  end

  def test_countries_without_limit
    result = @client.countries("Mehmet")
    assert_request "POST", "/api/v1/gender/countries", { "name" => "Mehmet" }
    assert_equal "Mehmet", result["name"]
    assert_equal %w[counted_sources counted_countries attested_countries note].sort, result["basis"].keys.sort
    assert_equal "TR", result["registrations"].first["country"]
    assert_equal 97.4, result["registrations"].first["share"]
    assert_equal %w[AZ CY NL], result["attested_in"]
  end

  def test_countries_with_limit
    @client.countries("Mehmet", limit: 10)
    assert_request "POST", "/api/v1/gender/countries", { "name" => "Mehmet", "limit" => 10 }
  end

  def test_account
    result = @client.account
    assert_request "GET", "/api/v1/me", nil
    assert_equal "dev@example.com", result["email"]
    assert_equal 997, result["credits_remaining"]
    assert_equal 1000, result["purchased_credits"]
    assert_equal 12, result["free_today"]
    assert_equal 100, result["free_daily_limit"]
    assert_equal 4321, result["lifetime_requests"]
    assert_equal "2026.09", result["data_version"]
  end

  def test_non_2xx_raises_with_status_and_body
    client = NameGender::Client.new(KEY, base_url: "http://127.0.0.1:#{@api.port}/api/v2")
    error = assert_raises(NameGender::Error) { client.name("Ayşe") }
    assert_equal 402, error.status
    assert_equal "Out of credits.", error.message
    assert_equal "no_credits", error.body["error"]
    assert_equal "req_9", error.body["request_id"]
  end

  def test_non_2xx_without_message_falls_back_to_status
    @api.override("/api/v1/gender", 429, '{"error":"rate_limited"}')
    error = assert_raises(NameGender::Error) { @client.name("Ayşe") }
    assert_equal 429, error.status
    assert_equal "HTTP 429", error.message
    assert_equal({ "error" => "rate_limited" }, error.body)
  end

  def test_invalid_json_raises_with_status
    @api.override("/api/v1/gender", 502, "<html>Bad Gateway</html>")
    error = assert_raises(NameGender::Error) { @client.name("Ayşe") }
    assert_equal 502, error.status
    assert_equal "NameGender returned invalid JSON", error.message
    assert_nil error.body
  end
end
