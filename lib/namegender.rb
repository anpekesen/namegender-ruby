require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module NameGender
  class Error < StandardError
    attr_reader :status, :body
    def initialize(message, status = 0, body = nil)
      super(message); @status = status; @body = body
    end
  end

  # The request is not a genuine NameGender webhook. Answer it with 400.
  class WebhookVerificationError < Error; end

  class Client
    def initialize(api_key, base_url: "https://namegender.com/api/v1")
      raise ArgumentError, "api_key is required" if api_key.to_s.empty?
      @api_key, @base_url = api_key, base_url.sub(%r{/$}, "")
    end

    # `country` is an ISO 3166-1 alpha-2 code. Without it, `locale` (a
    # language tag such as "it-IT" or "pt_BR"; a tag without a region, "en",
    # sets no country) and then `ip` (the end user's IP address, not stored by
    # the API) supply one: country > locale > ip. The result's
    # "country_source" says which was used ("country", "locale", "ip" or nil).
    #
    # Other `options` are sent as-is: `ai_fallback: true` falls back to a
    # language model for names not in the database (needs AI consent on the
    # account), `best_guess: true` returns the most likely gender even below
    # the probability threshold. Any non-2xx response raises NameGender::Error.
    def name(value, country: nil, locale: nil, ip: nil, **options)
      post("/gender", { name: value, country: country, locale: locale, ip: ip }.merge(options).compact)
    end
    def email(value, country: nil, locale: nil, ip: nil, **options)
      post("/gender/email", { email: value, country: country, locale: locale, ip: ip }.merge(options).compact)
    end
    def username(value, country: nil, locale: nil, ip: nil, **options)
      post("/gender/username", { username: value, country: country, locale: locale, ip: ip }.merge(options).compact)
    end
    # `country`, `locale` and `ip` apply to every name in the list.
    def bulk(values, country: nil, locale: nil, ip: nil, type: "name", **options)
      post("/gender/bulk", { names: Array(values), country: country, locale: locale, ip: ip, type: type }.merge(options).compact)
    end
    # Country distribution of a name. Not a country-of-origin or ethnicity
    # inference: "registrations" is counted volume, comparable only among the
    # countries that publish counted birth statistics; "attested_in" is
    # presence with no weight attached. `limit` caps "registrations" (1-100,
    # server default 25).
    def countries(value, limit: nil)
      post("/gender/countries", { name: value, limit: limit }.compact)
    end
    # A salutation for a letter or an email: "Sehr geehrte Frau Dr. Müller,",
    # "Sayın Ahmet Bey,". `value` is the full name, titles included; pass
    # `first_name:` and `last_name:` instead when they are stored separately
    # (they are not parsed). `language` defaults to the language of `locale`,
    # then the main language of the country, then "en"; an unsupported one is
    # a 422. `gender:` ("male", "female", "neutral") is a known gender and
    # skips the lookup; `min_probability:` (50-100, server default 90) is the
    # certainty below which the neutral form is used; `title:` is an academic
    # title kept in a separate field ("Dr."). "form" and "reason" in the result
    # say why a neutral form was chosen. One credit per name. `best_guess` and
    # `ai_fallback` do not apply here and are not accepted.
    def salutation(value = nil, first_name: nil, last_name: nil, language: nil, country: nil, locale: nil, ip: nil,
                   gender: nil, min_probability: nil, title: nil)
      post("/salutation", {
        name: value, first_name: first_name, last_name: last_name, language: language, country: country,
        locale: locale, ip: ip, gender: gender, min_probability: min_probability, title: title
      }.compact)
    end
    # Up to 100 names; every option applies to all of them. "results" keeps
    # the input order, "summary" counts the gendered, neutral and organization
    # forms.
    def salutation_bulk(values, language: nil, country: nil, locale: nil, ip: nil, gender: nil, min_probability: nil,
                        title: nil)
      post("/salutation/bulk", {
        names: Array(values), language: language, country: country, locale: locale, ip: ip, gender: gender,
        min_probability: min_probability, title: title
      }.compact)
    end
    # Whether a name typed into a form looks like a real person's name, with
    # reasons. It never calls a name fake: use it to flag records for a look,
    # not to reject people automatically. "assessment" is "plausible",
    # "suspicious" or "implausible", "score" is 0-100, and "signals" lists
    # why ({"code", "severity", "part", "value"}; "part" and "value" can be
    # nil). Surnames are judged by their shape only. `value` is the full name;
    # pass `first_name:` and `last_name:` instead when they are stored
    # separately (they are not parsed). `country`, `locale` and `ip` work as
    # in #name. One credit per name. `best_guess`, `ai_fallback` and
    # `language` do not apply here and are not accepted.
    def name_check(value = nil, first_name: nil, last_name: nil, country: nil, locale: nil, ip: nil)
      post("/name-check", {
        name: value, first_name: first_name, last_name: last_name, country: country, locale: locale, ip: ip
      }.compact)
    end
    # Up to 100 names; every option applies to all of them. "results" keeps
    # the input order, "summary" counts the plausible, suspicious and
    # implausible names.
    def name_check_bulk(values, country: nil, locale: nil, ip: nil)
      post("/name-check/bulk", { names: Array(values), country: country, locale: locale, ip: ip }.compact)
    end
    # Estimated age of the people who carry a first name, from birth records:
    # "age" is the median, "age_range" the middle half and "age_range_80" the
    # middle 80 percent ({"low", "high"}), "birth_year" the median birth year.
    # It describes a group, not a person: never use it for decisions about an
    # individual. Covers the US, France and Norway; with no country hint US
    # data is used and "country_source" is "default". When "age" is nil,
    # "reason" says why ("not_found", "insufficient_data" or
    # "country_not_covered"); that is a normal answer, not an error, and
    # "country_not_covered" costs no credit. `gender:` ("male" or "female")
    # narrows to that gender's records; `country`, `locale` and `ip` work as
    # in #name. Options that are nil or empty are not sent. One credit per
    # name. Age responses carry no "data_version".
    def age(value, gender: nil, country: nil, locale: nil, ip: nil)
      post("/age", present(name: value, gender: gender, country: country, locale: locale, ip: ip))
    end
    # Up to 100 names; every option applies to all of them. "results" keeps
    # the input order.
    def age_bulk(values, gender: nil, country: nil, locale: nil, ip: nil)
      post("/age/bulk", present(names: Array(values), gender: gender, country: country, locale: locale, ip: ip))
    end
    def account
      request(Net::HTTP::Get, "/me")
    end
    # File jobs: upload a CSV or XLSX file, get it back with gender columns added.
    def batches
      @batches ||= Batches.new(self)
    end

    private
    def post(path, body)
      request(Net::HTTP::Post, path, body)
    end
    # The fields that are set: nil and empty strings are dropped.
    def present(fields)
      fields.reject { |_, v| v.nil? || v == "" }
    end
    def request(klass, path, body = nil, raw: nil, headers: {})
      response = transmit(klass, path, body, raw: raw, headers: headers)
      # 204 (a cancelled job) has no body.
      return nil if response.body.to_s.empty?
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error.new("NameGender returned invalid JSON", response&.code.to_i)
    end
    # `raw` is [bytes, content type] for a body that is not JSON.
    def transmit(klass, path, body = nil, raw: nil, headers: {})
      uri = URI(@base_url + path)
      req = klass.new(uri)
      req["Accept"] = req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      if raw
        req.body, req["Content-Type"] = raw
      elsif body
        req.body = JSON.generate(body)
      end
      headers.each { |key, value| req[key] = value }
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
      return response if response.is_a?(Net::HTTPSuccess)
      begin
        parsed = JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error.new("NameGender returned invalid JSON", response.code.to_i)
      end
      message = parsed.is_a?(Hash) && parsed["message"]
      raise Error.new(message || "HTTP #{response.code}", response.code.to_i, parsed)
    end
  end

  # File jobs. Reached as `client.batches`.
  class Batches
    FINISHED = %w[completed failed cancelled].freeze
    # Statuses worth retrying an upload for: the request may never have reached
    # the application. Everything else (402, 422, 429 too_many_batches) would
    # fail the same way again.
    RETRYABLE = [502, 503, 504].freeze
    NETWORK_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

    def initialize(client)
      @client = client
    end

    # Upload a file and, unless `start: false`, start it.
    #
    # `file` is a path (String or Pathname), a binary String (`File.binread`)
    # together with `filename:`, or an IO. The extension of the file name
    # (.csv, .xlsx) tells the API the format. `name_column:` is required to
    # start: a guessed column that is wrong would spend credits on the wrong
    # data. With `start: false` the job carries "inspection" (columns,
    # preview, cost) and is started with #start.
    #
    # One Idempotency-Key is used for every attempt, so a retry after a
    # dropped connection returns the first job instead of opening a second
    # one and reserving credit twice.
    def create(file, filename: nil, start: true, idempotency_key: nil, retries: 2, **settings)
      content, name = read_file(file, filename)
      fields = { "start" => start ? "true" : "false" }
      settings.each { |key, value| fields[key.to_s] = value.to_s unless value.nil? }
      raw = multipart(fields, "file", name, content)
      headers = { "Idempotency-Key" => idempotency_key || SecureRandom.uuid }

      attempt = 0
      begin
        call(Net::HTTP::Post, "/batches", raw: raw, headers: headers)
      rescue Error => e
        raise unless RETRYABLE.include?(e.status) && attempt < retries
        pause(2**attempt); attempt += 1
        retry
      rescue *NETWORK_ERRORS
        raise unless attempt < retries
        pause(2**attempt); attempt += 1
        retry
      end
    end

    # Start a job uploaded with `start: false`.
    def start(id, name_column:, **settings)
      call(Net::HTTP::Post, "/batches/#{escape(id)}/start", { name_column: name_column }.merge(settings).compact)
    end
    def get(id)
      call(Net::HTTP::Get, "/batches/#{escape(id)}")
    end
    # Newest first. Includes jobs started from the dashboard.
    def list(limit: nil, page: nil)
      query = URI.encode_www_form({ limit: limit, page: page }.compact)
      call(Net::HTTP::Get, "/batches" + (query.empty? ? "" : "?#{query}"))
    end
    # Cancel a job that has not started (credit is returned), or delete a finished one.
    def cancel(id)
      call(Net::HTTP::Delete, "/batches/#{escape(id)}")
      nil
    end

    # Poll until the job is completed, failed or cancelled, and return it.
    # A failed job is returned, not raised: check "status" and "error"["code"].
    # `on_progress` (or a block) is called with the job after every poll.
    def wait(id, timeout: 3600, on_progress: nil, &block)
      on_progress ||= block
      deadline = now + timeout
      loop do
        job = get(id)
        on_progress&.call(job)
        return job if FINISHED.include?(job["status"]) || job["status"] == "uploaded"
        seconds = job["poll_after_seconds"] || 5
        raise Error.new("Timed out waiting for #{id}", 0, job) if now + seconds > deadline
        pause(seconds)
      end
    end

    # The result file as a binary String, or written to `path` (which is then returned).
    def download(id, path = nil)
      content = @client.send(:transmit, Net::HTTP::Get, "/batches/#{escape(id)}/result").body.to_s.b
      return content if path.nil?
      File.binwrite(path, content)
      path
    end

    private
    def call(klass, path, body = nil, **options)
      @client.send(:request, klass, path, body, **options)
    end
    def pause(seconds)
      sleep(seconds)
    end
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    def escape(id)
      id.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |char| format("%%%02X", char.ord) }
    end
    def read_file(file, filename)
      if file.is_a?(String) && file.encoding == Encoding::BINARY
        raise ArgumentError, "filename is required when file is a binary String" if filename.to_s.empty?
        [file, filename]
      elsif file.is_a?(String) || (defined?(Pathname) && file.is_a?(Pathname))
        [File.binread(file.to_s), filename || File.basename(file.to_s)]
      elsif file.respond_to?(:read)
        name = filename || (File.basename(file.path.to_s) if file.respond_to?(:path) && file.path)
        raise ArgumentError, "filename is required when the IO has no path" if name.to_s.empty?
        [file.read.to_s.b, name]
      else
        raise TypeError, "file must be a path, a binary String or an IO"
      end
    end
    def multipart(fields, file_field, filename, content)
      boundary = SecureRandom.hex(16)
      lines = []
      fields.each { |key, value| lines.push("--#{boundary}", %(Content-Disposition: form-data; name="#{key}"), "", value) }
      # A quote or line break in a file name would end the header early.
      safe = filename.to_s.gsub("\\", "\\\\\\\\").gsub('"', "%22").delete("\r\n")
      head = (lines + [
        "--#{boundary}",
        %(Content-Disposition: form-data; name="#{file_field}"; filename="#{safe}"),
        "Content-Type: application/octet-stream",
        "", ""
      ]).join("\r\n")
      [head.b + content.b + "\r\n--#{boundary}--\r\n".b, "multipart/form-data; boundary=#{boundary}"]
    end
  end

  # Webhook signature check.
  #
  # Pass the body exactly as received (`request.raw_post` in Rails,
  # `request.body.read` in Sinatra and Rack). Parsing the JSON and serialising
  # it again changes the bytes, and the signature no longer matches.
  module Webhooks
    module_function

    # Check the NameGender-Signature header and return the parsed event.
    # During a secret rotation the header carries two v1 values; either one
    # matching is enough.
    def verify(payload, signature_header, secret, tolerance: 300, now: nil)
      raise ArgumentError, "secret is required" if secret.to_s.empty?
      raise WebhookVerificationError, "Missing NameGender-Signature header" if signature_header.to_s.empty?
      raise TypeError, "payload must be the raw request body (a String)" unless payload.is_a?(String)

      timestamp = nil
      signatures = []
      signature_header.to_s.split(",").each do |part|
        key, value = part.strip.split("=", 2)
        if key == "t" && value.to_s.match?(/\A\d+\z/)
          timestamp = value.to_i
        elsif key == "v1" && !value.to_s.empty?
          signatures << value
        end
      end
      raise WebhookVerificationError, "Malformed NameGender-Signature header" if timestamp.nil? || signatures.empty?

      if ((now || Time.now.to_f) - timestamp).abs > tolerance
        raise WebhookVerificationError, "Webhook timestamp is outside the tolerance window"
      end

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.".b + payload.b)
      unless signatures.any? { |signature| OpenSSL.secure_compare(expected, signature) }
        raise WebhookVerificationError, "Webhook signature does not match"
      end

      JSON.parse(payload.b.force_encoding(Encoding::UTF_8))
    end
  end
end
