require "net/http"
require "uri"

require "health/portal"

module Health
  module Portal
    # A cookie-aware HTTP client.
    #
    # Redirects are followed manually rather than by `Net::HTTP`'s built-in
    # handling because every hop in the sign-in chain sets cookies that the
    # next hop needs, and because a 302 out of a POST must become a GET.
    class Client
      class Error < Portal::Error; end

      MAX_REDIRECTS = 10
      USER_AGENT = "health-cli (+https://github.com/ericboehs/health-cli)".freeze

      attr_reader :jar

      def initialize(jar: CookieJar.new)
        @jar = jar
      end

      def get(url, accept: "text/html,application/xhtml+xml", headers: {})
        follow(Net::HTTP::Get, URI(url.to_s), nil, accept, headers)
      end

      def post(url, form, accept: "text/html,application/xhtml+xml", headers: {})
        follow(Net::HTTP::Post, URI(url.to_s), form, accept, headers)
      end

      # A single request with no redirect following — used when the caller
      # needs to read a `Location` rather than chase it.
      def head_location(url)
        res = request(Net::HTTP::Get, URI(url.to_s), nil, "text/html", {})
        res["location"]
      end

      private

      def follow(verb, uri, form, accept, headers)
        res = nil
        MAX_REDIRECTS.times do
          res = request(verb, uri, form, accept, headers)
          return res unless res.is_a?(Net::HTTPRedirection)

          uri = URI.join(uri.to_s, res["location"])
          # Per RFC 7231 a 303 — and in practice a 302 out of a form POST —
          # continues as a GET with no body.
          verb = Net::HTTP::Get
          form = nil
        end
        raise Error, "too many redirects (last: #{uri})"
      end

      def request(verb, uri, form, accept, headers)
        req = verb.new(uri)
        req["Accept"] = accept
        req["User-Agent"] = USER_AGENT
        req["Accept-Language"] = "en-US,en;q=0.9"
        headers.each { |k, v| req[k] = v }
        cookies = @jar.header_for(uri)
        req["Cookie"] = cookies if cookies
        req.set_form_data(form) if form

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = 45
        res = http.request(req)

        @jar.absorb(res.get_fields("set-cookie"), uri)
        res.define_singleton_method(:uri) { uri }
        res
      end
    end
  end
end
