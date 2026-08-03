require "simplecov"

SimpleCov.start do
  add_filter "/test/"
  enable_coverage :branch
  minimum_coverage line: 100, branch: 88
end

require "minitest/autorun"
require "tmpdir"
require "json"
require "socket"
require "net/http"
require "stringio"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "health/config"
require "health/encryption"
require "health/token_store"
require "health/oauth"
require "health/session"
require "health/cli"
require "health/commands/args"
require "health/commands/auth"
require "health/commands/config"

# Every test runs against a throwaway XDG root so nothing touches the real
# ~/.config/health or, more importantly, a real token store.
module XDGSandbox
  def setup
    super
    @tmp = Dir.mktmpdir("health-test")
    @old_env = ENV.to_h.slice("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME")
    ENV["XDG_CONFIG_HOME"] = File.join(@tmp, "config")
    ENV["XDG_DATA_HOME"] = File.join(@tmp, "data")
    ENV["XDG_STATE_HOME"] = File.join(@tmp, "state")
    Health::Config.ensure_dirs!
  end

  def teardown
    ENV.delete("XDG_CONFIG_HOME")
    ENV.delete("XDG_DATA_HOME")
    ENV.delete("XDG_STATE_HOME")
    @old_env.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
    super
  end

  def config(overrides = {})
    Health::Config.new({ "client_id" => "test-client-id" }.merge(overrides))
  end

  def write_config(hash)
    Health::Config.config_path.write(JSON.pretty_generate(hash))
  end

  # Pre-seeds the discovery cache so OAuth never reaches the network in tests.
  def seed_discovery(cfg, tenant: nil, extra: {})
    id = cfg.tenant_id(tenant)
    doc = {
      "authorization_endpoint" => "https://authorization.example/tenants/#{id}/authorize",
      "token_endpoint" => "https://authorization.example/tenants/#{id}/token"
    }.merge(extra)
    Health::Config.cache_dir.join("smart-config-#{id}.json").write(JSON.generate(doc))
    doc
  end
end

# A real HTTP server on loopback. Used instead of mocking Net::HTTP so the
# token and discovery paths — the ones that will actually face Cerner — are
# exercised end to end, request line and form encoding included.
class StubHTTP
  Request = Struct.new(:method, :path, :body, :headers)

  attr_reader :requests

  # routes: "GET /path" => [status, body_string]
  def initialize(routes)
    @routes = routes
    @requests = []
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    @thread.abort_on_exception = false
  end

  def port = @server.addr[1]
  def base = "http://127.0.0.1:#{port}"

  def stop
    @server.close unless @server.closed?
    @thread.kill
  end

  private

  def serve
    loop do
      conn = @server.accept
      begin
        handle(conn)
      ensure
        conn.close unless conn.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil # server closed
  end

  def handle(conn)
    method, path, = conn.gets.to_s.split(" ")
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      k, v = line.split(":", 2)
      headers[k.to_s.strip.downcase] = v.to_s.strip
    end
    body = headers["content-length"] ? conn.read(headers["content-length"].to_i) : nil
    @mutex.synchronize { @requests << Request.new(method, path, body, headers) }

    status, payload = @routes.fetch("#{method} #{path.split("?").first}", [404, "{}"])
    conn.print("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
               "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  end
end

class ConfigTest < Minitest::Test
  include XDGSandbox

  def test_tenant_aliases_resolve_to_uuids
    assert_equal "870ba945-f258-4fb9-a3f5-2c79586392b9", config.tenant_id
    assert_equal "2f4f2c9e-c9c5-48b1-95a2-1ba6a49a76fd", config.tenant_id("west")
    assert_equal "ec2458f2-1e24-41c8-b71b-0e701af7583d", config.tenant_id("sandbox")
  end

  def test_unknown_tenant_is_passed_through_as_a_raw_id
    raw = "00000000-1111-2222-3333-444444444444"
    assert_equal raw, config.tenant_id(raw)
  end

  def test_fhir_base_has_trailing_slash
    assert_equal "https://fhir-myrecord.cerner.com/r4/870ba945-f258-4fb9-a3f5-2c79586392b9/",
                 config.fhir_base
  end

  def test_redirect_port_and_path
    assert_equal 8412, config.redirect_port
    assert_equal "/callback", config.redirect_path
  end

  def test_redirect_path_defaults_to_slash_when_absent
    cfg = config("redirect_uri" => "http://localhost:9000")
    assert_equal "/", cfg.redirect_path
  end

  def test_default_scopes_are_v1_read_and_include_offline_access
    scopes = config.scopes
    assert_includes scopes, "offline_access"
    assert_includes scopes, "launch/patient"
    assert_includes scopes, "patient/Observation.read"
    # v2 scopes would make PKCE mandatory on tenants that don't advertise it.
    refute(scopes.any? { |s| s.end_with?(".rs") })
    # `launch` is an EHR-launch scope the console force-enables; a standalone
    # CLI must not request it.
    refute_includes scopes, "launch"
  end

  def test_load_raises_when_config_missing
    err = assert_raises(Health::Config::Error) { Health::Config.load }
    assert_match(/config not found/, err.message)
  end

  def test_load_raises_on_invalid_json
    Health::Config.config_path.write("{ not json")
    err = assert_raises(Health::Config::Error) { Health::Config.load }
    assert_match(/not valid JSON/, err.message)
  end

  def test_write_default_is_idempotent
    assert Health::Config.write_default!(client_id: "abc")
    refute Health::Config.write_default!(client_id: "xyz")
    assert_equal "abc", JSON.parse(Health::Config.config_path.read)["client_id"]
  end

  def test_plain_values_are_returned_unchanged
    assert_equal "test-client-id", config.client_id
  end

  # Minitest 6 dropped `stub`, and a fake `op` on PATH is a better test anyway:
  # it exercises the real Open3 call rather than asserting against a mock of it.
  def with_fake_op(script)
    bin = Pathname(@tmp).join("bin")
    bin.mkpath
    if script
      op = bin.join("op")
      op.write("#!/bin/sh\n#{script}\n")
      op.chmod(0o755)
    end
    old = ENV["PATH"]
    ENV["PATH"] = bin.to_s
    yield
  ensure
    ENV["PATH"] = old
  end

  def test_op_reference_raises_a_clear_error_when_op_is_missing
    cfg = config("client_id" => "op://Personal/health-cli/client id")
    with_fake_op(nil) do
      err = assert_raises(Health::Config::Error) { cfg.client_id }
      assert_match(/`op` CLI is not installed/, err.message)
    end
  end

  def test_op_reference_resolves_via_op_read
    cfg = config("client_id" => "op://Personal/health-cli/client id")
    # Echoes back the reference it was handed, proving the argv is right.
    with_fake_op('test "$1" = read && printf "resolved:%s\\n" "$2"') do
      assert_equal "resolved:op://Personal/health-cli/client id", cfg.client_id
    end
  end

  def test_op_reference_failure_is_reported
    cfg = config("client_id" => "op://Personal/health-cli/nope")
    with_fake_op('echo "item not found" >&2; exit 1') do
      err = assert_raises(Health::Config::Error) { cfg.client_id }
      assert_match(/1Password lookup failed/, err.message)
      assert_match(/item not found/, err.message)
    end
  end
end

class EncryptionTest < Minitest::Test
  include XDGSandbox

  def ssh_key
    key = Pathname(File.expand_path("~/.ssh/id_ed25519"))
    skip "no ed25519 key on this machine" unless key.exist? && Pathname("#{key}.pub").exist?
    key
  end

  def test_roundtrip
    enc = Health::Encryption.new
    skip "age not installed" unless enc.available?

    out = Pathname(@tmp).join("secret.age")
    enc.encrypt("hello phi", ssh_key, out)

    assert out.exist?
    assert_equal "hello phi", enc.decrypt(out, ssh_key)
    # Ciphertext must not contain the plaintext.
    refute_includes out.binread, "hello phi"
  end

  def test_encrypted_file_is_not_group_or_world_readable
    enc = Health::Encryption.new
    skip "age not installed" unless enc.available?

    out = Pathname(@tmp).join("perm.age")
    enc.encrypt("x", ssh_key, out)
    assert_equal 0o600, out.stat.mode & 0o777
  end

  def test_decrypt_returns_nil_for_missing_file
    assert_nil Health::Encryption.new.decrypt(Pathname(@tmp).join("nope.age"), ssh_key)
  end

  def test_unsupported_key_type_is_rejected_by_name
    pub = Pathname(@tmp).join("id_ecdsa.pub")
    pub.write("ecdsa-sha2-nistp256 AAAA... eric@example\n")
    err = assert_raises(Health::Encryption::Error) do
      Health::Encryption.new.public_key_for(Pathname(@tmp).join("id_ecdsa"))
    end
    assert_match(/ecdsa-sha2-nistp256/, err.message)
  end

  def test_available_is_false_when_age_is_absent
    original = Health::Encryption.instance_variable_get(:@age_bin)
    Health::Encryption.instance_variable_set(:@age_bin, "/nonexistent/age")
    enc = Health::Encryption.new

    refute enc.available?
    err = assert_raises(Health::Encryption::Error) do
      enc.encrypt("x", Pathname(@tmp).join("k"), Pathname(@tmp).join("o.age"))
    end
    assert_match(/age` encryption tool is not installed/, err.message)
  ensure
    Health::Encryption.instance_variable_set(:@age_bin, original)
  end

  def test_decrypt_requires_the_private_key_to_exist
    enc = Health::Encryption.new
    skip "age not installed" unless enc.available?

    file = Pathname(@tmp).join("some.age")
    file.write("x")
    err = assert_raises(Health::Encryption::Error) do
      enc.decrypt(file, Pathname(@tmp).join("no-such-key"))
    end
    assert_match(/SSH key not found/, err.message)
  end

  def test_missing_public_key_is_reported
    err = assert_raises(Health::Encryption::Error) do
      Health::Encryption.new.public_key_for(Pathname(@tmp).join("absent"))
    end
    assert_match(/public key not found/, err.message)
  end
end

class TokenStoreTest < Minitest::Test
  include XDGSandbox

  # A stand-in for age so token logic is testable without a key or the binary.
  class PlainCrypto
    def encrypt(content, _key, out)
      File.write(out, content)
      File.chmod(0o600, out)
      out
    end

    def decrypt(file, _key)
      File.exist?(file) ? File.read(file) : nil
    end
  end

  def store
    Health::TokenStore.new(config, encryption: PlainCrypto.new,
                                   path: Pathname(@tmp).join("tokens.age"))
  end

  def test_write_then_read_roundtrip
    s = store
    s.write("access_token" => "a", "refresh_token" => "r")
    assert_equal "a", s.read["access_token"]
  end

  def test_clear_removes_the_file
    s = store
    s.write("access_token" => "a")
    assert s.exist?
    s.clear
    refute s.exist?
  end

  def test_corrupt_store_gives_actionable_error
    s = store
    s.path.write("}}} not json")
    err = assert_raises(Health::TokenStore::Error) { s.read }
    assert_match(/health auth login/, err.message)
  end

  # The single most consequential behaviour in the file: Cerner does not return
  # a refresh_token on refresh, so a naive merge would destroy the only
  # long-lived credential we hold.
  def test_refresh_response_without_refresh_token_preserves_the_stored_one
    s = store
    s.write(s.merge_response({ "access_token" => "first", "refresh_token" => "keep-me",
                               "expires_in" => 570 }, tenant: "t1"))

    merged = s.merge_response({ "access_token" => "second", "expires_in" => 570 }, tenant: "t1")

    assert_equal "second", merged["access_token"]
    assert_equal "keep-me", merged["refresh_token"]
  end

  def test_merge_defaults_expiry_when_absent
    merged = store.merge_response({ "access_token" => "a" }, tenant: "t")
    assert_in_delta (Time.now + 570).to_i, merged["expires_at"], 5
  end

  def test_expired_accounts_for_skew
    now = Time.now
    fresh = { "access_token" => "a", "expires_at" => (now + 600).to_i }
    soon  = { "access_token" => "a", "expires_at" => (now + 30).to_i }

    refute Health::TokenStore.expired?(fresh, now: now)
    # Within the 60s skew: treated as expired so a long command refreshes first.
    assert Health::TokenStore.expired?(soon, now: now)
  end

  def test_expired_for_nil_and_blank_token
    assert Health::TokenStore.expired?(nil)
    assert Health::TokenStore.expired?({ "access_token" => "" })
  end

  def test_summary_never_contains_token_material
    tokens = { "access_token" => "SUPERSECRETACCESS", "refresh_token" => "SUPERSECRETREFRESH",
               "expires_at" => (Time.now + 300).to_i, "scope" => "a b c",
               "patient" => "123", "tenant" => "t", "obtained_at" => Time.now.to_i }

    summary = Health::TokenStore.summary(tokens)
    serialized = JSON.generate(summary)

    refute_includes serialized, "SUPERSECRETACCESS"
    refute_includes serialized, "SUPERSECRETREFRESH"
    assert_equal 3, summary["scope_count"]
    assert summary["authenticated"]
    assert summary["has_refresh_token"]
  end

  def test_summary_for_nil
    refute Health::TokenStore.summary(nil)["authenticated"]
  end

  def test_redact_replaces_secret_keys
    out = Health::TokenStore.redact("access_token" => "x", "refresh_token" => "y", "tenant" => "t")
    assert_equal "[redacted]", out["access_token"]
    assert_equal "[redacted]", out["refresh_token"]
    assert_equal "t", out["tenant"]
  end
end

class OAuthTest < Minitest::Test
  include XDGSandbox

  def test_pkce_challenge_matches_rfc7636_vector
    oauth = Health::OAuth.new(config, io: StringIO.new)
    # RFC 7636 Appendix B.
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", oauth.challenge_for(verifier)
  end

  def test_authorize_url_carries_required_params
    cfg = config
    seed_discovery(cfg)
    oauth = Health::OAuth.new(cfg, io: StringIO.new)

    url = oauth.authorize_url(state: "st8", verifier: "verifier-value")
    params = URI.decode_www_form(URI(url).query).to_h

    assert_equal "code", params["response_type"]
    assert_equal "test-client-id", params["client_id"]
    assert_equal "http://localhost:8412/callback", params["redirect_uri"]
    assert_equal "st8", params["state"]
    assert_equal cfg.fhir_base, params["aud"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal oauth.challenge_for("verifier-value"), params["code_challenge"]
    # The verifier itself must never appear in the front-channel URL.
    refute_includes url, "verifier-value"
  end

  def test_pkce_can_be_disabled_for_a_tenant_that_rejects_it
    cfg = config("pkce" => false)
    seed_discovery(cfg)
    url = Health::OAuth.new(cfg, io: StringIO.new).authorize_url(state: "s", verifier: "v")
    refute_includes url, "code_challenge"
  end

  def test_pkce_supported_reflects_discovery
    cfg = config
    seed_discovery(cfg)
    refute Health::OAuth.new(cfg, io: StringIO.new).pkce_supported?

    other = config("tenant" => "sandbox")
    seed_discovery(other, extra: { "code_challenge_methods_supported" => ["S256"] })
    assert Health::OAuth.new(other, io: StringIO.new).pkce_supported?
  end

  def test_missing_client_id_is_reported
    cfg = Health::Config.new({})
    seed_discovery(cfg)
    err = assert_raises(Health::OAuth::Error) do
      Health::OAuth.new(cfg, io: StringIO.new).authorize_url(state: "s", verifier: "v")
    end
    assert_match(/no client_id/, err.message)
  end

  def test_placeholder_client_id_is_rejected
    cfg = Health::Config.new("client_id" => "PASTE-YOUR-CLIENT-ID")
    seed_discovery(cfg)
    err = assert_raises(Health::OAuth::Error) do
      Health::OAuth.new(cfg, io: StringIO.new).authorize_url(state: "s", verifier: "v")
    end
    assert_match(/placeholder/, err.message)
  end

  def test_empty_cached_discovery_is_ignored_rather_than_pinned
    cfg = config
    Health::Config.cache_dir.join("smart-config-#{cfg.tenant_id}.json").write("{}")
    oauth = Health::OAuth.new(cfg, io: StringIO.new)
    # With no network available in tests, an honoured empty cache would return
    # {} and fail on fetch; we assert it tries to refetch instead.
    assert_nil oauth.send(:read_cached_discovery)
  end

  def test_corrupt_discovery_cache_is_ignored
    cfg = config
    Health::Config.cache_dir.join("smart-config-#{cfg.tenant_id}.json").write("not json")
    assert_nil Health::OAuth.new(cfg, io: StringIO.new).send(:read_cached_discovery)
  end

  def test_stale_discovery_cache_is_ignored
    cfg = config
    path = Health::Config.cache_dir.join("smart-config-#{cfg.tenant_id}.json")
    seed_discovery(cfg)
    File.utime(Time.now - 100_000, Time.now - 100_000, path)
    assert_nil Health::OAuth.new(cfg, io: StringIO.new).send(:read_cached_discovery)
  end

  # ---- loopback listener -------------------------------------------------

  def with_listener(cfg, expected_state:)
    server = TCPServer.new("127.0.0.1", 0)
    oauth = Health::OAuth.new(cfg, io: StringIO.new)
    result = nil
    error = nil
    thread = Thread.new do
      result = oauth.send(:await_code, server, expected_state: expected_state)
    rescue StandardError => e
      error = e
    end
    yield server.addr[1]
    thread.join(5)
    [result, error]
  ensure
    server.close unless server.closed?
  end

  def get(port, path)
    Net::HTTP.start("127.0.0.1", port) { |h| h.request(Net::HTTP::Get.new(path)) }
  end

  def test_captures_code_on_the_registered_path
    result, error = with_listener(config, expected_state: "st8") do |port|
      res = get(port, "/callback?code=THECODE&state=st8")
      assert_equal "200", res.code
    end
    assert_nil error
    assert_equal "THECODE", result
  end

  def test_other_paths_404_and_the_listener_keeps_waiting
    result, error = with_listener(config, expected_state: "st8") do |port|
      assert_equal "404", get(port, "/favicon.ico").code
      get(port, "/callback?code=LATER&state=st8")
    end
    assert_nil error
    assert_equal "LATER", result
  end

  def test_state_mismatch_is_refused
    result, error = with_listener(config, expected_state: "expected") do |port|
      get(port, "/callback?code=X&state=attacker")
    end
    assert_nil result
    assert_instance_of Health::OAuth::Error, error
    assert_match(/state mismatch/, error.message)
  end

  def test_error_param_becomes_denied
    result, error = with_listener(config, expected_state: "st8") do |port|
      get(port, "/callback?error=access_denied&error_description=nope&state=st8")
    end
    assert_nil result
    assert_instance_of Health::OAuth::Denied, error
    assert_match(/access_denied/, error.message)
  end

  def test_missing_code_is_reported
    result, error = with_listener(config, expected_state: "st8") do |port|
      get(port, "/callback?state=st8")
    end
    assert_nil result
    assert_match(/no authorization code/, error.message)
  end
end

class OAuthNetworkTest < Minitest::Test
  include XDGSandbox

  # Overrides the one method that would otherwise launch a real browser, and
  # drives the redirect itself — so login! is covered end to end.
  class ScriptedOAuth < Health::OAuth
    attr_reader :opened

    def initialize(config, callback:, **kw)
      super(config, **kw)
      @callback = callback
    end

    def open_browser(url)
      @opened = url
      state = URI.decode_www_form(URI(url).query).to_h["state"]
      Thread.new { @callback.call(state) }
    end
  end

  def teardown
    @stub&.stop
    super
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def start_stub(routes)
    @stub = StubHTTP.new(routes)
  end

  def token_config(routes, extra = {})
    start_stub(routes)
    cfg = config({ "fhir_host" => "#{@stub.base}/r4" }.merge(extra))
    seed_discovery(cfg, extra: { "token_endpoint" => "#{@stub.base}/token" })
    cfg
  end

  TOKEN_OK = JSON.generate("access_token" => "AT", "refresh_token" => "RT",
                           "expires_in" => 570, "patient" => "12345",
                           "scope" => "patient/Observation.read offline_access")

  def test_exchange_code_posts_a_public_client_form
    cfg = token_config("POST /token" => [200, TOKEN_OK])
    body = Health::OAuth.new(cfg, io: StringIO.new).exchange_code("THECODE", verifier: "VER")

    assert_equal "AT", body["access_token"]
    form = URI.decode_www_form(@stub.requests.last.body).to_h
    assert_equal "authorization_code", form["grant_type"]
    assert_equal "THECODE", form["code"]
    assert_equal "VER", form["code_verifier"]
    assert_equal "test-client-id", form["client_id"]
    assert_equal cfg.redirect_uri, form["redirect_uri"]
    # Public client: no client_secret, and no Basic auth header.
    refute form.key?("client_secret")
    refute @stub.requests.last.headers.key?("authorization")
  end

  def test_exchange_code_omits_verifier_when_pkce_is_off
    cfg = token_config({ "POST /token" => [200, TOKEN_OK] }, "pkce" => false)
    Health::OAuth.new(cfg, io: StringIO.new).exchange_code("C", verifier: "VER")

    refute URI.decode_www_form(@stub.requests.last.body).to_h.key?("code_verifier")
  end

  def test_refresh_re_requests_the_same_scopes
    cfg = token_config("POST /token" => [200, TOKEN_OK])
    Health::OAuth.new(cfg, io: StringIO.new).refresh("RT")

    form = URI.decode_www_form(@stub.requests.last.body).to_h
    assert_equal "refresh_token", form["grant_type"]
    assert_equal "RT", form["refresh_token"]
    # Narrowing the grant on refresh would surface much later as a 403.
    assert_equal cfg.scopes.join(" "), form["scope"]
  end

  def test_token_error_surfaces_oauth_error_description
    body = JSON.generate("error" => "invalid_grant", "error_description" => "expired")
    cfg = token_config("POST /token" => [400, body])

    err = assert_raises(Health::OAuth::Error) do
      Health::OAuth.new(cfg, io: StringIO.new).refresh("RT")
    end
    assert_match(/HTTP 400/, err.message)
    assert_match(/invalid_grant: expired/, err.message)
  end

  def test_non_json_token_error_still_reports_the_status
    cfg = token_config("POST /token" => [502, "<html>gateway</html>"])
    err = assert_raises(Health::OAuth::Error) do
      Health::OAuth.new(cfg, io: StringIO.new).refresh("RT")
    end
    assert_match(/HTTP 502/, err.message)
  end

  def test_success_without_an_access_token_is_rejected
    cfg = token_config("POST /token" => [200, JSON.generate("token_type" => "Bearer")])
    err = assert_raises(Health::OAuth::Error) do
      Health::OAuth.new(cfg, io: StringIO.new).refresh("RT")
    end
    assert_match(/no access_token/, err.message)
  end

  # ---- discovery ---------------------------------------------------------

  def discovery_config(routes)
    start_stub(routes)
    config("fhir_host" => "#{@stub.base}/r4", "tenant" => "t")
  end

  def test_discovery_is_fetched_and_cached
    doc = JSON.generate("authorization_endpoint" => "https://a.example/authorize",
                        "token_endpoint" => "https://a.example/token",
                        "code_challenge_methods_supported" => ["S256"])
    cfg = discovery_config("GET /r4/t/.well-known/smart-configuration" => [200, doc])

    oauth = Health::OAuth.new(cfg, io: StringIO.new)
    assert_equal "https://a.example/authorize", oauth.authorization_endpoint
    assert oauth.pkce_supported?

    # Cached on disk, so a second instance makes no second request.
    assert_equal "https://a.example/token", Health::OAuth.new(cfg, io: StringIO.new).token_endpoint
    assert_equal 1, @stub.requests.size
  end

  def test_discovery_http_failure_names_the_tenant
    cfg = discovery_config("GET /r4/t/.well-known/smart-configuration" => [500, "{}"])
    err = assert_raises(Health::OAuth::Error) { Health::OAuth.new(cfg, io: StringIO.new).discovery }
    assert_match(/discovery failed for tenant t/, err.message)
  end

  def test_discovery_without_endpoints_is_rejected_rather_than_cached
    body = JSON.generate("issuer" => "https://a.example")
    cfg = discovery_config("GET /r4/t/.well-known/smart-configuration" => [200, body])

    assert_raises(Health::OAuth::Error) { Health::OAuth.new(cfg, io: StringIO.new).discovery }
    refute Health::Config.cache_dir.join("smart-config-t.json").exist?
  end

  # ---- full login --------------------------------------------------------

  def login_config(routes)
    start_stub(routes)
    cfg = config("fhir_host" => "#{@stub.base}/r4",
                 "redirect_uri" => "http://localhost:#{free_port}/callback")
    seed_discovery(cfg, extra: { "token_endpoint" => "#{@stub.base}/token" })
    cfg
  end

  def test_login_round_trip
    cfg = login_config("POST /token" => [200, TOKEN_OK])
    oauth = ScriptedOAuth.new(cfg, io: StringIO.new, callback: ->(state) {
      Net::HTTP.get(URI("#{cfg.redirect_uri}?code=AUTHCODE&state=#{state}"))
    })

    tokens = oauth.login!

    assert_equal "AT", tokens["access_token"]
    assert_equal "12345", tokens["patient"]
    assert_equal "AUTHCODE", URI.decode_www_form(@stub.requests.last.body).to_h["code"]
    assert_includes oauth.opened, "code_challenge_method=S256"
  end

  def test_login_reports_a_denied_authorization
    cfg = login_config("POST /token" => [200, TOKEN_OK])
    oauth = ScriptedOAuth.new(cfg, io: StringIO.new, callback: ->(state) {
      Net::HTTP.get(URI("#{cfg.redirect_uri}?error=access_denied&state=#{state}"))
    })

    err = assert_raises(Health::OAuth::Denied) { oauth.login! }
    assert_match(/access_denied/, err.message)
    # No token request was made.
    assert_empty @stub.requests
  end

  def test_login_explains_a_busy_redirect_port
    cfg = login_config("POST /token" => [200, TOKEN_OK])
    squatter = TCPServer.new("127.0.0.1", cfg.redirect_port)
    begin
      oauth = ScriptedOAuth.new(cfg, io: StringIO.new, callback: ->(_s) {})
      err = assert_raises(Health::OAuth::Error) { oauth.login! }
      assert_match(/already in use/, err.message)
      assert_match(/redirect_uri/, err.message)
    ensure
      squatter.close
    end
  end
end

class SessionTest < Minitest::Test
  include XDGSandbox

  class FakeOAuth
    attr_reader :refreshed, :logged_in

    def initialize(response: nil, raise_error: nil)
      @response = response || { "access_token" => "new-access", "expires_in" => 570 }
      @raise_error = raise_error
      @refreshed = 0
      @logged_in = 0
    end

    def tenant_id = "tenant-x"

    def refresh(_token)
      @refreshed += 1
      raise @raise_error if @raise_error

      @response
    end

    def login!
      @logged_in += 1
      { "access_token" => "fresh", "refresh_token" => "r1", "expires_in" => 570, "patient" => "p1" }
    end
  end

  def build(tokens: nil, oauth: FakeOAuth.new)
    store = Health::TokenStore.new(config, encryption: TokenStoreTest::PlainCrypto.new,
                                           path: Pathname(@tmp).join("t.age"))
    store.write(tokens) if tokens
    [Health::Session.new(config, store: store, oauth: oauth, io: StringIO.new), store]
  end

  def test_access_token_raises_when_not_signed_in
    session, = build
    assert_raises(Health::Session::NotAuthenticated) { session.access_token! }
  end

  def test_valid_token_is_returned_without_refresh
    oauth = FakeOAuth.new
    session, = build(tokens: { "access_token" => "still-good",
                               "expires_at" => (Time.now + 500).to_i }, oauth: oauth)
    assert_equal "still-good", session.access_token!
    assert_equal 0, oauth.refreshed
  end

  def test_expired_token_triggers_a_refresh_and_persists_it
    oauth = FakeOAuth.new
    session, store = build(tokens: { "access_token" => "old", "refresh_token" => "r1",
                                     "expires_at" => (Time.now - 10).to_i }, oauth: oauth)

    assert_equal "new-access", session.access_token!
    assert_equal 1, oauth.refreshed
    # Persisted, and the non-rotating refresh token survived.
    assert_equal "new-access", store.read["access_token"]
    assert_equal "r1", store.read["refresh_token"]
  end

  def test_expired_without_refresh_token_demands_reauth
    session, = build(tokens: { "access_token" => "old", "expires_at" => (Time.now - 10).to_i })
    err = assert_raises(Health::Session::NotAuthenticated) { session.access_token! }
    assert_match(/health auth login/, err.message)
  end

  def test_refresh_failure_is_translated_to_reauth_guidance
    oauth = FakeOAuth.new(raise_error: Health::OAuth::Error.new("invalid_grant"))
    session, = build(tokens: { "access_token" => "old", "refresh_token" => "r1",
                               "expires_at" => (Time.now - 10).to_i }, oauth: oauth)

    err = assert_raises(Health::Session::NotAuthenticated) { session.access_token! }
    assert_match(/no longer valid/, err.message)
    assert_match(/health auth login/, err.message)
  end

  def test_login_persists_tokens
    oauth = FakeOAuth.new
    session, store = build(oauth: oauth)
    session.login!

    assert_equal 1, oauth.logged_in
    assert_equal "fresh", store.read["access_token"]
    assert_equal "tenant-x", store.read["tenant"]
    assert session.authenticated?
  end

  def test_logout_clears_the_store
    session, store = build(tokens: { "access_token" => "a" })
    session.logout!
    refute store.exist?
    refute session.authenticated?
  end
end

class CLITest < Minitest::Test
  include XDGSandbox

  def capture
    out, err = StringIO.new, StringIO.new
    old_out, old_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = yield
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = old_out, old_err
  end

  def test_help_exits_zero
    code, out, = capture { Health::CLI.run(["help"]) }
    assert_equal 0, code
    assert_match(/auth login/, out)
  end

  def test_no_args_shows_help
    code, out, = capture { Health::CLI.run([]) }
    assert_equal 0, code
    assert_match(/Usage: health/, out)
  end

  def test_unknown_command_exits_two
    code, _out, err = capture { Health::CLI.run(["nope"]) }
    assert_equal 2, code
    assert_match(/unknown command/, err)
  end

  def test_missing_config_is_a_runtime_error_not_a_backtrace
    code, _out, err = capture { Health::CLI.run(["auth", "status"]) }
    assert_equal 1, code
    assert_match(/config not found/, err)
  end

  def test_config_init_then_show
    code, out, = capture { Health::CLI.run(["config", "init", "cid-123"]) }
    assert_equal 0, code
    assert_match(/Wrote/, out)

    code, out, = capture { Health::CLI.run(["config", "show"]) }
    assert_equal 0, code
    assert_equal "cid-123", JSON.parse(out)["client_id"]
  end

  def test_config_show_does_not_expand_op_references
    write_config("client_id" => "op://Personal/health-cli/client id")
    _code, out, = capture { Health::CLI.run(["config", "show"]) }
    assert_match(%r{op://Personal}, out)
  end

  def test_config_path
    _code, out, = capture { Health::CLI.run(["config", "path"]) }
    assert_match(/health\/config\.json/, out)
  end

  def test_unknown_config_subcommand_exits_two
    code, _out, err = capture { Health::CLI.run(["config", "bogus"]) }
    assert_equal 2, code
    assert_match(/unknown config subcommand/, err)
  end

  def test_unknown_auth_subcommand_exits_two
    write_config("client_id" => "x")
    code, _out, err = capture { Health::CLI.run(["auth", "bogus"]) }
    assert_equal 2, code
    assert_match(/unknown auth subcommand/, err)
  end

  def test_tenant_flag_without_value_exits_two
    write_config("client_id" => "x")
    code, _out, err = capture { Health::CLI.run(["auth", "--tenant"]) }
    assert_equal 2, code
    assert_match(/--tenant needs a value/, err)
  end

  def test_auth_status_when_not_signed_in_exits_one
    write_config("client_id" => "x")
    code, out, = capture { Health::CLI.run(["auth", "status"]) }
    assert_equal 1, code
    assert_match(/Not signed in/, out)
  end

  def test_auth_status_json
    write_config("client_id" => "x")
    code, out, = capture { Health::CLI.run(["--json", "auth", "status"]) }
    assert_equal 1, code
    refute JSON.parse(out)["authenticated"]
  end

  def test_auth_logout_with_no_store
    write_config("client_id" => "x")
    code, out, = capture { Health::CLI.run(["auth", "logout"]) }
    assert_equal 0, code
    assert_match(/No token store/, out)
  end

  def test_global_flags_are_stripped_before_dispatch
    write_config("client_id" => "x")
    code, _out, = capture { Health::CLI.run(["-q", "--json", "auth", "status"]) }
    assert_equal 1, code
  end

  # Exercises the Auth command against a stub session so status/login/refresh
  # formatting is covered without a browser or the network.
  class StubSession
    attr_reader :store

    def initialize(summary:, raise_on: nil)
      @summary = summary
      @raise_on = raise_on
      @store = Struct.new(:exist?).new(true)
    end

    def summary = @summary
    def login! = (raise @raise_on if @raise_on)
    def refresh! = (raise @raise_on if @raise_on)
    def logout! = true
  end

  def signed_in_summary
    { "authenticated" => true, "patient" => "p1", "tenant" => "t1", "scope_count" => 24,
      "access_token_expires_in" => 500, "access_token_expired" => false,
      "has_refresh_token" => true, "obtained_at" => "2026-08-03T10:00:00Z" }
  end

  def run_auth(argv, session)
    global = Health::GlobalOptions.new(json: argv.include?("--json"), quiet: false, verbose: false)
    out = StringIO.new
    cmd = Health::Commands::Auth.new(global, session_factory: ->(_c, _t) { session },
                                             io: out, err: StringIO.new)
    [cmd.run(argv.reject { |a| a == "--json" }), out.string]
  end

  def test_auth_status_signed_in_prints_no_token_material
    write_config("client_id" => "x")
    code, out = run_auth(["status"], StubSession.new(summary: signed_in_summary))
    assert_equal 0, code
    assert_match(/patient:\s+p1/, out)
    assert_match(/access token:\s+500s/, out)
    assert_match(/refresh token:\s+stored/, out)
  end

  def test_auth_status_shows_expired
    write_config("client_id" => "x")
    summary = signed_in_summary.merge("access_token_expired" => true, "access_token_expires_in" => -5)
    _code, out = run_auth(["status"], StubSession.new(summary: summary))
    assert_match(/access token:\s+expired/, out)
  end

  def test_auth_login_reports_denial
    write_config("client_id" => "x")
    session = StubSession.new(summary: signed_in_summary,
                              raise_on: Health::OAuth::Denied.new("authorization denied: access_denied"))
    code, = run_auth(["login"], session)
    assert_equal 1, code
  end

  def test_auth_refresh_prints_summary
    write_config("client_id" => "x")
    code, out = run_auth(["refresh"], StubSession.new(summary: signed_in_summary))
    assert_equal 0, code
    assert_match(/Refreshed/, out)
  end

  def test_auth_login_json_output
    write_config("client_id" => "x")
    code, out = run_auth(["login", "--json"], StubSession.new(summary: signed_in_summary))
    assert_equal 0, code
    assert JSON.parse(out)["authenticated"]
  end

  def test_auth_login_reports_a_generic_oauth_error
    write_config("client_id" => "x")
    session = StubSession.new(summary: signed_in_summary,
                              raise_on: Health::OAuth::Error.new("token request failed (HTTP 400)"))
    code, = run_auth(["login"], session)
    assert_equal 1, code
  end

  def test_auth_refresh_reports_a_dead_grant_as_reauth
    write_config("client_id" => "x")
    session = StubSession.new(summary: signed_in_summary,
                              raise_on: Health::Session::NotAuthenticated.new("grant is no longer valid"))
    code, = run_auth(["refresh"], session)
    assert_equal 1, code
  end

  def test_tenant_flag_is_consumed_before_the_subcommand
    write_config("client_id" => "x")
    seen = nil
    global = Health::GlobalOptions.new(json: false, quiet: false, verbose: false)
    cmd = Health::Commands::Auth.new(global, io: StringIO.new, err: StringIO.new,
      session_factory: ->(_c, tenant) {
        seen = tenant
        StubSession.new(summary: signed_in_summary)
      })

    assert_equal 0, cmd.run(["--tenant", "west", "status"])
    assert_equal "west", seen
  end

  def test_status_shows_unknown_expiry_when_the_token_has_none
    write_config("client_id" => "x")
    summary = signed_in_summary.merge("access_token_expires_in" => nil)
    _code, out = run_auth(["status"], StubSession.new(summary: summary))
    assert_match(/access token:\s+unknown/, out)
  end

  def test_config_init_twice_leaves_the_first_alone
    capture { Health::CLI.run(["config", "init", "first"]) }
    code, out, = capture { Health::CLI.run(["config", "init", "second"]) }

    assert_equal 0, code
    assert_match(/already exists/, out)
    assert_equal "first", JSON.parse(Health::Config.config_path.read)["client_id"]
  end

  def test_config_init_without_a_client_id_prompts_for_one
    code, out, = capture { Health::CLI.run(["config", "init"]) }
    assert_equal 0, code
    assert_match(/Set your client_id/, out)
    assert_match(/PASTE-/, Health::Config.config_path.read)
  end

  def test_config_edit_creates_the_file_then_opens_the_editor
    with_env("VISUAL" => "/usr/bin/true", "EDITOR" => nil) do
      code, = capture { Health::CLI.run(["config", "edit"]) }
      assert_equal 0, code
      assert Health::Config.config_path.exist?
    end
  end

  def test_config_edit_returns_one_when_the_editor_fails
    write_config("client_id" => "x")
    with_env("VISUAL" => nil, "EDITOR" => "/usr/bin/false") do
      code, = capture { Health::CLI.run(["config", "edit"]) }
      assert_equal 1, code
    end
  end

  def test_verbose_flag_is_accepted
    write_config("client_id" => "x")
    code, = capture { Health::CLI.run(["-v", "auth", "status"]) }
    assert_equal 1, code
  end

  def test_interrupt_exits_130
    # `system` defers SIGINT until the child is reaped, so a fake editor that
    # signals its parent exercises the same path as Ctrl-C at a prompt.
    editor = Pathname(@tmp).join("interrupting-editor")
    editor.write("#!/bin/sh\nkill -INT $PPID\n")
    editor.chmod(0o755)

    write_config("client_id" => "x")
    with_env("VISUAL" => editor.to_s, "EDITOR" => nil) do
      code, _out, err = capture { Health::CLI.run(["config", "edit"]) }
      assert_equal 130, code
      assert_match(/interrupted/, err)
    end
  end

  def with_env(pairs)
    old = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
