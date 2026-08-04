require "health/commands/resource"

module Health
  module Commands
    # `health allergies` — from AllergyIntolerance.
    #
    # No default filtering here, unlike `meds` and `problems`. An allergy list
    # is short, and it is the one list where an omission is dangerous rather
    # than merely untidy — a resolved or refuted entry still tells you what was
    # once suspected, and that is worth a row and a status column.
    class Allergies < Resource
      def resource_type = "AllergyIntolerance"
      def noun = "allergies"
      def singular = "allergy"

      def columns
        [
          [:substance, "Substance", { max: 44 }],
          [:reaction, "Reaction", { max: 36 }],
          [:criticality, "Criticality"],
          [:status, "Status"],
          [:date, "Recorded"]
        ]
      end

      def extract(resource)
        {
          substance: FHIR.display(resource["code"]),
          reaction: reactions_of(resource),
          criticality: FHIR.presence(resource["criticality"]),
          type: FHIR.presence(resource["type"]),
          # `category` is a plain array of strings here, not CodeableConcepts.
          category: Array(resource["category"]).map(&:to_s).join(", "),
          status: qualified_status(resource),
          verification: FHIR.status_code(resource["verificationStatus"]),
          date: FHIR.date_from(resource, "recordedDate", "onsetDateTime"),
          id: resource["id"]
        }
      end

      private

      # One allergy can record several reactions and each several
      # manifestations, all of which matter to the person reading. They are
      # joined rather than folded to the first, and the column truncates if
      # that runs long.
      def reactions_of(resource)
        manifestations = Array(resource["reaction"]).flat_map do |reaction|
          next [] unless reaction.is_a?(Hash)

          Array(reaction["manifestation"]).filter_map { |m| FHIR.display(m) }
        end
        FHIR.presence(manifestations.uniq.join(", "))
      end
    end
  end
end
