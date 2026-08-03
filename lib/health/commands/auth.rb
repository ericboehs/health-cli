require "json"

module Health
  module Commands
    class Auth
      SUBCOMMANDS = %w[login status refresh logout].freeze

      def initialize(global, session_factory: nil, io: $stdout, err: $stderr)
        @global = global
        @io = io
        @err = err
        @session_factory = session_factory || ->(config, tenant) {
          Session.new(config, tenant: tenant, io: err)
        }
      end

      def run(argv)
        argv = argv.dup
        tenant = extract_tenant!(argv)
        sub = argv.shift || "status"

        unless SUBCOMMANDS.include?(sub)
          raise Args::BadArgument, "unknown auth subcommand: #{sub} (expected: #{SUBCOMMANDS.join(", ")})"
        end

        @config = Health::Config.load
        TokenStore.migrate_legacy!(@config)
        session = @session_factory.call(@config, tenant)
        send(sub, session)
      rescue Session::NotAuthenticated => e
        @err.puts "health: #{e.message}"
        1
      end

      private

      def extract_tenant!(argv)
        idx = argv.index("--tenant")
        return nil unless idx

        value = argv[idx + 1]
        # Health::Config, not Commands::Config: bare `Config` in here resolves to
        # the sibling command class.
        raise Args::BadArgument, "--tenant needs a value (#{Health::Config::TENANTS.keys.join(", ")}, or a tenant id)" if value.nil?

        argv.slice!(idx, 2)
        value
      end

      def login(session)
        session.login!
        emit(session.summary, "Signed in.")
        0
      rescue OAuth::Denied => e
        @err.puts "health: #{e.message}"
        1
      rescue OAuth::Error => e
        @err.puts "health: #{e.message}"
        1
      end

      def status(session)
        summary = session.summary
        if @global.json
          @io.puts JSON.pretty_generate(summary)
        elsif !summary["authenticated"]
          @io.puts "Not signed in. Run `health auth login`."
        else
          print_status(summary)
        end
        summary["authenticated"] ? 0 : 1
      end

      def refresh(session)
        session.refresh!
        emit(session.summary, "Refreshed.")
        0
      end

      def logout(session)
        # Every tenant, not just this one: leaving another tenant's grant on
        # disk would not be signing out. Counted before anything is unlinked.
        stored = TokenStore.paths.size
        session.logout!
        TokenStore.clear_all

        # The cached portal session is a second live credential to the same
        # record; "signed out" has to mean all of them are gone.
        portal = Portal::SessionStore.new(@config)
        portal_existed = portal.exist?
        portal.clear

        @io.puts(stored.zero? ? "No token store to remove." : "Signed out; #{stored} token store#{"s" if stored > 1} removed.")
        @io.puts "Cached portal session removed." if portal_existed
        0
      end

      def emit(summary, message)
        if @global.json
          @io.puts JSON.pretty_generate(summary)
        else
          @io.puts message
          print_status(summary)
        end
      end

      def print_status(s)
        expires = s["access_token_expires_in"]
        expiry = if expires.nil?
          "unknown"
        elsif s["access_token_expired"]
          "expired"
        else
          "#{expires}s"
        end

        @io.puts format("  patient:        %s", s["patient"] || "-")
        @io.puts format("  tenant:         %s", s["tenant"] || "-")
        @io.puts format("  scopes granted: %s", s["scope_count"])
        @io.puts format("  access token:   %s", expiry)
        @io.puts format("  refresh token:  %s", s["has_refresh_token"] ? "stored" : "none")
        @io.puts format("  obtained:       %s", s["obtained_at"] || "-")
      end
    end
  end
end
