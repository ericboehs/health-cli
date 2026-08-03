require "json"
require "time"

require "health/error"

module Health
  # The age-encrypted token store. Everything PHI-adjacent that persists goes
  # through here; nothing in this class ever prints a token value, and callers
  # get `summary` rather than the raw hash when they want to show state.
  class TokenStore
    class Error < Health::Error; end

    # Access tokens are minted with expires_in=570 (9.5 min). Refresh a little
    # early so a long-running command doesn't expire mid-pagination.
    EXPIRY_SKEW = 60

    SECRET_KEYS = %w[access_token refresh_token id_token].freeze

    def initialize(config, tenant: nil, encryption: Encryption.new, path: nil)
      @config = config
      @encryption = encryption
      @path = path || Config.token_path(config.tenant_id(tenant))
    end

    attr_reader :path

    def exist? = File.exist?(@path)

    def read
      raw = @encryption.decrypt(@path, @config.ssh_key)
      return nil if raw.nil? || raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      # A corrupt store is recoverable by re-authenticating, so say that rather
      # than leaking a parse error from a file the user can't read anyway.
      raise Error, "token store at #{@path} is unreadable — run `health auth login` to replace it"
    end

    def write(tokens)
      Config.ensure_dirs!
      @encryption.encrypt(JSON.pretty_generate(tokens) + "\n", @config.ssh_key, @path)
      @path
    end

    def clear
      File.unlink(@path) if exist?
      true
    end

    # Every stored grant, across every tenant.
    def self.paths
      Dir.glob(Config.token_dir.join("*.age").to_s).sort +
        (File.exist?(Config.legacy_token_path) ? [Config.legacy_token_path.to_s] : [])
    end

    def self.clear_all
      paths.each { |p| File.unlink(p) }
      true
    end

    # Moves a pre-split store into its per-tenant home.
    #
    # There used to be one `tokens.age` regardless of tenant, so signing into a
    # second tenant destroyed the first grant. The file records the tenant it
    # belongs to, so the move needs no guessing.
    #
    # Returns the new path, or nil when there was nothing to move. An
    # unreadable or tenant-less store is left where it is rather than deleted:
    # it may still hold the only long-lived refresh token, and `auth login`
    # will supersede it anyway.
    def self.migrate_legacy!(config, encryption: Encryption.new)
      legacy = Config.legacy_token_path
      return nil unless File.exist?(legacy)

      tokens = new(config, encryption: encryption, path: legacy).read
      tenant = tokens && tokens["tenant"]
      return nil if tenant.to_s.empty?

      store = new(config, tenant: tenant, encryption: encryption)
      store.write(tokens)
      File.unlink(legacy)
      store.path
    rescue Error, Encryption::Error
      nil
    end

    # Merges a token endpoint response into what's already stored.
    #
    # Cerner does not rotate refresh tokens: a refresh response contains no
    # `refresh_token` at all. Naively storing the response would therefore wipe
    # the only long-lived credential we have and force a browser round-trip on
    # the very next command.
    def merge_response(response, tenant:, existing: nil)
      prior = existing || (exist? ? read : nil) || {}
      expires_in = (response["expires_in"] || 570).to_i

      prior.merge(
        "access_token" => response["access_token"],
        "refresh_token" => response["refresh_token"] || prior["refresh_token"],
        "expires_at" => (Time.now + expires_in).to_i,
        "scope" => response["scope"] || prior["scope"],
        "patient" => response["patient"] || prior["patient"],
        "tenant" => tenant,
        "obtained_at" => Time.now.to_i
      ).compact
    end

    def self.expired?(tokens, now: Time.now)
      return true if tokens.nil? || tokens["access_token"].to_s.empty?

      tokens["expires_at"].to_i - EXPIRY_SKEW <= now.to_i
    end

    # Safe to print: token values become presence booleans and a length, never
    # a prefix. Even a few characters of a bearer token in a terminal
    # scrollback or a bug report is more than this tool needs to disclose.
    def self.summary(tokens, now: Time.now)
      return { "authenticated" => false } if tokens.nil?

      expires_at = tokens["expires_at"].to_i
      {
        "authenticated" => !tokens["access_token"].to_s.empty?,
        "patient" => tokens["patient"],
        "tenant" => tokens["tenant"],
        "scope_count" => tokens["scope"].to_s.split(/\s+/).reject(&:empty?).size,
        "access_token_expires_in" => expires_at.zero? ? nil : expires_at - now.to_i,
        "access_token_expired" => expired?(tokens, now: now),
        "has_refresh_token" => !tokens["refresh_token"].to_s.empty?,
        "obtained_at" => tokens["obtained_at"] && Time.at(tokens["obtained_at"]).iso8601
      }
    end

    # Strips token values out of anything headed for a log or an error message.
    def self.redact(hash)
      hash.each_with_object({}) do |(k, v), out|
        out[k] = SECRET_KEYS.include?(k) ? "[redacted]" : v
      end
    end
  end
end
