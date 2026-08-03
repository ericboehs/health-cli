require "json"
require "open3"

require "health/portal"

module Health
  module Portal
    # Portal sign-in credentials, read from 1Password at the moment they are
    # needed and never persisted. Unlike the FHIR side there is no token to
    # cache: every portal cookie is session-scoped, so a username and password
    # are genuinely required per run.
    class Credentials
      class Error < Portal::Error; end

      DEFAULT_ITEM = "cernerhealth.com (ericboehs)".freeze
      DEFAULT_VAULT = "Personal".freeze

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

        username = by_label["username"]
        password = by_label["password"]
        raise Error, "1Password item #{item.inspect} is missing a username or password" if username.to_s.empty? || password.to_s.empty?

        new(username: username, password: password)
      rescue Errno::ENOENT
        raise Error, "portal sign-in needs the `op` CLI, which is not installed"
      rescue JSON::ParserError => e
        raise Error, "unexpected response from `op` (#{e.message})"
      end
    end
  end
end
