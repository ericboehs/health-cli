require "cgi"

require "health/portal"

module Health
  module Portal
    # Minimal HTML form extraction.
    #
    # Both forms in the sign-in chain are plain server-rendered markup — a
    # Django login form and a SAML POST-binding auto-submit form — so regex
    # parsing is adequate and keeps the CLI dependency-free. It is deliberately
    # not a general HTML parser.
    class Form
      FIELD = /<(?:input|button)\b([^>]*)>/i

      attr_reader :action, :method, :fields

      def initialize(action:, method:, fields:)
        @action = action
        @method = method
        @fields = fields
      end

      def field?(name) = fields.key?(name)

      # Resolves the form's action against the page it was served from, since
      # these actions are relative ("/login").
      def action_url(page_uri) = URI.join(page_uri.to_s, action.to_s.empty? ? page_uri.to_s : action).to_s

      class << self
        def all(html)
          html.to_s.scan(/<form\b([^>]*)>(.*?)<\/form>/mi).map do |attrs, body|
            new(
              action: attr(attrs, "action"),
              method: (attr(attrs, "method") || "get").downcase,
              fields: fields_in(body)
            )
          end
        end

        # The form carrying a given input — how the chain decides whether it is
        # looking at the login page or the SAML hand-off.
        def with_field(html, name)
          all(html).find { |f| f.field?(name) }
        end

        private

        def fields_in(body)
          body.scan(FIELD).each_with_object({}) do |(attrs), acc|
            name = attr(attrs, "name")
            next if name.nil? || name.empty?
            next if attr(attrs, "type").to_s.downcase == "submit" && !attrs.match?(/(?:\A|\s)value\s*=/i)

            acc[name] = CGI.unescapeHTML(attr(attrs, "value").to_s)
          end
        end

        # The boundary is whitespace, not `\b`: `\b` matches between the hyphen
        # and the "a" of `data-action`, so `data-action="/x" action="/login"`
        # resolved to `/x` — and this runs on the form that carries the
        # password. Leftmost-match means the impostor wins whenever it comes
        # first in the tag.
        def attr(attrs, name)
          key = Regexp.escape(name)
          m = attrs.match(/(?:\A|\s)#{key}\s*=\s*"([^"]*)"/i) ||
              attrs.match(/(?:\A|\s)#{key}\s*=\s*'([^']*)'/i) ||
              attrs.match(/(?:\A|\s)#{key}\s*=\s*([^\s>]+)/i)
          m && m[1]
        end
      end
    end
  end
end
