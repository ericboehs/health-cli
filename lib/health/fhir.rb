require "health/error"

module Health
  # The Millennium FHIR R4 API — everything the record carries *except* labs.
  #
  # The division of labour with Health::Portal is not a preference, it is what
  # each side actually serves. FHIR returns lab Observations stripped of
  # `valueQuantity` and `referenceRange`, which is why labs come from the
  # portal; but medications, problems, allergies, immunizations and documents
  # come back here fully populated, with codes and dates a scrape can only
  # approximate.
  #
  # Read-only by construction. Nothing in this module issues anything but GET,
  # and the scopes the grant carries are all `.read`.
  module FHIR
    class Error < Health::Error; end

    module_function

    # The human label for a CodeableConcept.
    #
    # Order matters and is not arbitrary. `text` is the record's own words for
    # this concept and wins outright. Failing that, the coding the clinician
    # actually picked (`userSelected`) beats one a terminology map added
    # afterwards — on this record a flu shot is "influenza virus vaccine,
    # inactivated" as chosen and "Fluzone Quadrivalent 2021-2022" as mapped,
    # and only the first is a statement about what happened.
    #
    # Falls back to the bare code so an unlabelled concept prints *something*.
    # A blank cell reads as "no allergy recorded" when what it means is "the
    # allergy has no display string", and those are opposite facts.
    def display(concept)
      return nil if concept.nil?
      return concept.to_s if concept.is_a?(String)

      text = presence(concept["text"])
      return text if text

      codings = Array(concept["coding"]).select { |c| c.is_a?(Hash) }
      chosen = codings.find { |c| c["userSelected"] && presence(c["display"]) }
      chosen ||= codings.find { |c| presence(c["display"]) }
      return presence(chosen["display"]) if chosen

      presence(codings.first&.dig("code"))
    end

    # The same, for the `clinicalStatus`/`verificationStatus` pattern where the
    # useful value is the code rather than its display ("active", not "Active").
    def status_code(concept)
      return nil if concept.nil?
      return concept.to_s if concept.is_a?(String)

      presence(Array(concept["coding"]).first&.dig("code"))&.downcase
    end

    # FHIR dates arrive as dates, instants, and offset datetimes all in one
    # field family. The first ten characters are the calendar date in every
    # one of those forms, and an offset datetime is already local to where the
    # event happened — which is the date a person means when they ask when
    # they got a shot.
    def date(value) = presence(value.to_s[0, 10])

    # The first date-ish field a resource actually carries. Resource types
    # disagree about what the relevant date is called, and several carry more
    # than one.
    def date_from(resource, *keys)
      keys.each do |key|
        found = date(resource[key])
        return found if found
      end
      nil
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
