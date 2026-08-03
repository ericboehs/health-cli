require "health/portal"

module Health
  module Portal
    # A cookie jar just large enough for the portal's sign-in chain.
    #
    # The chain crosses four hosts (cernerhealth.com, the portal, and two
    # healtheintent.com subdomains) and the session that ultimately matters —
    # `cloud-session` — is set on `.healtheintent.com`, a parent of the host
    # the health record is actually served from. So domain matching has to be
    # real: a host-only cookie must not leak to siblings, and a dotted cookie
    # must reach subdomains.
    class CookieJar
      Cookie = Struct.new(:name, :value, :domain, :path, :secure, :host_only, keyword_init: true)

      def initialize = @cookies = {}

      def size = @cookies.size

      def names_for(uri) = matching(uri).map(&:name)

      # Set-Cookie lines as returned by `response.get_fields("set-cookie")`.
      def absorb(lines, uri)
        Array(lines).each { |line| store(parse(line, uri)) }
        self
      end

      def header_for(uri)
        pairs = matching(uri).map { |c| "#{c.name}=#{c.value}" }
        pairs.empty? ? nil : pairs.join("; ")
      end

      def [](name)
        @cookies.values.find { |c| c.name == name }&.value
      end

      # Round-trips through the session cache. Every portal cookie is
      # session-scoped with no Expires attribute, so there is no expiry to
      # carry — whether the session still works is decided by using it.
      def dump
        @cookies.values.map { |c| c.to_h.transform_keys(&:to_s) }
      end

      def self.restore(rows)
        Array(rows).each_with_object(new) do |row, jar|
          next unless row.is_a?(Hash)

          # Slicing keeps a cache written by an older version — or a hand-edited
          # one — from blowing up on a member the struct no longer has.
          attrs = row.transform_keys(&:to_sym).slice(*Cookie.members)
          next if attrs[:name].to_s.empty?

          # Fill the rest rather than building a half-nil Cookie. `store` calls
          # `value.empty?` and `matching` calls `path.start_with?`, so one
          # missing member turned a stale cache into a NoMethodError out of
          # `health labs` — when a bad cache is supposed to mean nothing worse
          # than signing in again.
          attrs[:value] = attrs[:value].to_s
          attrs[:domain] = attrs[:domain].to_s.downcase
          attrs[:path] = attrs[:path].to_s.empty? ? "/" : attrs[:path].to_s
          attrs[:secure] = !attrs[:secure].nil? && attrs[:secure] != false
          attrs[:host_only] = !attrs[:host_only].nil? && attrs[:host_only] != false

          jar.add(Cookie.new(**attrs))
        end
      end

      def add(cookie)
        store(cookie)
        self
      end

      private

      def store(cookie)
        return unless cookie

        key = [cookie.domain, cookie.path, cookie.name]
        # An empty value is how a server expires a cookie mid-chain.
        cookie.value.empty? ? @cookies.delete(key) : @cookies[key] = cookie
      end

      def parse(line, uri)
        parts = line.split(";").map(&:strip)
        name, _, value = parts.first.to_s.partition("=")
        return nil if name.empty?

        attrs = parts.drop(1).each_with_object({}) do |p, h|
          k, _, v = p.partition("=")
          h[k.downcase] = v
        end

        domain = attrs["domain"].to_s.sub(/\A\./, "").downcase
        host_only = domain.empty?
        host = uri.host.to_s.downcase

        # A host may only scope a cookie to itself or to a parent of itself.
        # Without this, any hop in the sign-in chain could set — or silently
        # overwrite — `cloud-session` on `.healtheintent.com`, which is the one
        # cookie that authorizes the entire record.
        return nil unless host_only || host == domain || host.end_with?(".#{domain}")

        Cookie.new(
          name: name, value: value,
          domain: host_only ? uri.host.downcase : domain,
          path: attrs["path"].to_s.empty? ? "/" : attrs["path"],
          secure: attrs.key?("secure"),
          host_only: host_only
        )
      end

      def matching(uri)
        host = uri.host.downcase
        path = uri.path.empty? ? "/" : uri.path

        @cookies.values.select do |c|
          next false if c.secure && uri.scheme != "https"
          next false unless path.start_with?(c.path)

          c.host_only ? host == c.domain : host == c.domain || host.end_with?(".#{c.domain}")
        end
      end
    end
  end
end
