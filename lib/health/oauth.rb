require "net/http"
require "uri"
require "json"
require "socket"
require "openssl"
require "securerandom"
require "fileutils"

require "health/error"

module Health
  # SMART on FHIR standalone-patient authorization-code flow, hand-rolled on
  # stdlib. No fhir_client: its OAuth support is the client-credentials flow
  # (wrong grant), it has no PKCE, and it costs ~1s of startup for a CLI whose
  # whole point is being fast.
  class OAuth
    class Error < Health::Error; end
    class Denied < Error; end

    DISCOVERY_TTL = 86_400 # SMART config changes ~never; a day is plenty.
    LISTEN_TIMEOUT = 300   # Long enough to finish a Cerner Health login + 2FA.

    def initialize(config, tenant: nil, io: $stderr)
      @config = config
      @tenant = tenant
      @io = io
    end

    def tenant_id = @config.tenant_id(@tenant)

    # ---------------------------------------------------------------- discovery

    def discovery
      @discovery ||= begin
        cached = read_cached_discovery
        cached || fetch_discovery
      end
    end

    def authorization_endpoint = discovery.fetch("authorization_endpoint")
    def token_endpoint = discovery.fetch("token_endpoint")

    # These tenants advertise `client-public` yet omit `none` from
    # token_endpoint_auth_methods_supported. We send no client authentication
    # (correct for a public client) and let the server object if it disagrees.
    def pkce_supported?
      Array(discovery["code_challenge_methods_supported"]).include?("S256")
    end

    # ------------------------------------------------------------------- login

    def login!
      verifier = SecureRandom.urlsafe_base64(64)
      state = SecureRandom.urlsafe_base64(24)
      url = authorize_url(state: state, verifier: verifier)

      server = TCPServer.new("127.0.0.1", @config.redirect_port)
      begin
        @io.puts "Opening browser for Cerner Health sign-in…"
        @io.puts "If it doesn't open, visit:\n  #{url}\n\n"
        open_browser(url)

        code = await_code(server, expected_state: state)
      ensure
        # `close` is a no-op on an already-closed socket, so the guard this
        # used to carry only described a state nothing here can produce.
        server.close
      end

      exchange_code(code, verifier: verifier)
    rescue Errno::EADDRINUSE
      raise Error, "port #{@config.redirect_port} is already in use — free it, or change " \
                   "redirect_uri in #{Config.config_path} (and re-register the new URI)"
    end

    def authorize_url(state:, verifier:)
      params = {
        "response_type" => "code",
        "client_id" => require_client_id,
        "redirect_uri" => @config.redirect_uri,
        "scope" => @config.scopes.join(" "),
        "state" => state,
        "aud" => @config.fhir_base(@tenant)
      }
      # Sent even when the tenant doesn't advertise S256. PKCE is defense
      # against code interception on the loopback and unknown authorize params
      # are ignored per RFC 6749 — but `pkce: false` in config is the escape
      # hatch if a tenant turns out to reject it.
      if pkce?
        params["code_challenge"] = challenge_for(verifier)
        params["code_challenge_method"] = "S256"
      end

      "#{authorization_endpoint}?#{URI.encode_www_form(params)}"
    end

    def challenge_for(verifier)
      b64url(OpenSSL::Digest::SHA256.digest(verifier))
    end

    # ------------------------------------------------------------------ tokens

    def exchange_code(code, verifier:)
      form = {
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @config.redirect_uri,
        "client_id" => require_client_id
      }
      form["code_verifier"] = verifier if pkce?
      post_token(form)
    end

    def refresh(refresh_token)
      post_token(
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => require_client_id,
        # Asking for the same scopes keeps a refresh from silently narrowing the
        # grant, which would surface much later as a 403 on one resource.
        "scope" => @config.scopes.join(" ")
      )
    end

    private

    def pkce? = @config.data.fetch("pkce", true)

    def require_client_id
      id = @config.client_id
      raise Error, "no client_id in #{Config.config_path} — run `health config init`" if id.to_s.empty?
      raise Error, "client_id is still the placeholder — paste your real client_id" if id.start_with?("PASTE-")

      id
    end

    def post_token(form)
      uri = URI(token_endpoint)
      req = Net::HTTP::Post.new(uri)
      req["Accept"] = "application/json"
      req.set_form_data(form)

      res = http(uri).request(req)
      body = parse_json(res.body)

      unless res.is_a?(Net::HTTPSuccess)
        # `parse_json` already guarantees a Hash, so this needs no shape check
        # of its own — and the nil one used to produce here would have raised
        # NoMethodError on the next line rather than the error it was reporting.
        detail = [body["error"], body["error_description"]].compact.join(": ")
        raise Error, "token request failed (HTTP #{res.code})#{detail.empty? ? "" : " — #{detail}"}"
      end

      raise Error, "token response contained no access_token" if body["access_token"].to_s.empty?

      body
    end

    # ----------------------------------------------------------- loopback

    # Serves exactly the redirect. Anything else (favicon, a stray refresh)
    # gets a 404 and the listener keeps waiting, so one bad request doesn't
    # abort a login the user is midway through.
    def await_code(server, expected_state:)
      deadline = Time.now + LISTEN_TIMEOUT

      loop do
        remaining = deadline - Time.now
        raise Error, "timed out waiting for the browser redirect" if remaining <= 0
        raise Error, "timed out waiting for the browser redirect" unless IO.select([server], nil, nil, remaining)

        conn = server.accept
        begin
          line = conn.gets
          next respond(conn, 400, "Bad request.") if line.nil?

          path = line.split(" ")[1].to_s
          uri = URI("http://localhost#{path}")
          unless uri.path == @config.redirect_path
            respond(conn, 404, "Not found.")
            next
          end

          params = URI.decode_www_form(uri.query.to_s).to_h

          if params["error"]
            respond(conn, 200, "Authorization denied. You can close this tab.")
            raise Denied, "authorization denied: " \
                          "#{[params["error"], params["error_description"]].compact.join(": ")}"
          end

          # A mismatched state means this redirect isn't the one we started —
          # treat it as hostile and refuse the code rather than exchanging it.
          unless params["state"] == expected_state
            respond(conn, 400, "State mismatch. You can close this tab.")
            raise Error, "state mismatch on redirect — login aborted"
          end

          if params["code"].to_s.empty?
            respond(conn, 400, "No authorization code. You can close this tab.")
            raise Error, "redirect contained no authorization code"
          end

          respond(conn, 200, "health-cli is authorized. You can close this tab.")
          return params["code"]
        ensure
          conn.close
        end
      end
    end

    def respond(conn, status, message)
      text = { 200 => "OK", 400 => "Bad Request", 404 => "Not Found" }.fetch(status, "OK")
      body = "<!doctype html><meta charset=utf-8>" \
             "<title>health-cli</title>" \
             "<body style='font:16px -apple-system,sans-serif;padding:3rem'>#{message}</body>"
      conn.print("HTTP/1.1 #{status} #{text}\r\n" \
                 "Content-Type: text/html; charset=utf-8\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
    # :nocov: reachable only when the browser resets the connection mid-write.
    rescue Errno::EPIPE
      # Browser hung up early; the code was still captured.
      nil
      # :nocov:
    end

    # :nocov: covered by overriding this in tests — running it for real would
    # open Safari on the machine running the suite.
    def open_browser(url)
      # Safari is the established browser on this machine, but fall back to the
      # default handler so a login is never blocked by Safari being absent.
      return if system("open", "-a", "Safari", url, out: File::NULL, err: File::NULL)

      system("open", url, out: File::NULL, err: File::NULL)
    end
    # :nocov:

    # ---------------------------------------------------------------- plumbing

    def discovery_cache_path
      Config.cache_dir.join("smart-config-#{tenant_id}.json")
    end

    def read_cached_discovery
      path = discovery_cache_path
      return nil unless path.exist?
      return nil if Time.now - path.mtime > DISCOVERY_TTL

      value = JSON.parse(path.read)
      # Never trust a cached empty result: it means a failed fetch got written,
      # and honoring it would pin the failure for a full day.
      value.is_a?(Hash) && value["authorization_endpoint"] ? value : nil
    rescue JSON::ParserError
      nil
    end

    def fetch_discovery
      uri = URI("#{@config.fhir_base(@tenant)}.well-known/smart-configuration")
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      res = http(uri).request(req)

      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "SMART discovery failed for tenant #{tenant_id} (HTTP #{res.code})"
      end

      value = parse_json(res.body)
      unless value.is_a?(Hash) && value["authorization_endpoint"] && value["token_endpoint"]
        raise Error, "SMART discovery for tenant #{tenant_id} was missing endpoints"
      end

      Config.ensure_dirs!
      discovery_cache_path.write(JSON.generate(value))
      value
    end

    def http(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |h|
        h.use_ssl = uri.scheme == "https"
        h.verify_mode = OpenSSL::SSL::VERIFY_PEER
        h.open_timeout = 15
        h.read_timeout = 30
      end
    end

    # Always a Hash. `null`, `[]`, `"str"` and `0` are all valid JSON, and every
    # caller here indexes the result by key — so a token endpoint answering with
    # a non-object used to raise NoMethodError or TypeError, neither of which is
    # an OAuth::Error, and both of which escaped the top-level rescue.
    def parse_json(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def b64url(bytes)
      [bytes].pack("m0").tr("+/", "-_").delete("=")
    end
  end
end
