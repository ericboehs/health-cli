require "net/http"
require "openssl"
require "uri"

require "health/error"

module Health
  # A Data object rather than a Hash so a typo like `@global.jsn` raises instead
  # of quietly reading nil.
  GlobalOptions = Data.define(:json, :quiet, :verbose)

  class CLI
    # Everything that can go wrong between this process and the provider.
    # SystemCallError covers the Errno family (ECONNREFUSED, EHOSTUNREACH…) in
    # one entry.
    NETWORK_ERRORS = [
      SocketError, IOError, SystemCallError,
      Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, Net::ProtocolError,
      OpenSSL::SSL::SSLError, URI::Error
    ].freeze

    def self.run(argv) = new.run(argv)

    def run(argv)
      argv = argv.dup
      global = parse_global!(argv)
      cmd = argv.shift || "help"

      case cmd
      when "help", "-h", "--help"
        puts help_text
        0
      when "auth"   then Commands::Auth.new(global).run(argv)
      when "config" then Commands::Config.new(global).run(argv)
      when "labs"   then Commands::Labs.new(global).run(argv)
      else
        warn "unknown command: #{cmd}"
        warn help_text
        2
      end
    rescue Commands::Args::BadArgument => e
      warn "health: #{e.message}"
      2
    # One ancestor rather than a list of classes: see Health::Error for why an
    # unlisted error class is worse here than in most programs.
    rescue Health::Error => e
      warn "health: #{e.message}"
      1
    # Nothing between here and the provider is under this tool's control, and a
    # backtrace out of Net::HTTP would print the request URL — which carries the
    # person id — into whatever the operator pastes into a bug report.
    rescue *NETWORK_ERRORS => e
      warn "health: could not reach the server (#{e.class}: #{e.message})"
      1
    rescue Interrupt
      warn "\nhealth: interrupted"
      130
    end

    private

    def parse_global!(argv)
      json = quiet = verbose = false
      keep = []
      while (a = argv.shift)
        case a
        when "--json"          then json = true
        when "-q", "--quiet"   then quiet = true
        when "-v", "--verbose" then verbose = true
        else keep << a
        end
      end
      argv.replace(keep)
      GlobalOptions.new(json: json, quiet: quiet, verbose: verbose)
    end

    def help_text
      <<~HELP
        Usage: health <command> [options]

        Auth:
          auth login     Sign in via the browser (SMART on FHIR standalone patient launch)
          auth status    Show whether a usable token is stored
          auth refresh   Force a token refresh
          auth logout    Delete the encrypted token store

        Record:
          labs           Latest value per analyte, with reference ranges

        Other:
          config init    Write a starter config
          config show    Print the config as stored
          config path    Print the config file path
          config edit    Open the config in $EDITOR
          help           Show this help

        Global flags:
          --json         Emit JSON instead of formatted output
          -q/--quiet     Suppress non-essential output
          -v/--verbose   Verbose logs

        Auth flags:
          --tenant NAME  One of: #{Health::Config::TENANTS.keys.join(", ")}, or a tenant id

        Labs flags:
          --since DATE   Only results on or after DATE (YYYY-MM-DD)
          --until DATE   Only results on or before DATE (YYYY-MM-DD)
          --panel TEXT   Only panels whose name contains TEXT
          --abnormal     Only results outside their reference range
          --vitals       Only vitals (BP, pulse, weight, BMI)
          --no-vitals    Only labs
          --history NAME Every recorded draw of one analyte, newest first
      HELP
    end
  end
end
