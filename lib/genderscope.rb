require "json"
require "net/http"
require "uri"

module GenderScope
  class Error < StandardError
    attr_reader :status, :body
    def initialize(message, status = 0, body = nil)
      super(message); @status = status; @body = body
    end
  end

  class Client
    def initialize(api_key, base_url: "https://genderscope.io/api/v1")
      raise ArgumentError, "api_key is required" if api_key.to_s.empty?
      @api_key, @base_url = api_key, base_url.sub(%r{/$}, "")
    end

    def name(value, country: nil, **options)
      post("/gender", { name: value, country: country }.merge(options).compact)
    end
    def email(value, country: nil, **options)
      post("/gender/email", { email: value, country: country }.merge(options).compact)
    end
    def username(value, country: nil, **options)
      post("/gender/username", { username: value, country: country }.merge(options).compact)
    end
    def bulk(values, country: nil, type: "name", **options)
      post("/gender/bulk", { names: values, country: country, type: type }.merge(options).compact)
    end
    def account
      request(Net::HTTP::Get, "/me")
    end

    private
    def post(path, body)
      request(Net::HTTP::Post, path, body)
    end
    def request(klass, path, body = nil)
      uri = URI(@base_url + path)
      req = klass.new(uri)
      req["Accept"] = req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
      parsed = JSON.parse(response.body)
      raise Error.new(parsed["message"] || "HTTP #{response.code}", response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)
      parsed
    rescue JSON::ParserError
      raise Error.new("GenderScope returned invalid JSON", response&.code.to_i)
    end
  end
end
