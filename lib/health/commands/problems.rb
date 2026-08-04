require "health/commands/resource"

module Health
  module Commands
    # `health problems` — the problem list, from Condition.
    #
    # Condition carries two different things under one resource type, and the
    # difference is the whole reason this command has a default. A
    # `problem-list-item` is something a clinician put on the standing problem
    # list; an `encounter-diagnosis` is what was being treated at one visit. On
    # this record that is 30 against 106, and printing all 136 as "your
    # problems" would be wrong in the direction that alarms people — every
    # complaint ever investigated, listed as though it were a standing
    # diagnosis.
    class Problems < Resource
      def resource_type = "Condition"
      def noun = "problems"

      PROBLEM_LIST = "problem-list-item".freeze

      def columns
        cols = [[:problem, "Problem", { max: 52 }], [:status, "Status"]]
        cols << [:category, "Category"] if opts[:all]
        cols << [:date, "Onset"]
      end

      def extract(resource)
        {
          problem: FHIR.display(resource["code"]),
          status: FHIR.status_code(resource["clinicalStatus"]),
          verification: FHIR.status_code(resource["verificationStatus"]),
          category: category_of(resource),
          # Onset is what a person means by "since when"; recordedDate is when
          # someone typed it in. Onset is preferred and recordedDate is the
          # fallback, because a row with no date at all sorts to the bottom and
          # reads as missing data when the date is merely in the other field.
          date: FHIR.date_from(resource, "onsetDateTime", "recordedDate"),
          recorded: FHIR.date_from(resource, "recordedDate"),
          id: resource["id"]
        }
      end

      private

      # Millennium tags each Condition with both a US Core category and a
      # SNOMED one ("Medical (qualifier value)"), so this looks for the code it
      # knows rather than reading whichever coding happens to come first.
      def category_of(resource)
        codes = Array(resource["category"]).flat_map do |c|
          Array(c.is_a?(Hash) ? c["coding"] : nil).filter_map { |coding| coding["code"] }
        end
        codes.find { |c| c == PROBLEM_LIST } || codes.find { |c| c == "encounter-diagnosis" } || codes.first
      end

      def filter(items, opts)
        items = super
        return items if opts[:all]

        kept = items.select { |i| i[:category] == PROBLEM_LIST }
        @hidden = items.size - kept.size
        kept
      end

      def summarize(items)
        return if @global.quiet

        super
        return if @hidden.to_i.zero?

        @err.puts "#{@hidden} encounter #{(@hidden == 1) ? "diagnosis" : "diagnoses"} not on the " \
                  "problem list — see `health problems --all`."
      end

      def consume(arg, argv, opts)
        case arg
        when "--all" then opts[:all] = true
        else super
        end
      end
    end
  end
end
