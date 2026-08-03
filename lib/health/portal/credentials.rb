require "json"
require "open3"

require "health/portal"

module Health
  module Portal
    # Portal sign-in credentials, read at the moment they are needed and never
    # persisted. Unlike the FHIR side there is no token to cache: every portal
    # cookie is session-scoped, so a username and password are genuinely
    # required per run.
    #
    # Two sources, chosen by `portal.source` in config.json:
    #
    # `op` (the default) reads a 1Password item. Every read costs a biometric
    # prompt, which is why the portal session is cached — this runs only when
    # that cache has died.
    #
    # `keychain` reads a macOS Keychain item, and reads silently when the item
    # was created with `-T /usr/bin/security`. That is the trade: no prompt on
    # a headless run, in exchange for the password being readable by anything
    # running as this user, and not syncing to another machine.
    class Credentials
      class Error < Portal::Error; end

      # Overridable via `portal.op_item` / `portal.op_vault` in config.json,
      # since 1Password item names are personal to whoever is running this.
      DEFAULT_ITEM = "cernerhealth.com".freeze
      DEFAULT_VAULT = "Personal".freeze

      # And `portal.keychain_service` / `portal.keychain_account` for the other
      # source. The account is optional: without one, the item's own is used,
      # which keeps the username out of a config file that is not encrypted.
      DEFAULT_SERVICE = DEFAULT_ITEM

      attr_reader :username, :password

      def initialize(username:, password:)
        @username = username
        @password = password
      end

      # Never let a password reach a log line, a backtrace or `inspect`.
      def inspect = "#<Health::Portal::Credentials username=#{@username.inspect}>"
      alias to_s inspect

      def self.load(config = nil)
        portal = (config.respond_to?(:data) ? config.data["portal"] : nil) || {}

        case (source = portal["source"] || "op")
        when "op" then from_op(portal)
        when "keychain" then from_keychain(portal)
        else
          raise Error, "unknown portal credential source #{source.inspect} — " \
                       "set portal.source to \"op\" or \"keychain\""
        end
      end

      def self.from_op(portal)
        item = portal["op_item"] || DEFAULT_ITEM
        vault = portal["op_vault"] || DEFAULT_VAULT

        # One `op` invocation for both fields keeps this to a single biometric
        # prompt.
        out, err, status = Open3.capture3(
          "op", "item", "get", item, "--vault", vault,
          "--fields", "label=username,label=password", "--reveal", "--format", "json"
        )
        raise Error, "1Password lookup failed for #{item.inspect}: #{err.strip}" unless status.success?

        fields = JSON.parse(out)
        fields = [fields] unless fields.is_a?(Array)
        by_label = fields.to_h { |f| [f["label"], f["value"]] }

        build(by_label["username"], by_label["password"], "1Password item #{item.inspect}")
      rescue Errno::ENOENT
        raise Error, "portal sign-in needs the `op` CLI, which is not installed"
      rescue JSON::ParserError => e
        raise Error, "unexpected response from `op` (#{e.message})"
      end

      # `-g` rather than `-w`, for two reasons. It returns the account
      # alongside the password, so one invocation still covers both fields; and
      # it says which encoding the password came back in. `-w` prints raw text
      # for a printable-ASCII secret and bare hex for anything else, with
      # nothing to tell the two apart — a password of "deadbeef" is
      # indistinguishable from the hex for "\xDE\xAD\xBE\xEF".
      def self.from_keychain(portal)
        service = portal["keychain_service"] || DEFAULT_SERVICE
        account = portal["keychain_account"]
        argv = ["security", "find-generic-password", "-s", service]
        argv.push("-a", account) if account

        out, err, status = Open3.capture3(*argv, "-g")
        raise Error, "Keychain lookup failed for #{service.inspect}: #{scrub(err)}" unless status.success?

        # `security` writes the attributes to stdout and the password to
        # stderr, which is also why `scrub` exists: everything else in this
        # class can quote stderr into a message, and this one cannot.
        build(account || field(out, /"acct"<blob>=(.*)$/),
          field(err, /^password: (.*)$/),
          "Keychain item #{service.inspect}")
      rescue Errno::ENOENT
        raise Error, "portal sign-in needs the `security` CLI, which is not installed"
      end

      def self.build(username, password, described)
        if username.to_s.empty? || password.to_s.empty?
          raise Error, "#{described} is missing a username or password"
        end

        new(username: username, password: password)
      end

      # Both fields come back either quoted or as `0x…` hex, hex being used for
      # anything that is not printable ASCII. The quoted form is read to the
      # last quote on the line rather than the first, since a password may
      # contain one.
      def self.field(text, pattern)
        raw = text.to_s[pattern, 1]&.strip
        return nil if raw.nil?
        return [Regexp.last_match(1)].pack("H*").force_encoding(Encoding::UTF_8) if raw =~ /\A0x([0-9A-Fa-f]+)/

        raw[/\A"(.*)"/, 1]
      end

      # No stderr from `security` reaches a message without passing through
      # here. It is the one stream in this file that carries the secret.
      def self.scrub(text)
        text.to_s.lines.reject { |line| line.start_with?("password:") }.join.strip
      end

      private_class_method :from_op, :from_keychain, :build, :field, :scrub
    end
  end
end
