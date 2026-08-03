require "json"

require "health/portal"

module Health
  module Portal
    # Keeps a signed-in portal session on disk so every command does not have
    # to sign in again.
    #
    # Worth being precise about what this holds: `cloud-session` is a live
    # credential to the whole medical record, not a token with a scope. It is
    # therefore stored exactly like the OAuth tokens are — age-encrypted to an
    # SSH key, 0600 — which is also what keeps this non-interactive, since a
    # read needs the private key on disk rather than a prompt.
    #
    # The alternative, caching the password instead, would trade one prompt for
    # a worse secret at rest and still pay the SAML round-trip every run.
    class SessionStore
      class Error < Portal::Error; end

      FILENAME = "portal-session.age".freeze

      def initialize(config, encryption: Encryption.new, path: nil)
        @config = config
        @encryption = encryption
        @path = path || Config.data_dir.join(FILENAME)
      end

      attr_reader :path

      def exist? = File.exist?(@path)

      # Returns nil rather than raising when the cache is unusable: a bad cache
      # only means signing in again, which the caller is able to do anyway.
      def load
        return nil unless exist?

        raw = @encryption.decrypt(@path, @config.ssh_key)
        data = JSON.parse(raw.to_s)
        person_id = data["person_id"]
        return nil if person_id.to_s.empty?

        { person_id: person_id, jar: CookieJar.restore(data["cookies"]) }
      rescue JSON::ParserError, Encryption::Error
        nil
      end

      def save(jar:, person_id:)
        Config.ensure_dirs!
        payload = { "person_id" => person_id, "cookies" => jar.dump, "saved_at" => Time.now.to_i }
        @encryption.encrypt(JSON.generate(payload), @config.ssh_key, @path)
        @path
      end

      def clear
        File.unlink(@path) if exist?
        true
      end
    end
  end
end
