require "net/http"
require "uri"
require "json"
require "openssl"

require "health/fhir"

module Health
  module FHIR
    # A read-only FHIR client: search a resource type for the signed-in patient,
    # walk the Bundle's pages, hand back plain Hashes.
    #
    # Deliberately not a resource model layer. Every command here wants four or
    # five fields out of a resource and the rest is noise, so the resources stay
    # as parsed JSON and Health::FHIR.display does the digging. A class per
    # resource type would be a lot of code standing between a command and a
    # field it could have read directly.
    class Client
      ACCEPT = "application/fhir+json".freeze

      # A patient record is not big, and every page costs a round trip. This is
      # not a page budget so much as a runaway guard: a server that returns a
      # `next` link pointing at the page just fetched would otherwise spin here
      # until the operator killed it.
      MAX_PAGES = 100

      # Millennium pages at 25 by default, which made a 118-prescription
      # history five requests instead of two. Measured, the server spends about
      # the same total time either way — it is slower per page for a bigger
      # page — so this buys robustness rather than speed: fewer round trips is
      # fewer chances for one to fail partway through a walk.
      PAGE_SIZE = 100

      def initialize(config, session: nil, tenant: nil, io: nil)
        @config = config
        @tenant = tenant
        @session = session || Session.new(config, tenant: tenant, io: io)
        @io = io
      end

      # The patient this grant is scoped to. SMART returns it as launch context
      # in the token response, so it is stored rather than looked up.
      def patient_id
        id = @session.tokens&.dig("patient").to_s
        if id.empty?
          raise Error, "the stored grant carries no patient context — run `health auth login`"
        end

        id
      end

      # Every resource matching `params` across every page, as Hashes.
      #
      # `patient` is added here rather than by callers: a patient-scoped grant
      # rejects a search without it, and forgetting it in one command out of
      # five is exactly the bug that would go unnoticed until that command was
      # the one being used.
      def search(resource, params = {})
        uri = URI("#{@config.fhir_base(@tenant)}#{resource}")
        uri.query = URI.encode_www_form(
          { "patient" => patient_id, "_count" => PAGE_SIZE }.merge(stringify(params))
        )

        resources = []
        MAX_PAGES.times do |page|
          log "#{resource}: fetching page #{page + 1}"
          bundle = get_json(uri, resource)
          resources.concat(entries_of(bundle))

          nxt = next_link(bundle)
          return resources if nxt.nil?

          uri = same_host!(URI(nxt), resource)
        end

        raise Error, "#{resource} search did not stop paging after #{MAX_PAGES} pages — " \
                     "refusing to keep going"
      end

      # The bytes behind a DocumentReference attachment.
      #
      # Returns [content_type, body]. The URL comes out of a payload rather than
      # being built here, and this request carries a bearer token, so it is
      # checked against the configured host before it is followed — see
      # `same_host!`.
      #
      # `accept` is the attachment's own contentType and is not optional in
      # practice: Millennium's Binary endpoint answers `*/*` with a 406, so the
      # caller has to say back the type the DocumentReference just advertised.
      def fetch_binary(url, accept: nil)
        uri = same_host!(URI(url.to_s), "Binary")
        res = get(uri, accept: FHIR.presence(accept) || ACCEPT)

        # A 404 here is not a broken link. Millennium lists documents the
        # patient may see the existence of and serves the bytes for only some
        # of them — intake forms 404 while the visit summary from the same
        # encounter downloads. Saying "not found" would send someone looking
        # for a typo in an id this tool printed itself.
        if res.is_a?(Net::HTTPNotFound)
          raise Error, "the server lists this document but will not serve its contents (HTTP 404) — " \
                       "some documents are visible in the index without being released for download"
        end
        unless res.is_a?(Net::HTTPSuccess)
          raise Error, "could not download the document (HTTP #{res.code})"
        end
        # An empty 200 would otherwise be written out as a zero-byte file and
        # reported as a success — and `write!` then refuses to overwrite it, so
        # the retry that would have worked is the one thing that can't happen.
        if res.body.to_s.empty?
          raise Error, "the server returned an empty document (HTTP 200, zero bytes) — nothing was written"
        end

        [res["content-type"].to_s.split(";").first.to_s.strip, res.body]
      end

      private

      def stringify(params)
        params.each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s unless v.nil? }
      end

      def get_json(uri, resource)
        res = get(uri, accept: ACCEPT)
        body = parse(res.body)

        unless res.is_a?(Net::HTTPSuccess)
          raise Error, "#{resource} request failed (HTTP #{res.code})#{detail_of(body)}"
        end

        bundle!(body, resource)
      end

      # A 200 is not on its own an answer. A proxy interstitial, a login page,
      # or an OperationOutcome served with a 200 all parse to something this
      # code can call `["entry"]` on and get nothing from — and "nothing" then
      # prints as `no medications matched`, which is byte-identical to the
      # true statement that there are no prescriptions. Between "the record is
      # empty" and "the answer wasn't a record", only the second is safe to
      # get wrong in the direction of silence.
      def bundle!(body, resource)
        # `parse` hands back a Hash or nothing, so an interstitial, a bare
        # array and unparseable bytes all arrive here as {} — no resourceType,
        # which is the "not FHIR JSON" case.
        kind = body["resourceType"]
        return body if kind == "Bundle"

        raise Error, "#{resource} search answered with #{kind ? "a #{kind}" : "something that is not FHIR JSON"} " \
                     "rather than a Bundle — refusing to read it as an empty record"
      end

      def get(uri, accept:)
        req = Net::HTTP::Get.new(uri)
        # Asked for per request rather than once per client: an access token
        # lives 570 seconds and a full record walk can outlast that. Session
        # hands back the cached one until it is near expiry, so this is a hash
        # lookup on all but the refreshing call.
        req["Authorization"] = "Bearer #{@session.access_token!}"
        req["Accept"] = accept

        http(uri).request(req)
      end

      def http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |h|
          h.use_ssl = uri.scheme == "https"
          h.verify_mode = OpenSSL::SSL::VERIFY_PEER
          h.open_timeout = 15
          h.read_timeout = 45
        end
      end

      # A Bundle's entries, tolerating the two ways an empty result arrives:
      # no `entry` key at all, and an `entry` array of entries without
      # `resource`. Both occur on this record.
      def entries_of(bundle)
        Array(bundle["entry"]).filter_map { |e| e["resource"] if e.is_a?(Hash) }
      end

      def next_link(bundle)
        link = Array(bundle["link"]).find { |l| l.is_a?(Hash) && l["relation"] == "next" }
        url = link && link["url"].to_s
        url.to_s.empty? ? nil : url
      end

      # A URL out of a payload gets this request's bearer token attached, so it
      # may only point where that token belongs. Cerner's `next` links and
      # Binary URLs are absolute and on the FHIR host; anything else is either
      # a server that has changed shape or a payload trying to collect a
      # credential, and both deserve a stop rather than a best guess.
      #
      # Compared against the configured base rather than against a hardcoded
      # "https", so that pointing `fhir_host` at a proxy or a local stub keeps
      # working — and so that against the real base, which is https, a payload
      # offering an http:// link is still refused.
      def same_host!(uri, resource)
        expected = URI(@config.fhir_base(@tenant))
        return uri if uri.scheme == expected.scheme && uri.host == expected.host && uri.port == expected.port

        raise Error, "#{resource} pointed at #{uri.host.inspect}, which is not the FHIR host — refusing to follow it"
      end

      # OperationOutcome is the FHIR error body. Its `text.div` is HTML and its
      # `details.text` is usually the same string as `diagnostics`, so this
      # takes the first plain-text field it finds and stops.
      def detail_of(body)
        issue = Array(body["issue"]).first
        return "" unless issue.is_a?(Hash)

        text = issue.dig("details", "text") || issue["diagnostics"]
        text.to_s.empty? ? "" : " — #{redact(text)}"
      end

      # Server-authored text goes into a message an operator may paste into a
      # bug report, and Millennium echoes request parameters back in it
      # ("Invalid patient id: …"). The diagnostic is worth keeping — it is how
      # the 406 on Binary was diagnosed — but not at the cost of carrying the
      # person id out with it.
      #
      # `patient_id` rather than a nil-tolerant lookup: this runs on the way
      # back from a request that `search` only built because `patient_id`
      # already answered.
      def redact(text) = text.to_s.gsub(patient_id, "[patient]")

      def parse(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # Progress goes to whatever stream the command passed, and never carries
      # the URL: a search URL has the person id in its query string, and this
      # is the one place in the read path that writes to a terminal the operator
      # may well be piping into a file.
      def log(message) = @io&.puts("health: #{message}")
    end
  end
end
