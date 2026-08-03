module Health
  # The patient-portal backend (HealtheIntent), used for the data the FHIR API
  # does not carry. Labs are the reason it exists: the Millennium FHIR endpoint
  # returns lab Observations with no `valueQuantity` and no `referenceRange`,
  # while the portal serves the same draws with values and ranges intact.
  #
  # Everything here signs in as Eric and reads Eric's own record. There is no
  # published contract for these endpoints, so treat every field as optional.
  module Portal
    # One ancestor for every portal failure, so callers rescue once.
    class Error < RuntimeError; end
  end
end
