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

  def respond_json(path, body)
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
