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

        session = @session_factory.call(Health::Config.load, tenant)
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
        existed = session.store.exist?
        session.logout!
        @io.puts(existed ? "Signed out; token store removed." : "No token store to remove.")
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
