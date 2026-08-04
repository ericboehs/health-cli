require "health/commands/resource"

module Health
  module Commands
    # `health shots` — immunizations.
    #
    # Millennium codes a vaccine twice: once as the clinician selected it
    # ("influenza virus vaccine, inactivated") and once mapped to CVX
    # ("Fluzone Quadrivalent 2021-2022"). FHIR.display returns the first, which
    # is the record of what was given; the CVX display is the more specific
    # product name, so it is carried as its own field and shown when it adds
    # something the chosen coding didn't say.
    class Shots < Resource
      def resource_type = "Immunization"
      def noun = "immunizations"

      CVX = "http://hl7.org/fhir/sid/cvx".freeze

      def columns
        [
          [:vaccine, "Vaccine", { max: 40 }],
          [:product, "Product", { max: 34 }],
          [:status, "Status"],
          [:site, "Site"],
          [:date, "Given"]
        ]
      end

      def extract(resource)
        {
          vaccine: FHIR.display(resource["vaccineCode"]),
          product: product_of(resource),
          status: FHIR.presence(resource["status"]),
          site: FHIR.display(resource["site"]),
          date: FHIR.date_from(resource, "occurrenceDateTime", "occurrenceString"),
          location: resource.dig("location", "display"),
          manufacturer: resource.dig("manufacturer", "display"),
          lot: FHIR.presence(resource["lotNumber"]),
          id: resource["id"]
        }
      end

      private

      def product_of(resource)
        cvx = Array(resource.dig("vaccineCode", "coding")).find do |coding|
          coding.is_a?(Hash) && coding["system"] == CVX
        end
        product = FHIR.presence(cvx && cvx["display"])
        # Suppressed when it merely repeats the chosen coding, so the column
        # earns its width or stays empty.
        (product == FHIR.display(resource["vaccineCode"])) ? nil : product
      end
    end
  end
end
