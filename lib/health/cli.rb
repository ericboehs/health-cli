module Health
  # A Data object rather than a Hash so a typo like `@global.jsn` raises instead
  # of quietly reading nil.
  GlobalOptions = Data.define(:json, :quiet, :verbose)

  class CLI
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
      else
        warn "unknown command: #{cmd}"
        warn help_text
        2
      end
    rescue Commands::Args::BadArgument => e
      warn "health: #{e.message}"
      2
    rescue Health::Config::Error, Encryption::Error, TokenStore::Error, OAuth::Error => e
      warn "health: #{e.message}"
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
      HELP
    end
  end
end
