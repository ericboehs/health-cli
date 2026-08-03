require "json"
require "uri"

require "health/portal"

module Health
  module Portal
    # Read access to one person's health record.
    #
    # Every section is served from the same URL the browser navigates to;
    # asking for `application/json` instead of HTML returns the structured
    # payload the page renders from. There is no separate API host and no
    # published contract, so nothing here assumes a field is present.
    class Record
      class Error < Portal::Error; end

      # Sections known to serve JSON. `documents` is deliberately absent: its
      # JSON serializer 500s and only the HTML list works.
      SECTIONS = %w[results problems medications allergies immunizations procedures].freeze

      attr_reader :person_id

      def initialize(client:, person_id:, host: Login::RECORD_HOST)
        @client = client
        @person_id = person_id
        @host = host
      end

      # Returns a record positioned on the person the credentials belong to,
      # reusing a cached session when there is one.
      #
      # The cache is what keeps this from prompting for 1Password on every
      # command: a live `cloud-session` needs neither `op` nor the SAML chain.
      # Whether it is still live is settled by one cheap request rather than by
      # trusting a stored expiry, because the portal publishes none.
      #
      # `entry` and `record_host` exist for the same reason they do on Login —
      # pointing the chain at a local stub in tests.
      def self.open(config = nil, io: nil, client: Client.new, store: nil,
        entry: Login::ENTRY, record_host: Login::RECORD_HOST)
        store ||= SessionStore.new(config)

        if (saved = store.load(io: io))
          cached = new(client: Client.new(jar: saved[:jar]), person_id: saved[:person_id], host: record_host)
          return cached if cached.signed_in?

          io&.puts "  cached session has expired"
        end

        login = Login.new(credentials: Credentials.load(config), client: client,
          io: io, entry: entry, record_host: record_host)
        person_id = login.call
        store.save(jar: client.jar, person_id: person_id)
        new(client: client, person_id: person_id, host: record_host)
      end

      # Signed out, the record host redirects to the identity provider instead
      # of to this person, which is the cheapest available liveness check.
      def signed_in?
        @client.head_location("#{@host}/health-record/results/").to_s.include?("/person/#{@person_id}/")
      end

      # `results` is the only section that filters server-side, and it wants
      # US-formatted dates. A decade-wide window still comes back in one
      # response, so there is no paging to do here.
      def results(from:, to:)
        fetch("results", "date_range_0" => from.strftime("%m/%d/%Y"),
          "date_range_1" => to.strftime("%m/%d/%Y"))
      end

      # Every analyte the record knows about, paired with the id its history is
      # filed under. Costs a full HTML render of the results page — see
      # HistoryIndex for why there is no cheaper route.
      def history_index(from:, to:)
        HistoryIndex.parse(fetch_html("results", "date_range_0" => from.strftime("%m/%d/%Y"),
          "date_range_1" => to.strftime("%m/%d/%Y")))
      end

      # Every recorded draw of one analyte, newest first, as a payload shaped
      # like the other sections so one parser can read both.
      #
      # Paged rather than asked for in one go on purpose: `page_size` is
      # honoured up to somewhere between 100 and 500, and past that the server
      # silently reverts to 25 instead of erroring. A request that quietly
      # returns a prefix of the answer is the worst outcome available here, so
      # this asks for a size that is known to work and follows the cursor.
      PAGE_SIZE = 100
      MAX_PAGES = 50

      def history(uuid)
        items = []
        page_key = nil
        complete = false

        MAX_PAGES.times do
          params = { "name_and_type_uuid" => uuid, "page_size" => PAGE_SIZE }
          params.merge!("page_key" => page_key, "dir" => "next") if page_key
          page = fetch("results/history", params)
          rows = Array(page["items"])
          items.concat(rows)

          if rows.size < PAGE_SIZE
            complete = true
            break
          end

          page_key = cursor(rows)
          if page_key == :end
            complete = true
            break
          end

          # A full page whose rows carry no readable cursor means there are more
          # draws and no way to ask for them. The whole reason this method pages
          # instead of sending one big request is that a silent prefix is the
          # worst outcome here — so don't produce one by a different route.
          if page_key.nil?
            raise Error, "the portal returned a full page of history with no cursor to continue from"
          end
        end

        unless complete
          raise Error, "this analyte has more than #{MAX_PAGES * PAGE_SIZE} recorded draws — " \
                       "refusing to present a prefix as the whole history"
        end

        { "items" => items }
      end

      def fetch(section, params = {})
        res = @client.get(url_for(section, params), accept: "application/json")

        unless res.code == "200" && res["content-type"].to_s.include?("json")
          # Deliberately no body in the message: it would be PHI on the way to
          # a crash report.
          raise Error, "the portal did not return #{section} as JSON (HTTP #{res.code})"
        end

        shaped(section, JSON.parse(res.body))
      rescue JSON::ParserError
        raise Error, "the portal returned unreadable #{section} data"
      end

      private

      # "Treat every field as optional" has to stop at the payload's skeleton.
      # Without this check a 200 carrying valid JSON in a shape nobody here
      # recognises — a wrapper object, an error document, a login page rendered
      # as JSON — collapses to `[]` at every level and prints "no results
      # matched", exit 0. That is byte-identical to a genuinely empty window,
      # so a scrape that has silently stopped working reads as a clean answer
      # about a medical record. Say the format changed instead.
      def shaped(section, payload)
        return payload if payload.is_a?(Hash) && payload.key?("items")

        raise Error, "the portal's #{section} response was not in a recognised shape — " \
                     "the format has probably changed"
      end

      # The cursor for "the page these rows came from" is not a field of the
      # response — it is only reachable through the `page_key` the server
      # embeds in each row's detail link.
      def cursor(rows)
        key = rows.first.to_h["detailUrl"].to_s[/page_key=([^&]+)/, 1]
        # The portal writes the literal "None" where a page has no cursor;
        # sending that back asks for the first page again, forever. That is the
        # server saying "this is the end", which is a different answer from
        # finding no `page_key` at all — the latter means the link shape changed
        # and we can no longer tell whether more draws exist. `history` has to
        # distinguish them, so return :end rather than folding both into nil.
        return :end if key == "None"

        key
      end

      def fetch_html(section, params = {})
        res = @client.get(url_for(section, params), accept: "text/html")
        raise Error, "the portal did not serve #{section} (HTTP #{res.code})" unless res.code == "200"

        res.body.to_s
      end

      def url_for(section, params)
        url = "#{@host}/person/#{@person_id}/health-record/#{section}/"
        params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}"
      end
    end
  end
end
