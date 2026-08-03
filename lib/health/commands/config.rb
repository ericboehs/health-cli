require "json"

module Health
  module Commands
    class Config
      SUBCOMMANDS = %w[init show path edit].freeze

      def initialize(global, io: $stdout, err: $stderr)
        @global = global
        @io = io
        @err = err
      end

      def run(argv)
        sub = argv.shift || "show"
        raise Args::BadArgument, "unknown config subcommand: #{sub} (expected: #{SUBCOMMANDS.join(", ")})" unless SUBCOMMANDS.include?(sub)

        send(sub, argv)
      end

      private

      def init(argv)
        client_id = argv.shift
        if Health::Config.write_default!(client_id: client_id)
          @io.puts "Wrote #{Health::Config.config_path}"
          @io.puts "Set your client_id, then run `health auth login`." unless client_id
        else
          @io.puts "#{Health::Config.config_path} already exists; leaving it alone."
        end
        0
      end

      def path(_argv)
        @io.puts Health::Config.config_path
        0
      end

      def show(_argv)
        config = Health::Config.load
        # Print the file as written rather than the resolved values: an op://
        # reference should stay a reference on screen, never be expanded into
        # the secret it points at.
        @io.puts JSON.pretty_generate(config.data)
        0
      end

      def edit(_argv)
        Health::Config.write_default! unless Health::Config.config_path.exist?
        editor = ENV["VISUAL"] || ENV["EDITOR"] || "vi"
        system(editor, Health::Config.config_path.to_s) ? 0 : 1
      end
    end
  end
end
