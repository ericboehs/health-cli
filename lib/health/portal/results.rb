require "health/portal"

module Health
  module Portal
    # Flattens the portal's nested results payload — panel > result type >
    # result — into one row per analyte, and decides normal from abnormal.
    #
    # Two things about the payload are worth knowing before reading this:
    #
    # It carries its own `normalcy` string, and across this record that field
    # read "Normal" on every result observed — including ones the same payload
    # prints as sitting outside their own reference range, in both directions.
    # The field can evidently hold other values, so it isn't a literal constant;
    # it just never disagreed with itself often enough to be worth trusting. So
    # normalcy is always recomputed here from the reference range the payload
    # itself supplies, and the portal's claim is carried along unused, for
    # comparison.
    #
    # And it returns the *most recent* value per analyte within the requested
    # window, not every draw — a decade-wide window still yields one hematocrit.
    # A result type saying `hasMore` has earlier values behind the per-analyte
    # detail endpoint, which is why `truncated` is surfaced rather than dropped.
    module Results
      Result = Data.define(:panel, :analyte, :value, :number, :units,
        :low, :high, :critical_low, :critical_high, :range,
        :reported_normalcy, :collected_on, :truncated) do
        # :low and :high mean out of range in that direction. :unknown covers
        # everything not decidable: qualitative results ("NEGATIVE"), results
        # with no reference range, and panels reporting several values at once.
        def status
          return :unknown if number.nil? || (low.nil? && high.nil?)
          return :low if low && number < low
          return :high if high && number > high

          :normal
        end

        def abnormal? = status == :low || status == :high

        # Past a critical bound is a different kind of result from merely out
        # of range, and the two must not read the same in a table.
        def critical?
          return false if number.nil?

          (!critical_low.nil? && number < critical_low) ||
            (!critical_high.nil? && number > critical_high)
        end

        # Nothing for in-range or undecidable, since a blank column reads
        # better than a wall of "NORMAL".
        def flag
          return "" unless abnormal?

          critical? ? "CRITICAL #{status.to_s.upcase}" : status.to_s.upcase
        end
      end

      class << self
        def parse(payload)
          items(payload).flat_map do |panel|
            items(panel, "resultTypes").flat_map do |type|
              items(type, "results").map do |raw|
                result_for(raw, panel: panel["name"], type_name: type["name"],
                  truncated: type["hasMore"] == true)
              end
            end
          end
        end

        # The history endpoint answers with a flat list for a single analyte —
        # no panel wrapper and no `hasMore`, because this *is* what `hasMore`
        # was pointing at. The caller knows which panel it asked about, so it
        # supplies the name the payload leaves out.
        def parse_history(payload, panel: nil)
          items(payload).map do |raw|
            result_for(raw, panel: panel, type_name: raw["type"], truncated: false)
          end
        end

        private

        def items(hash, key = "items")
          hash.is_a?(Hash) ? Array(hash[key]) : []
        end

        def result_for(raw, panel:, type_name:, truncated:)
          values = Array(raw["resultValues"])
          ranges = raw["referenceRanges"] || {}
          low, high = ranges["normalLow"], ranges["normalHigh"]
          # Present but null-valued on nearly every result, so these go through
          # the same emptiness check as everything else.
          crit_low, crit_high = ranges["criticalLow"], ranges["criticalHigh"]

          Result.new(
            panel: panel,
            # A single-analyte result type names itself rather than its one
            # result, so fall back to the type's name.
            analyte: presence(raw["name"]) || type_name,
            value: values.filter_map { |v| display(v) }.join(", "),
            # Only an unambiguous single value can be compared to a range.
            number: (values.size == 1) ? number(values.first) : nil,
            units: values.filter_map { |v| units_of(v) }.first,
            low: number(low), high: number(high),
            critical_low: number(crit_low), critical_high: number(crit_high),
            range: range_display(low, high),
            reported_normalcy: raw["normalcy"],
            collected_on: raw["performedDateTime"].to_s[0, 10],
            truncated: truncated
          )
        end

        # Units are carried in their own field so they can be a table column of
        # their own; a value is just its number and any modifier ("< 5").
        def display(value)
          return nil unless present?(value)

          [value["modifier"], value["value"]].filter_map { |p| presence(p) }.join(" ")
        end

        def units_of(value) = present?(value) ? presence(value["units"]) : nil

        def range_display(low, high)
          lo, hi = display(low), display(high)
          if lo && hi then "#{lo} – #{hi}"
          elsif lo then bounded(lo, ">")
          elsif hi then bounded(hi, "<")
          end
        end

        # A one-sided range reads as an inequality, but the bound sometimes
        # carries its own operator already ("< 5.7") — don't stack a second.
        def bounded(text, operator)
          text.match?(/\A[<>]/) ? text : "#{operator} #{text}"
        end

        def present?(value) = value.is_a?(Hash) && !value["value"].to_s.empty?

        # Thousands separators appear on results like platelet counts.
        def number(value)
          return nil unless value.is_a?(Hash)

          Float(value["value"].to_s.delete(","))
        rescue ArgumentError, TypeError
          nil
        end

        def presence(value) = (value.nil? || value.to_s.empty?) ? nil : value.to_s
      end
    end
  end
end
