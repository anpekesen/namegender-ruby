require "minitest/autorun"
require "json"
require "socket"
require "stringio"
require "tmpdir"
require "namegender"

# A stand-in for the NameGender API: a plain TCPServer on 127.0.0.1 that
# records every request and answers with canned JSON in the current API shape.
# Bodies that are not JSON (a multipart upload) are kept as raw bytes.
class StandInAPI
  Request = Struct.new(:method, :path, :headers, :raw_body, :body)

  attr_reader :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @overrides = {}
    @scripts = {}
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

  # Answer one path with these [status, raw, content type] responses in turn;
  # the last one repeats.
  def script(path, *responses)
    @lock.synchronize { @scripts[path] = responses }
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
    json = headers["content-type"].to_s.start_with?("application/json")
    raw = length.positive? ? socket.read(length).force_encoding(json ? Encoding::UTF_8 : Encoding::BINARY) : nil
    body = raw && json ? JSON.parse(raw) : nil
    @lock.synchronize { @requests << Request.new(method, path, headers, raw, body) }

    status, payload, type = begin
      @lock.synchronize { next_scripted(path) || @overrides[path] } || respond(method, path, body)
    rescue StandardError => e
      [500, { "error" => "stand_in_failed", "message" => "#{e.class}: #{e.message}" }]
    end
    payload = JSON.generate(payload) unless payload.is_a?(String)
    reason = { 200 => "OK", 201 => "Created", 204 => "No Content", 402 => "Payment Required",
               503 => "Service Unavailable" }.fetch(status, "Status")
    socket.write(
      "HTTP/1.1 #{status} #{reason}\r\n" \
      "Content-Type: #{type || "application/json; charset=utf-8"}\r\n" \
      "Content-Length: #{payload.bytesize}\r\n" \
      "Connection: close\r\n\r\n"
    )
    socket.write(payload)
  ensure
    socket&.close
  end

  def next_scripted(path)
    responses = @scripts[path] or return
    responses.size > 1 ? responses.shift : responses.first
  end

  def job(status, extra = {})
    {
      "id" => "B-1", "status" => status, "source" => "api",
      "file" => { "name" => "a.csv", "format" => "csv" },
      "progress" => { "processed_rows" => 0, "total_rows" => 1, "percent" => 0 },
      "poll_after_seconds" => 5
    }.merge(extra)
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

  # Salutation results in the API shape, for the names the tests use.
  SALUTATIONS = {
    "Dr. Anna Müller" => {
      "query" => "Dr. Anna Müller", "language" => "de", "form" => "gendered", "reason" => nil,
      "salutation" => {
        "formal" => "Sehr geehrte Frau Dr. Müller,", "informal" => "Liebe Anna,",
        "neutral" => "Guten Tag Dr. Anna Müller,"
      },
      "parts" => { "opening" => "Sehr geehrte", "courtesy" => "Frau", "academic" => "Dr.", "name" => "Müller" },
      "gender" => "female", "gender_source" => "lookup", "probability" => 99, "confidence" => "high",
      "first_name" => "Anna", "last_name" => "Müller", "name_type" => "personal", "country" => "DE"
    },
    "Kim Schmidt" => {
      "query" => "Kim Schmidt", "language" => "de", "form" => "neutral", "reason" => "below_min_probability",
      "salutation" => {
        "formal" => "Guten Tag Kim Schmidt,", "informal" => "Hallo Kim,", "neutral" => "Guten Tag Kim Schmidt,"
      },
      "parts" => { "opening" => "Guten Tag", "courtesy" => nil, "academic" => nil, "name" => "Kim Schmidt" },
      "gender" => nil, "gender_source" => nil, "probability" => nil, "confidence" => nil,
      "first_name" => "Kim", "last_name" => "Schmidt", "name_type" => "personal", "country" => "DE"
    },
    "Müller GmbH" => {
      "query" => "Müller GmbH", "language" => "de", "form" => "organization", "reason" => nil,
      "salutation" => {
        "formal" => "Sehr geehrte Damen und Herren,", "informal" => "Hallo,",
        "neutral" => "Sehr geehrte Damen und Herren,"
      },
      "parts" => { "opening" => "Sehr geehrte Damen und Herren", "courtesy" => nil, "academic" => nil, "name" => nil },
      "gender" => nil, "gender_source" => nil, "probability" => nil, "confidence" => nil,
      "first_name" => nil, "last_name" => nil, "name_type" => "organization", "country" => "DE"
    }
  }.freeze

  # Name check results in the API shape, for the names the tests use.
  NAME_CHECKS = {
    "asdf qwerty" => {
      "query" => "asdf qwerty", "assessment" => "implausible", "score" => 0,
      "signals" => [
        { "code" => "keyboard_pattern", "severity" => "high", "part" => "first_name", "value" => "asdf" },
        { "code" => "keyboard_pattern", "severity" => "high", "part" => "last_name", "value" => "qwerty" },
        { "code" => "first_name_not_found", "severity" => "medium", "part" => "first_name", "value" => nil }
      ],
      "first_name" => "Asdf", "last_name" => "Qwerty", "name_type" => "personal",
      "evidence" => { "first_name_status" => "not_found", "first_name_counted_records" => 0 }
    },
    "Jennifer Null" => {
      "query" => "Jennifer Null", "assessment" => "plausible", "score" => 96,
      "signals" => [
        { "code" => "first_name_attested", "severity" => "positive", "part" => "first_name", "value" => "Jennifer" }
      ],
      "first_name" => "Jennifer", "last_name" => "Null", "name_type" => "personal",
      "evidence" => { "first_name_status" => "counted", "first_name_counted_records" => 1_470_000 }
    },
    "Acme Ltd" => {
      "query" => "Acme Ltd", "assessment" => "suspicious", "score" => 40,
      "signals" => [{ "code" => "organization_name", "severity" => "medium", "part" => "full", "value" => nil }],
      "first_name" => nil, "last_name" => nil, "name_type" => "organization",
      "evidence" => { "first_name_status" => nil, "first_name_counted_records" => 0 }
    }
  }.freeze

  def respond(method, path, body)
    case [method, path]
    in ["POST", "/api/v1/batches"]
      [201, job("queued")]
    in ["POST", "/api/v1/batches/B-1/start"]
      [200, job("queued", "columns" => body)]
    in ["GET", "/api/v1/batches/B-1"]
      [200, job("completed")]
    in ["DELETE", "/api/v1/batches/B-1"]
      [204, ""]
    in ["GET", "/api/v1/batches/B-1/result"]
      [200, "\xEF\xBB\xBFid,gender\n1,female\n".b, "text/csv; charset=utf-8"]
    in ["GET", %r{\A/api/v1/batches(\?|\z)}]
      [200, { "data" => [job("completed")], "page" => 1, "per_page" => 5, "total" => 1, "has_more" => false }]
    else
      respond_json(path, body)
    end
  end

  # Which input supplied the country, as the API decides it:
  # country > a locale with a region > ip.
  def country_source(body)
    if body["country"] then "country"
    elsif body["locale"].to_s.match?(/[-_][A-Za-z]{2}\z/) then "locale"
    elsif body["ip"] then "ip"
    end
  end

  def respond_json(path, body)
    source = { "country_source" => country_source(body) } if body
    case path
    when "/api/v1/gender"
      [200, result(body["name"], body["name"]).merge(source)]
    when "/api/v1/gender/email"
      [200, result(body["email"], "Ayşe").merge("matched_as" => "email").merge(source)]
    when "/api/v1/gender/username"
      [200, result(body["username"], "Ayşe").merge("matched_as" => "username").merge(source)]
    when "/api/v1/gender/bulk"
      results = Array(body["names"]).map { |n| result(n, n).reject { |k, _| k.start_with?("credits_") } }
      [200, {
        "results" => results,
        "summary" => { "total" => results.size, "female" => results.size, "male" => 0, "unknown" => 0 },
        "credits" => { "charged" => results.size, "remaining" => 998 - results.size },
        "data_version" => "2026.09", "request_id" => "req_2"
      }.merge(source)]
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
    when "/api/v1/salutation"
      if body["language"] == "xx"
        return [422, {
          "error" => "invalid_input", "message" => "Unsupported language.", "field" => "language",
          "supported" => %w[en de tr], "request_id" => "req_8"
        }]
      end
      item = SALUTATIONS.fetch(body["name"] || "Dr. Anna Müller")
      [200, {
        "credits_charged" => 1, "credits_remaining" => 4999, "data_version" => "2026.10", "request_id" => "req_4"
      }.merge(source).merge(item)]
    when "/api/v1/salutation/bulk"
      results = Array(body["names"]).map { |n| SALUTATIONS.fetch(n) }
      counts = results.map { |r| r["form"] }.tally
      [200, {
        "credits_charged" => results.size, "credits_remaining" => 4999 - results.size,
        "data_version" => "2026.10", "request_id" => "req_5", "took_ms" => 4, "language" => "de",
        "summary" => { "total" => results.size, "gendered" => counts.fetch("gendered", 0),
                       "neutral" => counts.fetch("neutral", 0), "organization" => counts.fetch("organization", 0) },
        "results" => results
      }.merge(source)]
    when "/api/v1/name-check"
      query = body["name"] || [body["first_name"], body["last_name"]].compact.join(" ")
      if query.empty?
        return [400, {
          "error" => "missing_input", "message" => "Send name, or first_name and last_name.", "request_id" => "req_10"
        }]
      end
      [200, {
        "credits_charged" => 1, "credits_remaining" => 4999, "data_version" => "2026.10", "request_id" => "req_6"
      }.merge(source).merge(NAME_CHECKS.fetch(query))]
    when "/api/v1/name-check/bulk"
      results = Array(body["names"]).map { |n| NAME_CHECKS.fetch(n) }
      counts = results.map { |r| r["assessment"] }.tally
      [200, {
        "credits_charged" => results.size, "credits_remaining" => 4999 - results.size,
        "data_version" => "2026.10", "request_id" => "req_7", "took_ms" => 4,
        "summary" => { "total" => results.size, "plausible" => counts.fetch("plausible", 0),
                       "suspicious" => counts.fetch("suspicious", 0), "implausible" => counts.fetch("implausible", 0) },
        "results" => results
      }.merge(source)]
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

  def test_name_with_locale
    result = @client.name("Andrea", locale: "it-IT")
    assert_request "POST", "/api/v1/gender", { "name" => "Andrea", "locale" => "it-IT" }
    assert_equal "locale", result["country_source"]
  end

  def test_name_with_ip
    result = @client.name("Andrea", ip: "203.0.113.7")
    assert_request "POST", "/api/v1/gender", { "name" => "Andrea", "ip" => "203.0.113.7" }
    assert_equal "ip", result["country_source"]
  end

  def test_country_wins_over_locale_and_ip
    result = @client.name("Andrea", country: "IT", locale: "pt_BR", ip: "203.0.113.7")
    assert_request "POST", "/api/v1/gender",
                   { "name" => "Andrea", "country" => "IT", "locale" => "pt_BR", "ip" => "203.0.113.7" }
    assert_equal "country", result["country_source"]
  end

  def test_locale_without_a_region_sets_no_country_source
    result = @client.name("Andrea", locale: "en")
    assert_request "POST", "/api/v1/gender", { "name" => "Andrea", "locale" => "en" }
    assert_nil result["country_source"]
    assert result.key?("country_source")
  end

  def test_email_and_username_send_locale_and_ip
    result = @client.email("andrea@example.com", locale: "pt_BR", best_guess: true)
    assert_equal({ "email" => "andrea@example.com", "locale" => "pt_BR", "best_guess" => true }, @api.requests.last.body)
    assert_equal "locale", result["country_source"]
    result = @client.username("andrea_88", ip: "2001:db8::1")
    assert_equal({ "username" => "andrea_88", "ip" => "2001:db8::1" }, @api.requests.last.body)
    assert_equal "ip", result["country_source"]
  end

  def test_bulk_with_locale_and_ip
    result = @client.bulk(%w[Andrea Luca], locale: "it-IT", ip: "203.0.113.7")
    assert_request "POST", "/api/v1/gender/bulk",
                   { "names" => %w[Andrea Luca], "locale" => "it-IT", "ip" => "203.0.113.7", "type" => "name" }
    assert_equal "locale", result["country_source"]
    result["results"].each { |item| refute item.key?("country_source") }
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

  # --- Salutation ---

  def test_salutation_sends_only_the_name
    result = @client.salutation("Dr. Anna Müller")
    assert_request "POST", "/api/v1/salutation", { "name" => "Dr. Anna Müller" }
    assert_equal "gendered", result["form"]
    assert_nil result["reason"]
    assert_equal "Sehr geehrte Frau Dr. Müller,", result["salutation"]["formal"]
    assert_equal "Liebe Anna,", result["salutation"]["informal"]
    assert_equal "Guten Tag Dr. Anna Müller,", result["salutation"]["neutral"]
    assert_equal({ "opening" => "Sehr geehrte", "courtesy" => "Frau", "academic" => "Dr.", "name" => "Müller" },
                 result["parts"])
    assert_equal "lookup", result["gender_source"]
    assert_equal 99, result["probability"]
    assert_equal 1, result["credits_charged"]
    assert_equal "2026.10", result["data_version"]
  end

  def test_salutation_sends_every_option_that_is_set
    @client.salutation("Dr. Anna Müller", language: "de", country: "DE", locale: "de-AT", ip: "203.0.113.7",
                                          gender: "female", min_probability: 80, title: "Dr.")
    assert_request "POST", "/api/v1/salutation", {
      "name" => "Dr. Anna Müller", "language" => "de", "country" => "DE", "locale" => "de-AT",
      "ip" => "203.0.113.7", "gender" => "female", "min_probability" => 80, "title" => "Dr."
    }
  end

  def test_salutation_with_first_and_last_name
    result = @client.salutation(first_name: "Anna", last_name: "Müller", locale: "de-DE")
    assert_request "POST", "/api/v1/salutation", { "first_name" => "Anna", "last_name" => "Müller", "locale" => "de-DE" }
    assert_equal "locale", result["country_source"]
  end

  def test_salutation_does_not_take_gender_lookup_options
    assert_raises(ArgumentError) { @client.salutation("Kim Schmidt", best_guess: true) }
    assert_raises(ArgumentError) { @client.salutation_bulk(["Kim Schmidt"], ai_fallback: true) }
    assert_empty @api.requests
  end

  def test_salutation_neutral_form_with_a_reason_and_null_parts
    result = @client.salutation("Kim Schmidt", language: "de")
    assert_equal "neutral", result["form"]
    assert_equal "below_min_probability", result["reason"]
    assert_equal "Guten Tag Kim Schmidt,", result["salutation"]["formal"]
    assert_nil result["parts"]["courtesy"]
    assert_nil result["parts"]["academic"]
    assert_nil result["gender"]
    assert_nil result["probability"]
    assert result["parts"].key?("courtesy")
    assert result.key?("gender_source")
  end

  def test_salutation_bulk_keeps_order_and_summary
    names = ["Müller GmbH", "Dr. Anna Müller", "Kim Schmidt"]
    result = @client.salutation_bulk(names, language: "de", min_probability: 95)
    assert_request "POST", "/api/v1/salutation/bulk",
                   { "names" => names, "language" => "de", "min_probability" => 95 }
    assert_equal names, result["results"].map { |r| r["query"] }
    assert_equal %w[organization gendered neutral], result["results"].map { |r| r["form"] }
    assert_equal({ "total" => 3, "gendered" => 1, "neutral" => 1, "organization" => 1 }, result["summary"])
    assert_equal 3, result["credits_charged"]
    result["results"].each { |item| refute item.key?("credits_charged") }
  end

  def test_salutation_bulk_with_a_single_string_sends_an_array
    @client.salutation_bulk("Kim Schmidt")
    assert_request "POST", "/api/v1/salutation/bulk", { "names" => ["Kim Schmidt"] }
  end

  def test_salutation_unsupported_language_raises
    error = assert_raises(NameGender::Error) { @client.salutation("Dr. Anna Müller", language: "xx") }
    assert_equal 422, error.status
    assert_equal "Unsupported language.", error.message
    assert_equal "invalid_input", error.body["error"]
    assert_equal "language", error.body["field"]
    assert_includes error.body["supported"], "de"
  end

  # --- Name check ---

  def test_name_check_sends_only_the_name
    result = @client.name_check("asdf qwerty")
    assert_request "POST", "/api/v1/name-check", { "name" => "asdf qwerty" }
    assert_equal "implausible", result["assessment"]
    assert_equal 0, result["score"]
    assert_equal "Asdf", result["first_name"]
    assert_equal "Qwerty", result["last_name"]
    assert_equal "personal", result["name_type"]
    assert_equal({ "code" => "keyboard_pattern", "severity" => "high", "part" => "first_name", "value" => "asdf" },
                 result["signals"].first)
    assert_equal({ "first_name_status" => "not_found", "first_name_counted_records" => 0 }, result["evidence"])
    assert_nil result["country_source"]
    assert result.key?("country_source")
    assert_equal 1, result["credits_charged"]
    assert_equal "2026.10", result["data_version"]
    assert_equal "req_6", result["request_id"]
  end

  def test_name_check_sends_every_option_that_is_set
    @client.name_check("Jennifer Null", country: "US", locale: "en-US", ip: "203.0.113.7")
    assert_request "POST", "/api/v1/name-check", {
      "name" => "Jennifer Null", "country" => "US", "locale" => "en-US", "ip" => "203.0.113.7"
    }
  end

  def test_name_check_with_first_and_last_name
    result = @client.name_check(first_name: "Jennifer", last_name: "Null", locale: "en-US")
    assert_request "POST", "/api/v1/name-check", { "first_name" => "Jennifer", "last_name" => "Null", "locale" => "en-US" }
    assert_equal "plausible", result["assessment"]
    assert_equal 96, result["score"]
    assert_equal "positive", result["signals"].first["severity"]
    assert_equal "counted", result["evidence"]["first_name_status"]
    assert_equal "locale", result["country_source"]
  end

  def test_name_check_does_not_take_gender_lookup_options
    assert_raises(ArgumentError) { @client.name_check("asdf qwerty", best_guess: true) }
    assert_raises(ArgumentError) { @client.name_check("asdf qwerty", language: "en") }
    assert_raises(ArgumentError) { @client.name_check_bulk(["asdf qwerty"], ai_fallback: true) }
    assert_empty @api.requests
  end

  def test_name_check_null_part_value_and_first_name_status
    result = @client.name_check("Acme Ltd")
    assert_equal "suspicious", result["assessment"]
    assert_equal "organization", result["name_type"]
    signal = result["signals"].first
    assert_equal "organization_name", signal["code"]
    assert_equal "full", signal["part"]
    assert_nil signal["value"]
    assert signal.key?("value")
    assert_nil result["first_name"]
    assert_nil result["evidence"]["first_name_status"]
    assert result["evidence"].key?("first_name_status")
    assert_nil @client.name_check("asdf qwerty")["signals"].last["value"]
  end

  def test_name_check_bulk_keeps_order_and_summary
    names = ["Jennifer Null", "asdf qwerty", "Acme Ltd"]
    result = @client.name_check_bulk(names, country: "US")
    assert_request "POST", "/api/v1/name-check/bulk", { "names" => names, "country" => "US" }
    assert_equal names, result["results"].map { |r| r["query"] }
    assert_equal %w[plausible implausible suspicious], result["results"].map { |r| r["assessment"] }
    assert_equal [96, 0, 40], result["results"].map { |r| r["score"] }
    assert_equal({ "total" => 3, "plausible" => 1, "suspicious" => 1, "implausible" => 1 }, result["summary"])
    assert_equal 3, result["credits_charged"]
    assert_equal "country", result["country_source"]
    result["results"].each { |item| refute item.key?("credits_charged") }
  end

  def test_name_check_bulk_with_a_single_string_sends_an_array
    @client.name_check_bulk("asdf qwerty")
    assert_request "POST", "/api/v1/name-check/bulk", { "names" => ["asdf qwerty"] }
  end

  def test_name_check_missing_input_raises
    error = assert_raises(NameGender::Error) { @client.name_check }
    assert_request "POST", "/api/v1/name-check", {}
    assert_equal 400, error.status
    assert_equal "Send name, or first_name and last_name.", error.message
    assert_equal "missing_input", error.body["error"]
    assert_equal "req_10", error.body["request_id"]
  end

  # --- File jobs ---

  # Records the backoff instead of sleeping through it.
  def record_pauses(batches)
    pauses = []
    batches.define_singleton_method(:pause) { |seconds| pauses << seconds }
    pauses
  end

  def test_batch_create_sends_a_multipart_upload
    job = @client.batches.create("ad\nAyşe\n".b, filename: "a.csv", name_column: "ad",
                                 country: "TR", best_guess: true, ai_fallback: nil)
    req = last_request
    assert_equal "POST", req.method
    assert_equal "/api/v1/batches", req.path
    assert_equal "Bearer #{KEY}", req.headers["authorization"]
    assert_match %r{\Amultipart/form-data; boundary=\S+\z}, req.headers["content-type"]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, req.headers["idempotency-key"])
    body = req.raw_body
    assert_equal Encoding::BINARY, body.encoding
    assert_includes body, %(name="file"; filename="a.csv")
    assert_includes body, "ad\nAyşe\n".b
    { "name_column" => "ad", "country" => "TR", "best_guess" => "true", "start" => "true" }.each do |key, value|
      assert_includes body, %(name="#{key}"\r\n\r\n#{value}\r\n)
    end
    refute_includes body, "ai_fallback"
    assert_equal "B-1", job["id"]
  end

  def test_batch_create_reads_a_path_and_an_io
    Dir.mktmpdir do |dir|
      path = File.join(dir, "customers.xlsx")
      File.binwrite(path, "PK\x03\x04".b)
      @client.batches.create(path, start: false)
      File.open(path, "rb") { |io| @client.batches.create(io, name_column: "ad") }
    end
    first, second = @api.requests.map(&:raw_body)
    assert_includes first, %(filename="customers.xlsx")
    assert_includes first, %(name="start"\r\n\r\nfalse\r\n)
    assert_includes first, "PK\x03\x04".b
    assert_includes second, %(filename="customers.xlsx")
    assert_includes second, %(name="start"\r\n\r\ntrue\r\n)
  end

  def test_batch_create_needs_a_filename_for_bytes
    assert_raises(ArgumentError) { @client.batches.create("ad\nAyşe\n".b, name_column: "ad") }
    assert_raises(ArgumentError) { @client.batches.create(StringIO.new("ad\n"), name_column: "ad") }
    assert_empty @api.requests
  end

  def test_batch_create_retries_a_503_with_the_same_key
    pauses = record_pauses(@client.batches)
    @api.script("/api/v1/batches", [503, '{"error":"unavailable"}'], [201, '{"id":"B-1","status":"queued"}'])
    job = @client.batches.create("ad\n".b, filename: "a.csv", name_column: "ad")
    assert_equal "B-1", job["id"]
    keys = @api.requests.map { |r| r.headers["idempotency-key"] }
    assert_equal 2, keys.size
    assert_equal 1, keys.uniq.size
    assert_equal [1], pauses
  end

  def test_batch_create_keeps_a_given_key_and_gives_up_after_the_retries
    pauses = record_pauses(@client.batches)
    @api.script("/api/v1/batches", [502, "<html>Bad Gateway</html>"])
    error = assert_raises(NameGender::Error) do
      @client.batches.create("ad\n".b, filename: "a.csv", name_column: "ad", idempotency_key: "mine", retries: 2)
    end
    assert_equal 502, error.status
    assert_equal %w[mine mine mine], @api.requests.map { |r| r.headers["idempotency-key"] }
    assert_equal [1, 2], pauses
  end

  def test_batch_create_does_not_retry_a_402
    pauses = record_pauses(@client.batches)
    @api.script("/api/v1/batches", [402, '{"error":"no_credits","message":"Out of credits."}'])
    error = assert_raises(NameGender::Error) { @client.batches.create("ad\n".b, filename: "a.csv", name_column: "ad") }
    assert_equal 402, error.status
    assert_equal "no_credits", error.body["error"]
    assert_equal 1, @api.requests.size
    assert_empty pauses
  end

  def test_batch_create_retries_network_errors
    port = @api.port
    @api.stop
    client = NameGender::Client.new(KEY, base_url: "http://127.0.0.1:#{port}/api/v1")
    pauses = record_pauses(client.batches)
    assert_raises(SystemCallError) { client.batches.create("ad\n".b, filename: "a.csv", retries: 1) }
    assert_equal [1], pauses
    @api = StandInAPI.new
  end

  def test_batch_start
    job = @client.batches.start("B-1", name_column: "first_name", country_column: "country", country: nil)
    assert_request "POST", "/api/v1/batches/B-1/start", { "name_column" => "first_name", "country_column" => "country" }
    assert_equal "queued", job["status"]
  end

  def test_batch_wait_polls_until_finished
    pauses = record_pauses(@client.batches)
    @api.script("/api/v1/batches/B-1",
                [200, '{"id":"B-1","status":"queued","poll_after_seconds":2}'],
                [200, '{"id":"B-1","status":"processing"}'],
                [200, '{"id":"B-1","status":"failed","error":{"code":"unreadable_file"}}'])
    seen = []
    job = @client.batches.wait("B-1", on_progress: ->(j) { seen << j["status"] })
    assert_equal "failed", job["status"]
    assert_equal "unreadable_file", job["error"]["code"]
    assert_equal %w[queued processing failed], seen
    assert_equal [2, 5], pauses
    assert_equal ["GET"], @api.requests.map(&:method).uniq
  end

  def test_batch_wait_returns_an_uploaded_job_and_times_out
    @api.script("/api/v1/batches/B-1", [200, '{"id":"B-1","status":"uploaded"}'])
    assert_equal "uploaded", @client.batches.wait("B-1")["status"]

    @api.script("/api/v1/batches/B-1", [200, '{"id":"B-1","status":"processing","poll_after_seconds":30}'])
    error = assert_raises(NameGender::Error) { @client.batches.wait("B-1", timeout: 10) }
    assert_equal "Timed out waiting for B-1", error.message
    assert_equal "processing", error.body["status"]
  end

  def test_batch_get_cancel_list_and_download
    assert_equal "completed", @client.batches.get("B-1")["status"]
    assert_nil @client.batches.cancel("B-1")
    assert_equal 1, @client.batches.list(limit: 5)["total"]
    @client.batches.list
    csv = @client.batches.download("B-1")
    assert_equal "\xEF\xBB\xBFid,gender\n1,female\n".b, csv
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.csv")
      assert_equal path, @client.batches.download("B-1", path)
      assert_equal csv, File.binread(path)
    end
    assert_equal [
      "GET /api/v1/batches/B-1", "DELETE /api/v1/batches/B-1", "GET /api/v1/batches?limit=5",
      "GET /api/v1/batches", "GET /api/v1/batches/B-1/result", "GET /api/v1/batches/B-1/result"
    ], @api.requests.map { |r| "#{r.method} #{r.path}" }
  end

  def test_batch_ids_are_escaped
    @api.script("/api/v1/batches/a%2Fb%20c", [200, '{"id":"a/b c","status":"queued"}'])
    assert_equal "a/b c", @client.batches.get("a/b c")["id"]
  end

  # --- Webhooks ---

  # Same vector as the server's WebhookDeliveryTest and the JS and Python SDKs.
  SECRET = "whsec_test_vector"
  PAYLOAD = '{"id":"evt_1","type":"webhook.test"}'
  SIGNATURE = "857fcddfea47617c448b7a8e6537bbd59c9922a37c5273b2709812fbadb29e50"
  HEADER = "t=1700000000,v1=#{SIGNATURE}"
  NOW = 1_700_000_000

  def test_webhook_verifies_the_shared_vector
    event = NameGender::Webhooks.verify(PAYLOAD, HEADER, SECRET, now: NOW)
    assert_equal({ "id" => "evt_1", "type" => "webhook.test" }, event)
    NameGender::Webhooks.verify(PAYLOAD.b, HEADER, SECRET, now: NOW + 60)
    NameGender::Webhooks.verify(PAYLOAD, "t=1700000000,v1=#{"0" * 64},v1=#{SIGNATURE}", SECRET, now: NOW)
  end

  def test_webhook_rejects_anything_else
    reject = lambda do |payload, header, secret, now|
      assert_raises(NameGender::WebhookVerificationError) { NameGender::Webhooks.verify(payload, header, secret, now: now) }
    end
    reject.call(PAYLOAD.sub("evt_1", "evt_2"), HEADER, SECRET, NOW)
    reject.call(PAYLOAD, HEADER, "whsec_other", NOW)
    reject.call(PAYLOAD, HEADER, SECRET, NOW + 301)
    reject.call(PAYLOAD, HEADER, SECRET, NOW - 301)
    reject.call(PAYLOAD, nil, SECRET, NOW)
    reject.call(PAYLOAD, "", SECRET, NOW)
    reject.call(PAYLOAD, "t=abc,v1=", SECRET, NOW)
    reject.call(PAYLOAD, "v1=#{SIGNATURE}", SECRET, NOW)
    assert NameGender::WebhookVerificationError < NameGender::Error
  end

  def test_webhook_needs_a_raw_string_body_and_a_secret
    assert_raises(TypeError) { NameGender::Webhooks.verify({ "id" => "evt_1" }, HEADER, SECRET, now: NOW) }
    assert_raises(ArgumentError) { NameGender::Webhooks.verify(PAYLOAD, HEADER, "", now: NOW) }
  end
end
