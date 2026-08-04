require "date"
require "json"

module Health
  module Commands
    # The shared body of every FHIR record listing — `meds`, `problems`,
    # `allergies`, `shots`, `docs`.
    #
    # All five do the same five things: search one resource type, pull a handful
    # of fields out of each result, drop what falls outside a date window, sort,
    # and print a table or JSON. What differs between them is a resource name, a
    # column list, and one `extract` method, so that is all a subclass provides.
    #
    # The date window is applied here, to the extracted `:date`, rather than
    # sent as a FHIR search parameter. Millennium supports `date` on some of
    # these resource types and ignores it on others, and an ignored filter is
    # worse than no filter: it answers a narrow question with a wide list and
    # nothing says so.
    class Resource
      # Subclasses override these three.
      def resource_type = raise(NotImplementedError)

      # [key, label, options] per column, in print order. `options` is passed
      # through to Health::Table (:align, :max).
      def columns = raise(NotImplementedError)

      # One FHIR resource Hash in, one flat Hash of symbol keys out. Keys that
      # appear in `columns` are printed; the rest are carried into --json.
      def extract(_resource) = raise(NotImplementedError)

      # What to call these in a message. Plural.
      def noun = raise(NotImplementedError)

      # Overridden where dropping the "s" is not the singular — "1 allergie."
      # is the kind of thing a reader stops on, in output whose whole job is to
      # be read carefully.
      def singular = noun.sub(/s\z/, "")

      # Newest first, which is right for every one of these: a medication list,
      # a problem list and a document list are all read from the top.
      def sort_key(item) = item[:date].to_s

      def initialize(global, client_factory: nil, io: $stdout, err: $stderr)
        @global = global
        @io = io
        @err = err
        @client_factory = client_factory ||
          ->(config, progress) { FHIR::Client.new(config, progress: progress) }
      end

      def run(argv) = with_progress { execute(parse!(argv.dup)) }

      private

      # Every path out of here — a table, a JSON document, a raised error, a
      # Ctrl-C — has to leave the terminal as it found it, so the reporter is
      # closed in an `ensure` rather than after the work.
      def with_progress
        yield
      ensure
        progress.finish
      end

      # Progress is stderr, so a piped `--json` stays clean; suppressed entirely
      # under --quiet, and line-by-line rather than redrawn under --verbose.
      def progress
        @progress ||= Progress.for(@err, quiet: @global.quiet, verbose: @global.verbose)
      end

      # Split from `run` so a subclass that takes over the argv (`docs --get`)
      # parses once and hands the same options back here.
      def execute(opts)
        items = collect(opts)

        return emit_json(items) if @global.json

        print_table(items)
        0
      end

      attr_reader :opts

      def client
        @client ||= @client_factory.call(Health::Config.load, progress)
      end

      def collect(opts)
        @opts = opts
        items = client.search(resource_type).map { |r| extract(r) }
        # The waiting is over here, and the table is about to be printed to
        # stdout — which would otherwise land on the line the ticker is still
        # redrawing on stderr.
        progress.finish
        items = filter(items, opts)
        items.sort_by { |i| sort_key(i) }.reverse
      end

      # An undated item is kept rather than dropped, the same way `health labs`
      # keeps one. Dropping makes a medication silently absent from a list the
      # operator is reading *as* their medication list; keeping it prints a row
      # with a blank date, which a reader can see and question.
      def filter(items, opts)
        items = items.select { |i| i[:date].nil? || i[:date] >= opts[:since].to_s } if opts[:since]
        items = items.select { |i| i[:date].nil? || i[:date] <= opts[:until].to_s } if opts[:until]
        items
      end

      def emit_json(items)
        @io.puts JSON.pretty_generate(items)
        # The document stays the array it has always been — the count of what
        # was withheld goes to stderr, where every other count in this tool
        # goes, so `--json | jq` is unaffected and the operator still hears it.
        hidden_note unless @global.quiet
        0
      end

      def print_table(items)
        if items.empty?
          unless @global.quiet
            @err.puts "health: no #{noun} matched."
            # Said here too, and not only alongside a count. A record whose
            # every prescription is completed otherwise answers "no medications
            # matched", which reads as "you are on no medications" — in exactly
            # the case where the hint about `--all` is the whole answer.
            hidden_note
          end
          return
        end

        table = Table.new(*columns.map { |key, label, options| [label, options] })
        keys = columns.map(&:first)
        table.render(items.map { |i| keys.map { |k| i[k] } }).each { |line| @io.puts line }

        summarize(items)
      end

      def summarize(items)
        return if @global.quiet

        @err.puts "#{items.size} #{(items.size == 1) ? singular : noun}."
        notes(items)
        hidden_note
      end

      # What a command wants to say about the rows it printed.
      def notes(_items) = nil

      # What a command wants to say about the rows it didn't. Overridden by
      # every command that filters by default, and said on all three paths —
      # table, empty table, and JSON.
      def hidden_note = nil

      # Millennium records clinicalStatus and verificationStatus separately,
      # and reading only the first prints a refuted allergy as an ordinary
      # one. Anything but "confirmed" is worth a reader's attention, so it
      # rides along in the same cell rather than paying for a column.
      def qualified_status(resource)
        clinical = FHIR.status_code(resource["clinicalStatus"])
        verification = FHIR.status_code(resource["verificationStatus"])
        return clinical if verification.nil? || verification == "confirmed"

        [clinical, "(#{verification})"].compact.join(" ")
      end

      # Subclasses that take their own flags override this and call `super` for
      # anything they don't recognise.
      def parse!(argv)
        opts = {}
        while (arg = argv.shift)
          consume(arg, argv, opts)
        end
        opts
      end

      def consume(arg, argv, opts)
        case arg
        when "--since" then opts[:since] = date!(argv.shift, arg)
        when "--until" then opts[:until] = date!(argv.shift, arg)
        else raise Args::BadArgument, "unknown #{noun} option: #{arg}"
        end
      end

      def value!(value, flag)
        raise Args::BadArgument, "#{flag} needs a value" if value.nil?

        value
      end

      def date!(value, flag)
        Date.strptime(value!(value, flag), "%Y-%m-%d")
      rescue Date::Error
        raise Args::BadArgument, "#{flag} needs a date as YYYY-MM-DD (got #{value.inspect})"
      end
    end
  end
end
