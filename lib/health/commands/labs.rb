require "date"
require "json"

module Health
  module Commands
    # `health labs` — lab and vital results with their reference ranges.
    #
    # Reads the portal rather than FHIR because the FHIR endpoint returns lab
    # Observations with neither a value nor a range; see Health::Portal.
    #
    # What comes back is the most recent value for each analyte in the window,
    # not every draw, because that is what the portal's results section serves.
    # A window narrows which value is "most recent"; it does not turn the list
    # into a history. `--history <analyte>` is what asks for the rest.
    class Labs
      # The record predates any window worth asking about, and the portal
      # returns a decade in a single response, so a wide default costs nothing.
      EARLIEST = Date.new(2010, 1, 1)

      # Vitals and labs arrive in the same payload with nothing but the panel
      # name to tell them apart — no category, no code, and `item.type` merely
      # repeats the name. So this list is a naming convention, not a contract;
      # `--vitals` and `--panel` exist for when it is wrong.
      VITALS = [/\Avital signs/i, /\Ameasurements/i, /\Aheight/i, /\Aweight/i, /\Abody mass index/i].freeze

      def initialize(global, record_factory: nil, io: $stdout, err: $stderr)
        @global = global
        @io = io
        @err = err
        @record_factory = record_factory || ->(config, log) { Portal::Record.open(config, io: log) }
      end

      def run(argv)
        opts = parse!(argv.dup)
        results = select(opts[:history] ? history(opts) : fetch(opts), opts)

        return emit_json(results) if @global.json

        print_table(results, history: opts[:history])
        0
      end

      private

      def record
        # Sign-in progress is chatter, not output — it goes to stderr so a
        # piped `--json` stays clean, and nowhere at all under --quiet.
        @record ||= @record_factory.call(Health::Config.load, @global.quiet ? nil : @err)
      end

      def window(opts) = [opts[:since] || EARLIEST, opts[:until] || Date.today]

      def fetch(opts)
        from, to = window(opts)
        Portal::Results.parse(record.results(from: from, to: to))
      end

      # `--history` is a different question from the default listing — "every
      # draw of this one analyte" rather than "the latest of each" — and it is
      # answered by a different endpoint, keyed by an id that has to be looked
      # up first.
      def history(opts)
        from, to = window(opts)
        index = record.history_index(from: from, to: to)

        # An empty index is not "you named an analyte your record doesn't have"
        # — `resolve` would say that, as a usage error, and send the operator
        # hunting for a typo in a spelling that was right. It means the results
        # page stopped carrying the markup HistoryIndex reads.
        if index.empty?
          raise Portal::Error, "the results page carried no analyte history links — " \
                               "the portal's markup has probably changed"
        end

        entry = resolve(index, opts)
        results = Portal::Results.parse_history(record.history(entry.uuid), panel: entry.panel)
        cross_check!(results, entry)
        results
      end

      # The index pairs a name with an id by their order in the page's markup;
      # the history payload names its own analyte. Comparing the two is the only
      # available check that the pairing still holds, and it matters more than
      # any other here: if it doesn't hold, the output is one analyte's values
      # printed under another's name — the worst thing this tool can produce.
      #
      # Containment rather than equality, because the page's heading and the
      # payload's name are two labels for one thing and needn't be spelled alike
      # ("Hgb" against "Hgb A1c" is caught either way; the risk this guards is a
      # wholesale mispairing, not a punctuation difference).
      def cross_check!(results, entry)
        wanted = entry.analyte.to_s.downcase
        names = results.filter_map { |r| presence(r.analyte) }.uniq
        return if wanted.empty? || names.empty?
        return if names.all? { |n| n.include?(wanted) || wanted.include?(n) }

        raise Portal::Error, "asked for #{entry.analyte.inspect} but the portal returned " \
                             "#{names.join(", ")} — the results page markup has probably changed"
      end

      def presence(value)
        text = value.to_s.downcase.strip
        text.empty? ? nil : text
      end

      def resolve(index, opts)
        wanted = opts[:history].downcase
        index = index.select { |e| e.panel.to_s.downcase.include?(opts[:panel]) } if opts[:panel]

        # An exact name wins outright, so `--history Hgb` is not made ambiguous
        # by the existence of "Hgb A1c".
        matches = index.select { |e| e.analyte.to_s.downcase == wanted }
        matches = index.select { |e| e.analyte.to_s.downcase.include?(wanted) } if matches.empty?

        raise Args::BadArgument, "no analyte matching #{opts[:history].inspect}" if matches.empty?

        unless matches.map(&:uuid).uniq.size == 1
          raise Args::BadArgument, "#{opts[:history].inspect} matches several analytes: " \
                                   "#{matches.map(&:analyte).uniq.join(", ")}"
        end

        matches.first
      end

      def select(results, opts)
        # The window is applied again here rather than trusted to the portal:
        # it is an undocumented query parameter, and a silently ignored one
        # would otherwise show results outside the range that was asked for.
        #
        # An undated result can't be placed in the window in either direction,
        # so it is kept rather than dropped: the row prints its (blank) date and
        # a reader can see what happened, where dropping makes a lab value
        # vanish with no trace. Dates are ISO-8601, where string order is date
        # order.
        results = results.select { |r| r.collected_on.empty? || r.collected_on >= opts[:since].to_s } if opts[:since]
        results = results.select { |r| r.collected_on.empty? || r.collected_on <= opts[:until].to_s } if opts[:until]

        results = results.select { |r| r.panel.to_s.downcase.include?(opts[:panel]) } if opts[:panel]
        results = results.select { |r| vitals?(r) == opts[:vitals] } if opts.key?(:vitals)
        results = results.select(&:abnormal?) if opts[:abnormal]

        # A history is one analyte over time, so date is the axis worth
        # sorting on — newest first, the way the portal presents it.
        return results.sort_by { |r| r.collected_on.to_s }.reverse if opts[:history]

        results.sort_by { |r| [r.panel.to_s, r.analyte.to_s] }
      end

      def vitals?(result) = VITALS.any? { |pattern| result.panel.to_s.match?(pattern) }

      def emit_json(results)
        @io.puts JSON.pretty_generate(results.map { |r| r.to_h.merge(status: r.status, critical: r.critical?) })
        0
      end

      def print_table(results, history: nil)
        if results.empty?
          @err.puts "health: no results matched." unless @global.quiet
          return
        end

        widths = column_widths(results)
        results.chunk_while { |a, b| a.panel == b.panel }.each do |group|
          @io.puts [group.first.panel, history && group.first.analyte].compact.join(" — ")
          group.each { |r| @io.puts row(r, widths, history: history) }
          @io.puts
        end

        summarize(results, history: history)
      end

      # Measured rather than fixed: units run from "%" to "mL/min/1.73m^2", and
      # a fixed width either wastes a screen or lets one long unit shove every
      # column after it out of alignment.
      def column_widths(results)
        {
          analyte: width_of(results, &:analyte),
          value: width_of(results, &:value),
          units: width_of(results, &:units),
          range: width_of(results, &:range),
          flag: width_of(results, &:flag)
        }
      end

      def width_of(results, &field) = results.map { |r| field.call(r).to_s.length }.max

      # In a history every row is the same analyte and the heading already says
      # so, so that column is dropped and the date leads instead.
      def row(result, w, history: nil)
        cells = [format("%-#{w[:analyte]}s", result.analyte)]
        cells = [result.collected_on.to_s] if history
        cells += [format("%#{w[:value]}s", result.value), format("%-#{w[:units]}s", result.units),
          format("%-#{w[:range]}s", result.range), format("%-#{w[:flag]}s", result.flag)]
        cells << result.collected_on unless history

        "  #{cells.join("  ")}".rstrip
      end

      def summarize(results, history: nil)
        return if @global.quiet

        out = results.count(&:abnormal?)
        noun = history ? "draws" : "results"
        # Say "recomputed", because the portal's own normalcy field disagrees
        # with this count and that difference is the whole point.
        @err.puts "#{results.size} #{noun}, #{out} outside the stated reference range (recomputed)."

        # Without this the two counts read as a partition and they are not:
        # qualitative results and results the portal ships no range for are in
        # neither, and "0 outside the range" would otherwise imply they were
        # checked and passed.
        unchecked = results.count { |r| r.status == :unknown }
        @err.puts "#{unchecked} could not be checked — no reference range, or not a single number." if unchecked.positive?

        earlier = results.count(&:truncated)
        return if earlier.zero?

        verb = (earlier == 1) ? "has" : "have"
        @err.puts "#{earlier} of them #{verb} earlier values on record; " \
                  "see `health labs --history <analyte>`."
      end

      def parse!(argv)
        opts = {}
        while (arg = argv.shift)
          case arg
          when "--since"     then opts[:since] = date!(argv.shift, arg)
          when "--until"     then opts[:until] = date!(argv.shift, arg)
          when "--panel"     then opts[:panel] = value!(argv.shift, arg).downcase
          when "--history"   then opts[:history] = value!(argv.shift, arg)
          when "--abnormal"  then opts[:abnormal] = true
          when "--vitals"    then opts[:vitals] = true
          when "--no-vitals" then opts[:vitals] = false
          else raise Args::BadArgument, "unknown labs option: #{arg}"
          end
        end
        opts
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
