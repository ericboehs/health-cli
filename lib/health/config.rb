require "json"
require "fileutils"
require "pathname"
require "open3"

module Health
  class Config
    class Error < RuntimeError; end

    # Oracle Health Millennium patient-persona tenants. Aliases exist because
    # "which tenant is mine" is not knowable up front — the three UHS Ambulatory
    # tenants are byte-identical in capability, so resolving it means trying
    # them. `health auth login --tenant west` is cheaper than pasting a UUID.
    TENANTS = {
      "central" => "870ba945-f258-4fb9-a3f5-2c79586392b9", # UHS_Ambulatory_Central
      "west"    => "2f4f2c9e-c9c5-48b1-95a2-1ba6a49a76fd", # UHS_Ambulatory_West
      "east"    => "6d80f5c7-212b-4be1-9709-7bad9391b694", # UHS_Ambulatory_East
      "sandbox" => "ec2458f2-1e24-41c8-b71b-0e701af7583d"  # Oracle public sandbox
    }.freeze

    FHIR_HOST = "https://fhir-myrecord.cerner.com/r4".freeze

    # Requested at authorize time. Deliberately a subset of what the app is
    # registered for: `launch` and `profile` are force-enabled by the Oracle
    # console but are an EHR-launch scope and a deprecated alias respectively,
    # so asking for them in a standalone CLI flow would be noise.
    #
    # `.read` (SMART v1), not `.rs` (v2), because none of the three UHS tenants
    # advertise `code_challenge_methods_supported` — and v2 scopes make PKCE
    # mandatory. See README "PKCE".
    RESOURCES = %w[
      Patient Observation DiagnosticReport Specimen
      MedicationRequest MedicationDispense MedicationAdministration
      Condition AllergyIntolerance Immunization Encounter
      CareTeam CarePlan Goal DocumentReference Binary
      Procedure Device FamilyMemberHistory Provenance
    ].freeze

    DEFAULT_SCOPES = (
      %w[launch/patient offline_access openid fhirUser] +
      RESOURCES.map { |r| "patient/#{r}.read" }
    ).freeze

    DEFAULTS = {
      "redirect_uri" => "http://localhost:8412/callback",
      "tenant" => "central",
      "ssh_key" => "~/.ssh/id_ed25519",
      "scopes" => DEFAULT_SCOPES,
      "output" => { "color" => true }
    }.freeze

    attr_reader :data

    def initialize(data)
      @data = DEFAULTS.merge(data || {})
    end

    def client_id = resolve(data["client_id"])
    def redirect_uri = data["redirect_uri"]
    def scopes = Array(data["scopes"])
    def color? = data.dig("output", "color") != false

    def ssh_key
      Pathname(File.expand_path(data["ssh_key"]))
    end

    # Accepts an alias ("central") or a raw tenant UUID, so a tenant Oracle adds
    # later needs no code change.
    def tenant_id(override = nil)
      key = (override || data["tenant"]).to_s
      TENANTS.fetch(key) { key }
    end

    # `fhir_host` is overridable so the base can be pointed at a proxy or a
    # local stub; in normal use it is FHIR_HOST.
    def fhir_host = data["fhir_host"] || FHIR_HOST

    def fhir_base(override = nil)
      "#{fhir_host}/#{tenant_id(override)}/"
    end

    def redirect_port
      URI(redirect_uri).port
    end

    def redirect_path
      # Oracle uses strict path matching including trailing slashes, so the
      # listener must compare against exactly what was registered.
      p = URI(redirect_uri).path
      p.empty? ? "/" : p
    end

    # Config values may be `op://…` references so a secret never lands in a
    # file. The current client is public (no secret), but a confidential
    # fallback would need this, and it costs nothing to support now.
    def resolve(value)
      return value unless value.is_a?(String) && value.start_with?("op://")

      out, err, status = Open3.capture3("op", "read", value)
      raise Error, "1Password lookup failed for #{value}: #{err.strip}" unless status.success?

      out.strip
    rescue Errno::ENOENT
      raise Error, "config references #{value} but the `op` CLI is not installed"
    end

    class << self
      def xdg(env, fallback)
        ENV[env] ? Pathname(ENV[env]) : Pathname(Dir.home).join(fallback)
      end

      def config_dir  = xdg("XDG_CONFIG_HOME", ".config").join("health")
      def config_path = config_dir.join("config.json")
      def data_dir    = xdg("XDG_DATA_HOME", ".local/share").join("health")
      def cache_dir   = data_dir.join("cache")
      def state_dir   = xdg("XDG_STATE_HOME", ".local/state").join("health")
      def token_path  = data_dir.join("tokens.age")

      def ensure_dirs!
        [config_dir, data_dir, cache_dir, state_dir].each { |d| FileUtils.mkdir_p(d) }
        # The token file and the discovery cache both sit under data_dir.
        [data_dir, cache_dir].each { |d| File.chmod(0o700, d) }
      end

      def load
        ensure_dirs!
        unless config_path.exist?
          raise Error, "config not found at #{config_path}\nRun: health config init"
        end

        new(JSON.parse(File.read(config_path)))
      rescue JSON::ParserError => e
        raise Error, "config at #{config_path} is not valid JSON (#{e.message})"
      end

      def write_default!(client_id: nil)
        ensure_dirs!
        return false if config_path.exist?

        File.write(config_path, JSON.pretty_generate(
          DEFAULTS.merge("client_id" => client_id || "PASTE-YOUR-CLIENT-ID")
        ) + "\n")
        true
      end
    end
  end
end
