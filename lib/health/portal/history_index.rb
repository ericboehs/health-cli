require "cgi"

require "health/portal"

module Health
  module Portal
    # Maps an analyte to the id its result history is filed under.
    #
    # This exists because of an asymmetry in the portal. The results section
    # serves clean JSON, but the history endpoint behind it is keyed by
    # `name_and_type_uuid` — and that value appears in no JSON payload
    # anywhere. Not on the panel, not on the result type, not on the result.
    # It is only ever emitted into the rendered page, on the "View all for this
    # result" link. Asking the history endpoint for `type=Hct` instead, which
    # is what the per-result `detailUrl` uses, answers "we're unable to find
    # the results you searched for" and hands back the default listing.
    #
    # So reading any history means scraping the ids out of the HTML first. That
    # is unpleasant and it is also the only way in.
    module HistoryIndex
      # The page is flat: a panel heading, then a card per analyte carrying the
      # analyte's name and a link carrying its id, in that order and never
      # nested. So one left-to-right pass over those three tokens is enough to
      # reassemble which id belongs to which analyte — no HTML parser needed,
      # and nothing to go wrong beyond the markup changing shape.
      TOKENS = %r{
        <h3[^>]*\bconsumer-card-header\b[^>]*>\s*(?<panel>[^<]+?)\s*</h3>
        | <div[^>]*\bsmall-heading\b[^>]*>\s*<bdi[^>]*>\s*(?<analyte>[^<]+?)\s*</bdi>
        | name_and_type_uuid=(?<uuid>[0-9a-f]{32})
      }x

      Entry = Data.define(:panel, :analyte, :uuid)

      # Returns one Entry per analyte, in page order. The first id after an
      # analyte's name is that analyte's; later ones belong to later cards.
      def self.parse(html)
        panel = nil
        analyte = nil
        entries = []

        html.to_s.scan(TOKENS) do
          m = Regexp.last_match
          if m[:panel]
            panel = clean(m[:panel])
          elsif m[:analyte]
            analyte = clean(m[:analyte])
          elsif analyte
            entries << Entry.new(panel: panel, analyte: analyte, uuid: m[:uuid])
            # Consumed: a card can carry several links, and only the first
            # names this analyte.
            analyte = nil
          end
        end

        entries
      end

      # Panel headings arrive with the trailing colon the page shows them with
      # ("Height:"), which the JSON payload also carries — left alone so the
      # two views of the same record agree.
      def self.clean(text) = CGI.unescapeHTML(text.to_s).gsub(/\s+/, " ").strip
    end
  end
end
