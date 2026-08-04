require "health/commands/resource"

module Health
  module Commands
    # `health meds` — prescriptions, from MedicationRequest.
    #
    # MedicationDispense is the resource that would say what has actually been
    # handed over, and on this record it is empty: Millennium only carries
    # dispense events for medications dispensed inside the health system, and a
    # prescription filled at a retail pharmacy leaves none. So everything here
    # comes from the request, and the Refills column is what the prescriber
    # *authorized* — not what is left. See `refills_note`.
    class Meds < Resource
      def resource_type = "MedicationRequest"
      def noun = "medications"

      # Status filtering is done here rather than by passing `status=active` to
      # the server, so that the count of what was hidden can be reported. A
      # medication list that quietly omits rows is the wrong default for a
      # medical record even when the omitted rows are stale.
      ACTIVE = %w[active on-hold draft].freeze

      def columns
        cols = [
          [:medication, "Medication", { max: 46 }],
          [:sig, "Sig", { max: 44 }],
          [:refills, "Refills", { align: :right }]
        ]
        cols << [:status, "Status"] if opts[:all]
        cols << [:date, "Prescribed"]
      end

      def extract(resource)
        dispense = resource["dispenseRequest"] || {}
        dosage = Array(resource["dosageInstruction"]).find { |d| d.is_a?(Hash) } || {}

        {
          medication: FHIR.display(resource["medicationCodeableConcept"]),
          sig: FHIR.presence(dosage["patientInstruction"]) || FHIR.presence(dosage["text"]),
          refills: dispense["numberOfRepeatsAllowed"],
          status: FHIR.presence(resource["status"]),
          date: FHIR.date_from(resource, "authoredOn"),
          prescriber: resource.dig("requester", "display"),
          pharmacy: dispense.dig("performer", "display"),
          quantity: quantity_of(dispense["quantity"]),
          id: resource["id"]
        }
      end

      private

      def quantity_of(quantity)
        return nil unless quantity.is_a?(Hash)

        value = quantity["value"]
        return nil if value.nil?

        # 8.5 g, but 30 tab rather than 30.0 tab.
        number = (value.to_f % 1).zero? ? value.to_i : value.to_f
        [number, FHIR.presence(quantity["unit"])].compact.join(" ")
      end

      def filter(items, opts)
        items = super
        return items if opts[:all]

        kept = items.select { |i| ACTIVE.include?(i[:status].to_s) }
        @hidden = items.size - kept.size
        kept
      end

      def summarize(items)
        return if @global.quiet

        super
        refills_note(items)
        return if @hidden.to_i.zero?

        @err.puts "#{@hidden} more on record (completed, stopped or expired) — see `health meds --all`."
      end

      # Said once, in the output, rather than left to the column header. The
      # difference between "3 refills authorized" and "3 refills left" is the
      # kind of thing someone plans a week around, and this tool cannot tell
      # them the second one.
      def refills_note(items)
        return if items.none? { |i| i[:refills] }

        @err.puts "Refills are what the prescription authorized, not what remains — " \
                  "the pharmacy is the only place that knows the difference."
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
