require "health/error"

module Health
  # What every future resource command will actually depend on: "give me a
  # usable access token." Keeps refresh-vs-reauth logic in one place so no
  # command has to reason about 570-second expiry.
  class Session
    class NotAuthenticated < Health::Error; end

    def initialize(config, tenant: nil, store: nil, oauth: nil, io: $stderr)
      @config = config
      @tenant = tenant
      @store = store || TokenStore.new(config, tenant: tenant)
      @oauth = oauth || OAuth.new(config, tenant: tenant, io: io)
      @io = io
    end

    attr_reader :store, :oauth

    def tokens
      @tokens ||= (@store.exist? ? @store.read : nil)
    end

    def authenticated? = !tokens.nil? && !tokens["access_token"].to_s.empty?

    # Returns a live access token, refreshing first if the current one is at or
    # near expiry. Raises NotAuthenticated when a browser round-trip is
    # genuinely required, so callers can print one clear instruction.
    def access_token!
      unless authenticated?
        raise NotAuthenticated, "not signed in — run `health auth login`"
      end

      return tokens["access_token"] unless TokenStore.expired?(tokens)

      if tokens["refresh_token"].to_s.empty?
        raise NotAuthenticated, "access token expired and no refresh token is stored — " \
                                "run `health auth login`"
      end

      refresh!["access_token"]
    end

    def refresh!
      current = tokens
      raise NotAuthenticated, "not signed in — run `health auth login`" if current.nil?

      refresh_token = current["refresh_token"].to_s
      raise NotAuthenticated, "no refresh token stored — run `health auth login`" if refresh_token.empty?

      response = @oauth.refresh(refresh_token)
      persist(response, existing: current)
    rescue OAuth::Error => e
      # Cerner deliberately does not distinguish "revoked" from "suspended", and
      # a suspension can be triggered by things outside our control. Re-auth is
      # the only remedy either way, so say that instead of surfacing a raw error.
      #
      # But only for the errors that actually mean the grant is gone. A 502 from
      # the token endpoint, or a connection that never opened, is the provider
      # having a bad minute — telling the operator to re-authorize sends them
      # through a browser login that fixes nothing and, on a bad day, spends a
      # working refresh token to find that out.
      raise unless invalid_grant?(e)

      raise NotAuthenticated, "#{e.message}\nThe stored grant is no longer valid — " \
                              "run `health auth login` to re-authorize."
    end

    def login!
      response = @oauth.login!
      persist(response)
    end

    def logout!
      @store.clear
      @tokens = nil
      true
    end

    def summary = TokenStore.summary(tokens)

    private

    # The OAuth error codes that mean "this grant will never work again"
    # (RFC 6749 §5.2). Everything else — 5xx, a timeout, a rate limit — is
    # transient or unrelated and keeps its own message.
    TERMINAL = /\b(invalid_grant|invalid_client|unauthorized_client|invalid_scope)\b/

    def invalid_grant?(error) = error.message.match?(TERMINAL)

    def persist(response, existing: nil)
      merged = @store.merge_response(response, tenant: @oauth.tenant_id, existing: existing)
      @store.write(merged)
      @tokens = merged
    end
  end
end
