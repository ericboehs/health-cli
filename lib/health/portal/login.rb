require "health/portal"

module Health
  module Portal
    # Signs in to the HealtheIntent patient portal without a browser.
    #
    # The chain is: the portal bounces to a Cerner Health SAML endpoint, which
    # renders an ordinary Django login form; posting it returns a SAML
    # POST-binding page whose auto-submitting form hands the assertion back to
    # the portal, which finally sets `cloud-session`. That one cookie is all
    # the health-record endpoints need.
    #
    # Rather than hard-coding six hops, this walks whatever form it is shown —
    # login form, then SAML hand-off — until a page arrives with neither. That
    # tolerates the provider inserting or reordering steps.
    class Login
      class Error < Portal::Error; end

      PORTAL = "https://asp-central.uhs.patientportal.us-1.healtheintent.com".freeze
      RECORD_HOST = "https://uhs-pacentral.patientportal.healtheintent.com".freeze
      ENTRY = "#{PORTAL}/pages/health_record/results".freeze
      SESSION_COOKIE = "cloud-session".freeze

      MAX_STEPS = 8

      # `entry` and `record_host` are overridable so the chain can be pointed at
      # a local stub in tests; in normal use they are the constants above.
      def initialize(credentials:, client: Client.new, io: nil, entry: ENTRY, record_host: RECORD_HOST)
        @credentials = credentials
        @client = client
        @io = io
        @entry = entry
        @record_host = record_host
      end

      attr_reader :client

      # Returns the person id the record is filed under; the authenticated
      # cookie jar lives on `client`.
      def call
        res = @client.get(@entry)
        submitted = false

        MAX_STEPS.times do
          body = res.body.to_s

          if (form = Form.with_field(body, "login_password"))
            # Being shown the login form a second time means the first
            # submission was rejected. Walking the loop would resend the same
            # password up to MAX_STEPS times, which is how an account gets
            # locked out — and this is a medical IdP, where a lockout costs a
            # phone call. Fail on the first rejection instead.
            if submitted
              raise Error, "the portal rejected the stored credentials — " \
                           "check the username and password in 1Password"
            end

            log "submitting credentials"
            submitted = true
            res = submit(form, res.uri, {})
            next
          end

          if (form = Form.with_field(body, "SAMLResponse"))
            log "relaying SAML assertion"
            res = submit(form, res.uri, {})
            next
          end

          break
        end

        unless @client.jar[SESSION_COOKIE]
          raise Error, "signed in but no #{SESSION_COOKIE} cookie was issued — the portal may have changed its flow"
        end

        person_id
      end

      private

      def log(msg) = @io&.puts("  #{msg}")

      def submit(form, page_uri, overrides)
        fields = form.fields.merge(overrides)
        # Read off @credentials only at the moment of the request. That object
        # does hold the password for its own lifetime — see Credentials, which
        # keeps it out of `inspect` for exactly that reason — but it never
        # reaches this class's own state, a log line, or a retry.
        if form.field?("login_password")
          fields["login_username"] = @credentials.username
          fields["login_password"] = @credentials.password
        end
        @client.post(form.action_url(page_uri), fields, headers: { "Referer" => page_uri.to_s })
      end

      # The record host redirects an unscoped request to the person it belongs
      # to, which is how the id is discovered without a separate API call.
      def person_id
        location = @client.head_location("#{@record_host}/health-record/results/")
        id = location.to_s[%r{/person/([^/?#]+)/}, 1]
        raise Error, "signed in but could not resolve the person id" unless id

        id
      end
    end
  end
end
