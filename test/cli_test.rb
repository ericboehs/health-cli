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
require "health/portal"
require "health/portal/cookie_jar"
require "health/portal/form"
require "health/portal/http"
require "health/portal/credentials"
require "health/portal/login"
require "health/portal/session_store"
require "health/portal/record"
require "health/portal/results"
require "health/portal/history_index"
require "health/commands/labs"

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

  def capture
    out, err = StringIO.new, StringIO.new
    old_out, old_err = $stdout, $stderr
    $stdout, $stderr = out, err
    code = yield
    [code, out.string, err.string]
  ensure
    $stdout, $stderr = old_out, old_err
  end

  # Redirects the real $stdout/$stderr, since CLI.run writes to them directly.
  # Minitest 6 dropped `stub`, and a fake `op` on PATH is a better test anyway:
  # it exercises the real Open3 call rather than asserting against a mock of it.
  # Passing a nil script leaves PATH empty, which is how "op isn't installed"
  # is reproduced.
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

  # routes: "GET /path" => [status, body_string] or
  #         "GET /path" => [status, body_string, {"Header" => value_or_array}] or
  #         "GET /path" => ->(request) { one of the above }
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
    request = Request.new(method, path, body, headers)
    @mutex.synchronize { @requests << request }

    route = @routes.fetch("#{method} #{path.split("?").first}", [404, "{}"])
    status, payload, extra = route.respond_to?(:call) ? route.call(request) : route
    lines = { "Content-Type" => "application/json" }.merge(extra || {}).flat_map do |k, v|
      Array(v).map { |one| "#{k}: #{one}" }
    end
    conn.print("HTTP/1.1 #{status} X\r\n#{lines.join("\r\n")}\r\n" \
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

# One file per tenant. Before this, `--tenant west` overwrote the grant for
# `central`, because every login rewrites the whole store.
class TokenStoreTenantTest < Minitest::Test
  include XDGSandbox

  Crypto = TokenStoreTest::PlainCrypto

  def store(tenant) = Health::TokenStore.new(config, tenant: tenant, encryption: Crypto.new)

  def test_each_tenant_gets_its_own_file
    central, west = store("central"), store("west")

    refute_equal central.path, west.path
    assert_equal Health::Config::TENANTS["central"], File.basename(central.path, ".age")
  end

  def test_signing_into_a_second_tenant_leaves_the_first_alone
    store("central").write("access_token" => "central-token", "tenant" => "central")
    store("west").write("access_token" => "west-token", "tenant" => "west")

    assert_equal "central-token", store("central").read["access_token"]
    assert_equal "west-token", store("west").read["access_token"]
  end

  # `--tenant` takes an arbitrary string so a tenant Oracle adds later needs no
  # code change; that string must not get to choose a path.
  def test_a_tenant_id_cannot_escape_the_token_directory
    path = store("../../etc/passwd").path

    assert_equal Health::Config.token_dir.to_s, File.dirname(path)
    assert_equal ".._.._etc_passwd.age", File.basename(path)
  end

  def test_paths_and_clear_all_span_every_tenant
    store("central").write("access_token" => "a")
    store("west").write("access_token" => "b")
    Health::Config.legacy_token_path.write("old")

    assert_equal 3, Health::TokenStore.paths.size

    Health::TokenStore.clear_all

    assert_empty Health::TokenStore.paths
  end

  def test_a_legacy_store_moves_under_the_tenant_it_names
    legacy = Health::Config.legacy_token_path
    legacy.write(JSON.generate("access_token" => "a", "refresh_token" => "keep",
      "tenant" => Health::Config::TENANTS["west"]))

    moved = Health::TokenStore.migrate_legacy!(config, encryption: Crypto.new)

    refute legacy.exist?
    assert_equal store("west").path.to_s, moved.to_s
    assert_equal "keep", store("west").read["refresh_token"]
  end

  def test_migration_is_a_no_op_without_a_legacy_store
    assert_nil Health::TokenStore.migrate_legacy!(config, encryption: Crypto.new)
  end

  # Deleting either of these would throw away a refresh token that may still
  # work, so they are left where they are for `auth login` to supersede.
  def test_a_legacy_store_that_names_no_tenant_or_will_not_parse_is_left_in_place
    legacy = Health::Config.legacy_token_path

    legacy.write(JSON.generate("access_token" => "a"))
    assert_nil Health::TokenStore.migrate_legacy!(config, encryption: Crypto.new)
    assert legacy.exist?

    legacy.write("}}} not json")
    assert_nil Health::TokenStore.migrate_legacy!(config, encryption: Crypto.new)
    assert legacy.exist?
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

  # A discovery fetch against a host that does not resolve. The point is that
  # the operator gets a sentence rather than a backtrace: Net::HTTP frames
  # print the request URL, which on a record endpoint carries the person id.
  def test_an_unreachable_host_is_a_message_not_a_backtrace
    write_config("client_id" => "x", "fhir_host" => "https://unresolvable.invalid/r4")
    code, _out, err = capture { Health::CLI.run(["auth", "login"]) }

    assert_equal 1, code
    assert_match(/could not reach the server/, err)
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

  # Signing out of one tenant while another tenant's grant sits on disk would
  # not be signing out.
  def test_auth_logout_removes_every_tenants_grant
    write_config("client_id" => "x")
    Health::Config.ensure_dirs!
    %w[central west].each { |t| Health::Config.token_path(Health::Config::TENANTS[t]).write("x") }

    code, out, = capture { Health::CLI.run(["auth", "logout"]) }

    assert_equal 0, code
    assert_match(/2 token stores removed/, out)
    assert_empty Health::TokenStore.paths
  end

  # The store used to be one file for every tenant. Anything left there is
  # moved into place on the way through, so a login predating the split keeps
  # working instead of silently reading as signed out.
  def test_auth_migrates_a_pre_split_token_store
    enc = Health::Encryption.new
    key = Pathname(File.expand_path("~/.ssh/id_ed25519"))
    skip "needs age and an ed25519 key" unless enc.available? && key.exist?

    write_config("client_id" => "x", "ssh_key" => key.to_s)
    tenant = Health::Config::TENANTS["central"]
    enc.encrypt(JSON.generate("access_token" => "a", "tenant" => tenant),
      key, Health::Config.legacy_token_path)

    code, out, = capture { Health::CLI.run(["auth", "status"]) }

    assert_equal 0, code
    assert_match(/#{tenant}/, out)
    refute Health::Config.legacy_token_path.exist?
    assert Health::Config.token_path(tenant).exist?
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

class CookieJarTest < Minitest::Test
  def setup
    super
    @jar = Health::Portal::CookieJar.new
  end

  def absorb(*lines, at: "https://portal.healtheintent.com/")
    @jar.absorb(lines, URI(at))
  end

  def test_a_host_only_cookie_does_not_leak_to_siblings
    absorb("sid=1; Path=/", at: "https://a.example.com/")

    assert_equal "sid=1", @jar.header_for(URI("https://a.example.com/x"))
    assert_nil @jar.header_for(URI("https://b.example.com/x"))
    assert_nil @jar.header_for(URI("https://example.com/x"))
  end

  # The cookie that actually authorizes the record — `cloud-session` — is set on
  # `.healtheintent.com` and read from a subdomain, so this is the case the jar
  # exists for.
  def test_a_dotted_cookie_reaches_subdomains_and_the_domain_itself
    absorb("cloud-session=abc; Domain=.healtheintent.com; Path=/; Secure")

    assert_equal "cloud-session=abc", @jar.header_for(URI("https://uhs-pacentral.patientportal.healtheintent.com/x"))
    assert_equal "cloud-session=abc", @jar.header_for(URI("https://healtheintent.com/"))
    assert_nil @jar.header_for(URI("https://healtheintent.com.evil.test/"))
  end

  def test_a_secure_cookie_is_withheld_over_plain_http
    absorb("sid=1; Secure")

    assert_nil @jar.header_for(URI("http://portal.healtheintent.com/"))
    assert_equal "sid=1", @jar.header_for(URI("https://portal.healtheintent.com/"))
  end

  def test_path_scoped_cookies_only_match_below_their_path
    absorb("scoped=1; Path=/health-record")

    assert_equal "scoped=1", @jar.header_for(URI("https://portal.healtheintent.com/health-record/results"))
    assert_nil @jar.header_for(URI("https://portal.healtheintent.com/pages"))
  end

  def test_a_uri_without_a_path_is_treated_as_root
    absorb("sid=1")
    assert_equal "sid=1", @jar.header_for(URI("https://portal.healtheintent.com"))
  end

  def test_an_empty_value_expires_the_cookie
    absorb("bcs_token=one-time; Path=/")
    assert_equal "one-time", @jar["bcs_token"]

    absorb("bcs_token=; Path=/")
    assert_nil @jar["bcs_token"]
    assert_equal 0, @jar.size
  end

  def test_cookies_of_the_same_name_on_different_domains_coexist
    absorb("sid=portal", at: "https://portal.healtheintent.com/")
    absorb("sid=cerner", at: "https://cernerhealth.com/")

    assert_equal 2, @jar.size
    assert_equal "sid=portal", @jar.header_for(URI("https://portal.healtheintent.com/"))
    assert_equal "sid=cerner", @jar.header_for(URI("https://cernerhealth.com/"))
  end

  def test_a_repeated_cookie_replaces_the_earlier_value
    absorb("sid=1")
    absorb("sid=2")

    assert_equal 1, @jar.size
    assert_equal "2", @jar["sid"]
  end

  def test_nameless_and_absent_set_cookie_lines_are_ignored
    @jar.absorb(nil, URI("https://portal.healtheintent.com/"))
    absorb("=orphan; Path=/")

    assert_equal 0, @jar.size
  end

  def test_names_for_lists_what_would_be_sent
    absorb("a=1")
    absorb("b=2; Path=/deep")

    assert_equal %w[a], @jar.names_for(URI("https://portal.healtheintent.com/"))
    assert_equal %w[a b], @jar.names_for(URI("https://portal.healtheintent.com/deep/er")).sort
  end

  def test_lookup_by_name_ignores_domain
    absorb("cloud-session=abc; Domain=.healtheintent.com")
    assert_equal "abc", @jar["cloud-session"]
    assert_nil @jar["nope"]
  end
end

class FormTest < Minitest::Test
  Form = Health::Portal::Form

  def test_it_extracts_the_action_method_and_fields
    form = Form.all(<<~HTML).first
      <form method="POST" action="/login">
        <input type="hidden" name="csrfmiddlewaretoken" value="tok">
        <input type="text" name="login_username" value="">
        <input type="password" name="login_password">
      </form>
    HTML

    assert_equal "/login", form.action
    assert_equal "post", form.method
    assert_equal({ "csrfmiddlewaretoken" => "tok", "login_username" => "", "login_password" => "" }, form.fields)
  end

  def test_method_defaults_to_get
    assert_equal "get", Form.all('<form action="/x"><input name="q"></form>').first.method
  end

  def test_attributes_may_be_single_quoted_or_bare
    form = Form.all("<form action='/x' method=post><input name='a' value=1></form>").first

    assert_equal "/x", form.action
    assert_equal "post", form.method
    assert_equal({ "a" => "1" }, form.fields)
  end

  # SAML assertions are base64 inside an HTML attribute, so any `&` in the
  # surrounding markup arrives entity-encoded.
  def test_values_are_html_unescaped
    form = Form.all('<form><input name="RelayState" value="/a?b=1&amp;c=2"></form>').first
    assert_equal "/a?b=1&c=2", form.fields["RelayState"]
  end

  def test_unnamed_inputs_and_valueless_submits_are_dropped
    form = Form.all(<<~HTML).first
      <form>
        <input type="text">
        <input type="text" name="">
        <input type="submit">
        <input type="submit" name="go" value="Sign in">
        <button name="action" value="continue">Continue</button>
      </form>
    HTML

    assert_equal({ "go" => "Sign in", "action" => "continue" }, form.fields)
  end

  def test_it_finds_the_form_carrying_a_given_field
    html = <<~HTML
      <form action="/search"><input name="q"></form>
      <form action="/acs"><input name="SAMLResponse" value="abc"></form>
    HTML

    assert_equal "/acs", Form.with_field(html, "SAMLResponse").action
    assert_nil Form.with_field(html, "login_password")
    assert_nil Form.with_field(nil, "SAMLResponse")
  end

  def test_relative_actions_resolve_against_the_page
    page = URI("https://idp.example.com/auth/login?next=/x")

    assert_equal "https://idp.example.com/login", Form.all('<form action="/login"></form>').first.action_url(page)
    assert_equal "https://idp.example.com/auth/next", Form.all('<form action="next"></form>').first.action_url(page)
  end

  def test_an_empty_action_posts_back_to_the_page
    page = URI("https://idp.example.com/auth/login")
    assert_equal page.to_s, Form.all("<form></form>").first.action_url(page)
  end
end

class PortalClientTest < Minitest::Test
  def teardown
    @stub&.stop
    super
  end

  def serve(routes)
    @stub = StubHTTP.new(routes)
  end

  def client = @client ||= Health::Portal::Client.new

  def test_it_follows_redirects_and_reports_the_final_uri
    serve("GET /start" => [302, "", { "Location" => "/next" }],
      "GET /next" => [200, "arrived"])

    res = client.get("#{@stub.base}/start")

    assert_equal "arrived", res.body
    assert_equal "#{@stub.base}/next", res.uri.to_s
    assert_equal %w[/start /next], @stub.requests.map(&:path)
  end

  # A 302 out of a form POST continues as a GET with no body — the SAML
  # hand-off depends on it.
  def test_a_redirected_post_continues_as_a_get
    serve("POST /login" => [302, "", { "Location" => "/done" }],
      "GET /done" => [200, "ok"])

    client.post("#{@stub.base}/login", { "user" => "eric" })

    assert_equal %w[POST GET], @stub.requests.map(&:method)
    assert_equal "user=eric", @stub.requests.first.body
    assert_nil @stub.requests.last.body
  end

  def test_cookies_set_on_one_hop_are_sent_on_the_next
    serve("GET /a" => [302, "", { "Location" => "/b", "Set-Cookie" => ["one=1; Path=/", "two=2; Path=/"] }],
      "GET /b" => [200, "ok"])

    client.get("#{@stub.base}/a")

    assert_nil @stub.requests.first.headers["cookie"]
    assert_equal "one=1; two=2", @stub.requests.last.headers["cookie"]
    assert_equal "1", client.jar["one"]
  end

  def test_it_sends_the_requested_accept_and_extra_headers
    serve("GET /r" => [200, "{}"])

    client.get("#{@stub.base}/r", accept: "application/json", headers: { "Referer" => "https://example.test/" })
    req = @stub.requests.first

    assert_equal "application/json", req.headers["accept"]
    assert_equal "https://example.test/", req.headers["referer"]
    assert_match(/health-cli/, req.headers["user-agent"])
  end

  def test_a_redirect_loop_is_given_up_on
    serve("GET /loop" => [302, "", { "Location" => "/loop" }])

    err = assert_raises(Health::Portal::Client::Error) { client.get("#{@stub.base}/loop") }

    assert_match(/too many redirects/, err.message)
    assert_equal Health::Portal::Client::MAX_REDIRECTS, @stub.requests.size
  end

  def test_head_location_reads_the_location_without_chasing_it
    serve("GET /results/" => [302, "", { "Location" => "/person/abc/results/" }])

    assert_equal "/person/abc/results/", client.head_location("#{@stub.base}/results/")
    assert_equal 1, @stub.requests.size
  end

  def test_head_location_is_nil_when_there_is_no_redirect
    serve("GET /results/" => [200, "ok"])
    assert_nil client.head_location("#{@stub.base}/results/")
  end
end

class PortalCredentialsTest < Minitest::Test
  include XDGSandbox

  Credentials = Health::Portal::Credentials

  # PATH holds nothing but the fake `op`, so the script may only use builtins.
  def op_returning(json)
    "echo '#{json}'"
  end

  def both_fields
    JSON.generate([{ "label" => "username", "value" => "portal-user" },
      { "label" => "password", "value" => "hunter2" }])
  end

  def test_it_reads_the_username_and_password_in_one_op_call
    with_fake_op("#{op_returning(both_fields)}\necho \"$@\" > #{@tmp}/argv") do
      creds = Credentials.load

      assert_equal "portal-user", creds.username
      assert_equal "hunter2", creds.password
      argv = File.read("#{@tmp}/argv")
      assert_includes argv, Credentials::DEFAULT_ITEM
      assert_includes argv, "label=username,label=password"
    end
  end

  def test_the_item_and_vault_are_configurable
    cfg = config("portal" => { "op_item" => "Some Portal", "op_vault" => "Private" })

    with_fake_op("echo \"$@\" > #{@tmp}/argv\n#{op_returning(both_fields)}") do
      Credentials.load(cfg)
      argv = File.read("#{@tmp}/argv")

      assert_includes argv, "Some Portal"
      assert_includes argv, "Private"
    end
  end

  def test_a_single_field_response_is_still_accepted
    single = JSON.generate({ "label" => "username", "value" => "portal-user" })

    with_fake_op(op_returning(single)) do
      err = assert_raises(Credentials::Error) { Credentials.load }
      assert_match(/missing a username or password/, err.message)
    end
  end

  def test_a_failed_lookup_surfaces_the_op_error
    with_fake_op("echo 'item not found' >&2\nexit 1") do
      err = assert_raises(Credentials::Error) { Credentials.load }
      assert_match(/1Password lookup failed/, err.message)
      assert_match(/item not found/, err.message)
    end
  end

  def test_unparseable_output_is_reported_as_such
    with_fake_op("echo not-json") do
      err = assert_raises(Credentials::Error) { Credentials.load }
      assert_match(/unexpected response from `op`/, err.message)
    end
  end

  def test_a_missing_op_cli_is_reported_as_such
    with_fake_op(nil) do
      err = assert_raises(Credentials::Error) { Credentials.load }
      assert_match(/not installed/, err.message)
    end
  end

  # The password must not be reachable through the paths that end up in logs,
  # backtraces or a crash report.
  def test_the_password_never_appears_in_inspect_or_to_s
    creds = Credentials.new(username: "portal-user", password: "hunter2")

    refute_includes creds.inspect, "hunter2"
    refute_includes creds.to_s, "hunter2"
    refute_includes "#{creds}", "hunter2"
    assert_includes creds.inspect, "portal-user"
  end
end

class PortalLoginTest < Minitest::Test
  Login = Health::Portal::Login

  LOGIN_PAGE = <<~HTML.freeze
    <html><body>
      <form method="post" action="/login">
        <input type="hidden" name="csrfmiddlewaretoken" value="csrf-abc">
        <input type="text" name="login_username" value="">
        <input type="password" name="login_password" value="">
      </form>
    </body></html>
  HTML

  SAML_PAGE = <<~HTML.freeze
    <html><body onload="document.forms[0].submit()">
      <form method="post" action="/acs">
        <input type="hidden" name="SAMLResponse" value="PHNhbWw+">
        <input type="hidden" name="RelayState" value="/pages/health_record/results">
      </form>
    </body></html>
  HTML

  PERSON = "xB7PV5t92n45kL4".freeze

  def teardown
    @stub&.stop
    super
  end

  # The whole chain on loopback: entry page -> Django login form -> SAML
  # POST binding -> `cloud-session` -> the record host naming the person.
  def serve(overrides = {})
    routes = {
      "GET /pages/health_record/results" => [200, LOGIN_PAGE],
      "POST /login" => [200, SAML_PAGE],
      "POST /acs" => [200, "<html>signed in</html>",
        { "Set-Cookie" => "cloud-session=sess-xyz; Path=/; HttpOnly" }],
      "GET /health-record/results/" => [302, "", { "Location" => "/person/#{PERSON}/health-record/results/" }]
    }.merge(overrides)
    @stub = StubHTTP.new(routes)
  end

  def login(io: nil, **kwargs)
    Login.new(credentials: Health::Portal::Credentials.new(username: "portal-user", password: "hunter2"),
      io: io, entry: "#{@stub.base}/pages/health_record/results", record_host: @stub.base, **kwargs)
  end

  def test_it_walks_the_chain_and_returns_the_person_id
    serve
    session = login

    assert_equal PERSON, session.call
    assert_equal "sess-xyz", session.client.jar[Login::SESSION_COOKIE]
    assert_equal ["/pages/health_record/results", "/login", "/acs", "/health-record/results/"],
      @stub.requests.map(&:path)
  end

  def test_it_posts_the_credentials_along_with_the_form_state
    serve
    login.call
    posted = URI.decode_www_form(@stub.requests[1].body).to_h

    assert_equal "portal-user", posted["login_username"]
    assert_equal "hunter2", posted["login_password"]
    assert_equal "csrf-abc", posted["csrfmiddlewaretoken"]
    assert_match(%r{/pages/health_record/results\z}, @stub.requests[1].headers["referer"])
  end

  def test_it_relays_the_saml_assertion_untouched
    serve
    login.call
    posted = URI.decode_www_form(@stub.requests[2].body).to_h

    assert_equal "PHNhbWw+", posted["SAMLResponse"]
    assert_equal "/pages/health_record/results", posted["RelayState"]
    refute_includes posted.keys, "login_password"
  end

  def test_it_narrates_each_step_when_given_an_io
    serve
    io = StringIO.new
    login(io: io).call

    assert_match(/submitting credentials/, io.string)
    assert_match(/relaying SAML assertion/, io.string)
    refute_includes io.string, "hunter2"
  end

  def test_a_chain_that_never_issues_a_session_is_an_error
    serve("POST /acs" => [200, "<html>sorry</html>"])

    err = assert_raises(Login::Error) { login.call }
    assert_match(/no cloud-session cookie/, err.message)
  end

  def test_an_unresolvable_person_id_is_an_error
    serve("GET /health-record/results/" => [200, "<html>no redirect</html>"])

    err = assert_raises(Login::Error) { login.call }
    assert_match(/could not resolve the person id/, err.message)
  end

  # A page with neither form ends the walk, so an already-authenticated entry
  # needs no hops at all.
  def test_an_already_signed_in_entry_skips_straight_to_the_person_id
    serve("GET /pages/health_record/results" => [200, "<html>results</html>",
      { "Set-Cookie" => "cloud-session=already; Path=/" }])

    assert_equal PERSON, login.call
    assert_equal ["/pages/health_record/results", "/health-record/results/"], @stub.requests.map(&:path)
  end

  # If the provider ever loops the login form back at us, the walk has to stop
  # rather than spin.
  def test_a_login_form_that_never_advances_stops_after_max_steps
    serve("POST /login" => [200, LOGIN_PAGE])

    assert_raises(Login::Error) { login.call }
    assert_equal Login::MAX_STEPS + 1, @stub.requests.count { |r| r.path == "/login" || r.path.end_with?("results") }
  end
end

class PortalRecordTest < Minitest::Test
  include XDGSandbox

  Record = Health::Portal::Record

  def teardown
    @stub&.stop
    super
  end

  def record(routes)
    @stub = StubHTTP.new(routes)
    Record.new(client: Health::Portal::Client.new, person_id: "PERSON1", host: @stub.base)
  end

  def test_it_asks_for_json_and_parses_it
    payload = { "items" => [{ "name" => "CBC" }] }
    rec = record("GET /person/PERSON1/health-record/problems/" => [200, JSON.generate(payload)])

    assert_equal payload, rec.fetch("problems")
    assert_equal "application/json", @stub.requests.first.headers["accept"]
  end

  def test_results_are_windowed_with_us_formatted_dates
    rec = record("GET /person/PERSON1/health-record/results/" => [200, "{}"])
    rec.results(from: Date.new(2010, 1, 1), to: Date.new(2026, 5, 7))

    query = URI.decode_www_form(URI(@stub.requests.first.path).query).to_h
    assert_equal "01/01/2010", query["date_range_0"]
    assert_equal "05/07/2026", query["date_range_1"]
  end

  # The documents section answers HTML with a 500 on its JSON serializer; any
  # section behaving that way has to fail loudly rather than return nothing.
  def test_html_instead_of_json_is_an_error
    rec = record("GET /person/PERSON1/health-record/documents/" =>
      [200, "<html>list</html>", { "Content-Type" => "text/html" }])

    err = assert_raises(Record::Error) { rec.fetch("documents") }
    assert_match(/did not return documents as JSON/, err.message)
  end

  def test_a_server_error_is_reported_with_its_status_and_no_body
    rec = record("GET /person/PERSON1/health-record/results/" => [500, "stack trace with a name in it"])

    err = assert_raises(Record::Error) { rec.fetch("results") }
    assert_match(/HTTP 500/, err.message)
    refute_includes err.message, "stack trace"
  end

  def test_unparseable_json_is_an_error
    rec = record("GET /person/PERSON1/health-record/results/" => [200, "{not json"])

    err = assert_raises(Record::Error) { rec.fetch("results") }
    assert_match(/unreadable results data/, err.message)
  end

  def test_a_portal_failure_is_rescuable_as_one_kind
    rec = record("GET /person/PERSON1/health-record/results/" => [500, "x"])
    assert_raises(Health::Portal::Error) { rec.fetch("results") }
  end

  # Cheap enough to prove: the history endpoint is keyed by an id that exists
  # only in the HTML, so this is the one place the tool reads a rendered page.
  def test_history_index_comes_from_the_rendered_page
    rec = record("GET /person/PERSON1/health-record/results/" =>
      [200, PortalHistoryIndexTest::PAGE, { "Content-Type" => "text/html" }])

    index = rec.history_index(from: Date.new(2010, 1, 1), to: Date.new(2026, 5, 7))

    assert_equal %w[Hct Hgb], index.map(&:analyte)
    assert_equal "text/html", @stub.requests.first.headers["accept"]
    query = URI.decode_www_form(URI(@stub.requests.first.path).query).to_h
    assert_equal "01/01/2010", query["date_range_0"]
  end

  def test_a_page_that_will_not_render_is_an_error
    rec = record("GET /person/PERSON1/health-record/results/" => [500, "boom"])

    err = assert_raises(Record::Error) { rec.history_index(from: Date.today, to: Date.today) }
    assert_match(/HTTP 500/, err.message)
    refute_includes err.message, "boom"
  end

  # `page_size` is honoured up to somewhere between 100 and 500 and silently
  # reverts to 25 past that, so the cursor is followed rather than trusted to
  # one big request.
  def test_history_follows_the_cursor_until_a_short_page
    page1 = history_page(Record::PAGE_SIZE, key: "cursor1")
    page2 = history_page(3, key: "cursor2")
    calls = []
    rec = record("GET /person/PERSON1/health-record/results/history/" => lambda { |req|
      calls << URI.decode_www_form(URI(req.path).query).to_h
      [200, JSON.generate(calls.size == 1 ? page1 : page2)]
    })

    items = rec.history("UUID1")["items"]

    assert_equal Record::PAGE_SIZE + 3, items.size
    assert_equal 2, calls.size
    assert_equal ["UUID1"], calls.map { |c| c["name_and_type_uuid"] }.uniq
    assert_nil calls.first["page_key"]
    assert_equal %w[cursor1 next], calls.last.values_at("page_key", "dir")
  end

  # Both spellings of "there is no next page". Sending "None" back would ask
  # for the first page again, and keep asking.
  def test_history_stops_when_a_full_page_carries_no_cursor
    [nil, "None"].each do |key|
      page = history_page(Record::PAGE_SIZE, key: key)
      rec = record("GET /person/PERSON1/health-record/results/history/" => [200, JSON.generate(page)])

      assert_equal Record::PAGE_SIZE, rec.history("UUID1")["items"].size
      assert_equal 1, @stub.requests.size
      @stub.stop
    end
  end

  def history_page(count, key:)
    detail = key && "/x/?lab_ids=%5B1%5D&page_key=#{key}&dir=None"
    { "items" => Array.new(count) { |i| { "id" => i.to_s, "detailUrl" => detail } } }
  end

  def test_history_gives_up_rather_than_paging_forever
    page = history_page(Record::PAGE_SIZE, key: "same-cursor-every-time")
    rec = record("GET /person/PERSON1/health-record/results/history/" => [200, JSON.generate(page)])

    assert_equal Record::MAX_PAGES * Record::PAGE_SIZE, rec.history("UUID1")["items"].size
  end

  def test_open_signs_in_and_positions_on_the_person
    routes = {
      "GET /entry" => [200, "<html>results</html>", { "Set-Cookie" => "cloud-session=s; Path=/" }],
      "GET /health-record/results/" => [302, "", { "Location" => "/person/PERSON9/health-record/results/" }],
      "GET /person/PERSON9/health-record/problems/" => [200, '{"items":[]}']
    }
    @stub = StubHTTP.new(routes)
    json = JSON.generate([{ "label" => "username", "value" => "eric" },
      { "label" => "password", "value" => "pw" }])

    with_fake_op("echo '#{json}'") do
      # No cache exists in this sandbox, so this is the cold path: sign in,
      # then persist the session for the next command.
      rec = Record.open(config, entry: "#{@stub.base}/entry", record_host: @stub.base)

      assert_equal "PERSON9", rec.person_id
      assert_equal({ "items" => [] }, rec.fetch("problems"))
      assert Health::Portal::SessionStore.new(config).exist?
    end
  end
end

class PortalHistoryIndexTest < Minitest::Test
  HistoryIndex = Health::Portal::HistoryIndex

  # Trimmed from the real page, keeping the parts that matter: the panel
  # heading, the analyte name inside a <bdi>, the "learn more" link that sits
  # between them and carries no id, and the history link that carries one.
  PAGE = <<~HTML.freeze
    <div class="section">
      <h3 class="section-top consumer-card-header">CBC &amp; Diff (IQH)</h3>
      <ul class="labs-list">
        <li class="consumer-card-item">
          <div class="small-heading text-bold pad-bottom"><bdi dir="auto">Hct</bdi></div>
          <a href="/person/P1/health-content/?hc_id=deadbeef">Learn more about this</a>
          <div data-link="/person/P1/health-record/results/history/?name_and_type_uuid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&amp;page_size=25">
            <span class="x-small-heading"><bdi dir="auto"> 40.2 %</bdi></span>
            <a href="/person/P1/health-record/results/history/?name_and_type_uuid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&amp;page_size=25">View all for this result</a>
          </div>
        </li>
        <li class="consumer-card-item">
          <div class="small-heading text-bold pad-bottom"><bdi dir="auto">Hgb</bdi></div>
          <div data-link="/person/P1/health-record/results/history/?name_and_type_uuid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&amp;page_size=25"></div>
        </li>
      </ul>
    </div>
  HTML

  def test_it_pairs_each_analyte_with_the_id_its_history_is_filed_under
    entries = HistoryIndex.parse(PAGE)

    assert_equal %w[Hct Hgb], entries.map(&:analyte)
    assert_equal ["a" * 32, "b" * 32], entries.map(&:uuid)
    assert_equal ["CBC & Diff (IQH)"], entries.map(&:panel).uniq
  end

  # A card carries the same id on both its wrapper and its link. Counting both
  # would attribute the second one to whichever analyte came next.
  def test_only_the_first_id_after_a_name_belongs_to_it
    assert_equal 2, HistoryIndex.parse(PAGE).size
  end

  def test_ids_before_any_analyte_are_ignored
    assert_empty HistoryIndex.parse(%(<a href="?name_and_type_uuid=#{"c" * 32}">stray</a>))
  end

  def test_a_page_with_nothing_to_index_yields_nothing
    assert_empty HistoryIndex.parse("<html><body>no results</body></html>")
    assert_empty HistoryIndex.parse(nil)
  end
end

class PortalResultsTest < Minitest::Test
  Results = Health::Portal::Results

  def value(v, units: "ng/mL", modifier: nil)
    { "value" => v, "units" => units, "modifier" => modifier }
  end

  def payload(*results, panel: "Chemistry", type: "Vitamin D")
    { "items" => [{ "name" => panel, "resultTypes" => [{ "name" => type, "results" => results }] }] }
  end

  def result(**overrides)
    raw = {
      "name" => "Vit D 25 Hydroxy",
      "resultValues" => [value("24.6")],
      "referenceRanges" => { "normalLow" => value("30.0"), "normalHigh" => value("100.0") },
      "normalcy" => "Normal",
      "performedDateTime" => "2026-01-15T09:30:00Z"
    }.merge(overrides)
    Results.parse(payload(raw)).first
  end

  def test_it_flattens_panel_type_and_result_into_one_row
    r = result

    assert_equal "Chemistry", r.panel
    assert_equal "Vit D 25 Hydroxy", r.analyte
    assert_equal "24.6", r.value
    assert_equal "ng/mL", r.units
    assert_in_delta 24.6, r.number
    assert_equal "30.0 – 100.0", r.range
    assert_equal "2026-01-15", r.collected_on
  end

  # The reason this parser exists: the portal calls a vitamin D of 24.6 against
  # a 30.0–100.0 range "Normal".
  def test_normalcy_is_recomputed_rather_than_believed
    r = result

    assert_equal "Normal", r.reported_normalcy
    assert_equal :low, r.status
    assert r.abnormal?
    assert_equal "LOW", r.flag
  end

  def test_a_value_above_the_range_is_high
    r = result("resultValues" => [value("38.4", units: "%")],
      "referenceRanges" => { "normalLow" => value("27.0"), "normalHigh" => value("37.0") })

    assert_equal :high, r.status
    assert_equal "HIGH", r.flag
  end

  def test_a_value_inside_the_range_is_normal
    r = result("resultValues" => [value("55.0")])

    assert_equal :normal, r.status
    refute r.abnormal?
    assert_equal "", r.flag
  end

  # Bounds are inclusive: a hematocrit of exactly 42.0 against 42.0–53.0 is
  # not abnormal.
  def test_the_bounds_themselves_are_in_range
    assert_equal :normal, result("resultValues" => [value("30.0")]).status
    assert_equal :normal, result("resultValues" => [value("100.0")]).status
  end

  def test_a_one_sided_range_only_constrains_that_side
    low_only = result("referenceRanges" => { "normalLow" => value("30.0") })
    high_only = result("referenceRanges" => { "normalHigh" => value("100.0") })

    assert_equal "> 30.0", low_only.range
    assert_equal :low, low_only.status
    assert_equal "< 100.0", high_only.range
    assert_equal :normal, high_only.status
  end

  # A one-sided bound that already reads as an inequality keeps its own
  # operator rather than acquiring a second.
  def test_a_range_modifier_is_not_doubled_up
    r = result("referenceRanges" => { "normalHigh" => value("5.7", modifier: "<") })

    assert_equal "< 5.7", r.range
    assert_equal :high, r.status
  end

  def test_a_qualitative_result_is_undecidable_rather_than_normal
    r = result("resultValues" => [value("NEGATIVE", units: nil)], "referenceRanges" => {})

    assert_equal "NEGATIVE", r.value
    assert_nil r.number
    assert_nil r.range
    assert_equal :unknown, r.status
    refute r.abnormal?
    assert_equal "", r.flag
  end

  def test_a_value_past_a_critical_bound_is_marked_as_such
    ranges = { "normalLow" => value("3.5"), "normalHigh" => value("5.1"),
               "criticalLow" => value("2.5"), "criticalHigh" => value("6.5") }
    low = result("resultValues" => [value("2.1")], "referenceRanges" => ranges)
    high = result("resultValues" => [value("6.9")], "referenceRanges" => ranges)
    merely_low = result("resultValues" => [value("3.0")], "referenceRanges" => ranges)

    assert low.critical?
    assert_equal "CRITICAL LOW", low.flag
    assert high.critical?
    assert_equal "CRITICAL HIGH", high.flag
    refute merely_low.critical?
    assert_equal "LOW", merely_low.flag
  end

  # Critical bounds are present on nearly every result but almost always null.
  def test_absent_critical_bounds_are_not_a_bound
    r = result("referenceRanges" => { "normalLow" => value("30.0"),
                                      "criticalLow" => value(nil), "criticalHigh" => value(nil) })

    assert_nil r.critical_low
    refute r.critical?
    assert_equal "LOW", r.flag
  end

  def test_a_result_type_with_earlier_values_is_marked_truncated
    payload = { "items" => [{ "name" => "CBC", "resultTypes" => [
      { "name" => "Hct", "hasMore" => true, "results" => [{ "name" => "Hct", "resultValues" => [value("40.2")] }] },
      { "name" => "MPV", "results" => [{ "name" => "MPV", "resultValues" => [value("8.9")] }] }
    ] }] }
    hct, mpv = Results.parse(payload)

    assert hct.truncated
    refute mpv.truncated
  end

  def test_a_numeric_result_with_no_range_is_undecidable
    assert_equal :unknown, result("referenceRanges" => nil).status
  end

  def test_thousands_separators_are_understood
    r = result("resultValues" => [value("1,240")], "referenceRanges" => { "normalHigh" => value("1000") })

    assert_in_delta 1240.0, r.number
    assert_equal :high, r.status
  end

  # A result reporting several values at once has no single number to compare.
  def test_multiple_values_are_joined_and_left_undecided
    r = result("resultValues" => [value("120", units: "mmHg"), value("80", units: "mmHg")])

    assert_equal "120, 80", r.value
    assert_equal "mmHg", r.units
    assert_nil r.number
    assert_equal :unknown, r.status
  end

  def test_a_modifier_on_the_value_is_shown
    assert_equal "< 5", result("resultValues" => [value("5", modifier: "<")]).value
  end

  def test_an_unnamed_result_borrows_its_type_name
    assert_equal "Vitamin D", result("name" => nil).analyte
    assert_equal "Vitamin D", result("name" => "").analyte
  end

  def test_empty_and_missing_values_are_dropped
    r = result("resultValues" => [value(""), value(nil), "not a hash"])

    assert_equal "", r.value
    assert_nil r.units
    assert_equal :unknown, r.status
  end

  def test_a_payload_with_nothing_in_it_yields_nothing
    assert_empty Results.parse(nil)
    assert_empty Results.parse({})
    assert_empty Results.parse({ "items" => nil })
    assert_empty Results.parse({ "items" => [{ "name" => "Empty panel" }] })
    assert_empty Results.parse({ "items" => [{ "resultTypes" => [{ "name" => "t" }] }] })
  end

  # The history endpoint answers flat — one analyte, every draw, no panel
  # wrapper and no `hasMore`, since this is what `hasMore` was pointing at.
  def test_history_is_read_from_a_flat_payload
    payload = { "items" => [
      { "name" => "Hct", "type" => "Hct", "resultValues" => [value("40.2", units: "%")],
        "referenceRanges" => { "normalLow" => value("42.0"), "normalHigh" => value("53.0") },
        "performedDateTime" => "2026-01-15T15:53:00Z" },
      { "name" => "Hct", "type" => "Hct", "resultValues" => [value("44.1", units: "%")],
        "referenceRanges" => { "normalLow" => value("42.0"), "normalHigh" => value("53.0") },
        "performedDateTime" => "2025-06-10T15:00:00Z" }
    ] }

    rows = Results.parse_history(payload, panel: "CBC (IQH)")

    assert_equal %w[2026-01-15 2025-06-10], rows.map(&:collected_on)
    assert_equal ["CBC (IQH)"], rows.map(&:panel).uniq
    assert_equal [:low, :normal], rows.map(&:status)
    # Nothing is held back here, so nothing is disclosed as held back.
    refute rows.any?(&:truncated)
  end

  # Same fallback as the grouped payload: an unnamed row takes the type's name.
  def test_a_history_row_without_a_name_falls_back_to_its_type
    payload = { "items" => [{ "type" => "Hct", "resultValues" => [value("40.2")] }] }

    assert_equal "Hct", Results.parse_history(payload).first.analyte
  end

  def test_an_empty_history_yields_nothing
    assert_empty Results.parse_history({ "items" => [] })
    assert_empty Results.parse_history(nil)
  end
end

class LabsCommandTest < Minitest::Test
  include XDGSandbox

# Shaped like the real payload: the latest value per analyte, analytes last
# drawn on different dates, one vitals panel, and a `hasMore` marking an
# analyte with earlier values the results section does not return.
PAYLOAD = {
  "items" => [
    { "name" => "CBC (IQH)",
      "resultTypes" => [
        { "name" => "Hct", "hasMore" => true, "results" => [
          { "name" => "Hct", "resultValues" => [{ "value" => "40.2", "units" => "%" }],
            "referenceRanges" => { "normalLow" => { "value" => "42.0" }, "normalHigh" => { "value" => "53.0" } },
            "normalcy" => "Normal", "performedDateTime" => "2026-01-15T15:53:00Z" }
        ] },
        { "name" => "Potassium", "results" => [
          { "name" => "Potassium", "resultValues" => [{ "value" => "6.9", "units" => "mmol/L" }],
            "referenceRanges" => { "normalLow" => { "value" => "3.5" }, "normalHigh" => { "value" => "5.1" },
                                   "criticalHigh" => { "value" => "6.5" }, "criticalLow" => { "value" => nil } },
            "normalcy" => "Abnormal", "performedDateTime" => "2026-01-15T15:53:00Z" }
        ] }
      ] },
    { "name" => "Chemistry",
      "resultTypes" => [{ "name" => "Glucose", "results" => [
        { "name" => "Glucose", "resultValues" => [{ "value" => "92", "units" => "mg/dL" }],
          "referenceRanges" => { "normalLow" => { "value" => "70" }, "normalHigh" => { "value" => "99" } },
          "normalcy" => "Normal", "performedDateTime" => "2024-01-15T14:00:00Z" }
      ] }] },
    { "name" => "Vital Signs (IQH)",
      "resultTypes" => [{ "name" => "Systolic Blood Pressure", "results" => [
        { "name" => "Systolic Blood Pressure", "resultValues" => [{ "value" => "130", "units" => "mmHg" }],
          "referenceRanges" => { "normalLow" => { "value" => "90" }, "normalHigh" => { "value" => "120" } },
          "normalcy" => "Normal", "performedDateTime" => "2026-07-29T09:00:00Z" }
      ] }] }
  ]
}.freeze

# One analyte over time, as the history endpoint serves it: flat, newest
# first, no panel wrapper.
HISTORY = {
  "items" => [
    { "name" => "Hct", "type" => "Hct", "resultValues" => [{ "value" => "40.2", "units" => "%" }],
      "referenceRanges" => { "normalLow" => { "value" => "42.0" }, "normalHigh" => { "value" => "53.0" } },
      "performedDateTime" => "2026-01-15T15:53:00Z" },
    { "name" => "Hct", "type" => "Hct", "resultValues" => [{ "value" => "44.1", "units" => "%" }],
      "referenceRanges" => { "normalLow" => { "value" => "42.0" }, "normalHigh" => { "value" => "53.0" } },
      "performedDateTime" => "2025-06-10T15:00:00Z" },
    { "name" => "Hct", "type" => "Hct", "resultValues" => [{ "value" => "38.4", "units" => "%" }],
      "referenceRanges" => { "normalLow" => { "value" => "42.0" }, "normalHigh" => { "value" => "53.0" } },
      "performedDateTime" => "2018-09-12T15:00:00Z" }
  ]
}.freeze

Entry = Health::Portal::HistoryIndex::Entry

INDEX = [
  Entry.new(panel: "CBC (IQH)", analyte: "Hct", uuid: "u-hct"),
  Entry.new(panel: "CBC (IQH)", analyte: "Hgb", uuid: "u-hgb"),
  Entry.new(panel: "Chemistry", analyte: "Hgb A1c", uuid: "u-a1c"),
  Entry.new(panel: "Chemistry", analyte: "Glucose Level", uuid: "u-glu"),
  Entry.new(panel: "Vital Signs (IQH)", analyte: "Glucose Level", uuid: "u-glu2")
].freeze

# Stands in for a signed-in Portal::Record without reaching the network.
class FakeRecord
  attr_reader :window, :asked_for

  def initialize(payload, history: HISTORY, index: INDEX)
    @payload = payload
    @history = history
    @index = index
  end

  def results(from:, to:)
    @window = [from, to]
    @payload
  end

  def history_index(from:, to:)
    @window = [from, to]
    @index
  end

  def history(uuid)
    @asked_for = uuid
    @history
  end
end

def run_labs(argv, payload: PAYLOAD, json: false, quiet: false)
  @record = FakeRecord.new(payload)
  global = Health::GlobalOptions.new(json: json, quiet: quiet, verbose: false)
  io = StringIO.new
  err = StringIO.new
  cmd = Health::Commands::Labs.new(global, io: io, err: err,
    record_factory: ->(_config, _log) { @record })
  [cmd.run(argv), io.string, err.string]
end

def setup
  super
  write_config("client_id" => "x")
end

# The portal's results section answers with the latest value per analyte,
# so the default view is every analyte, each carrying its own date.
def test_it_shows_every_analyte_with_the_date_it_was_drawn
  code, out = run_labs([])

  assert_equal 0, code
  assert_includes out, "CBC (IQH)"
  assert_includes out, "2026-01-15"
  assert_includes out, "2024-01-15"
  assert_equal [Health::Commands::Labs::EARLIEST, Date.today], @record.window
end

def test_it_groups_by_panel_in_a_stable_order
  _code, out = run_labs([])
  panels = out.lines.reject { |l| l.start_with?("  ") }.map(&:strip).reject(&:empty?)

  assert_equal ["CBC (IQH)", "Chemistry", "Vital Signs (IQH)"], panels
end

def test_it_flags_what_the_portal_calls_normal
  _code, out = run_labs([])

  assert_match(/Hct\s+40\.2\s+%\s+42\.0 – 53\.0\s+LOW\s+2026-01-15/, out)
  assert_match(/Glucose\s+92\s+mg\/dL\s+70 – 99\s+2024-01-15/, out)
end

# Past a critical bound has to read differently from merely out of range.
def test_a_critical_value_says_so
  _code, out = run_labs([])
  assert_match(/Potassium\s+6\.9\s+mmol\/L\s+3\.5 – 5\.1\s+CRITICAL HIGH/, out)
end

def test_a_window_is_passed_to_the_portal_and_applied_again_locally
  _code, out = run_labs(["--since", "2026-01-01", "--until", "2026-06-30"])

  assert_equal [Date.new(2026, 1, 1), Date.new(2026, 6, 30)], @record.window
  assert_includes out, "Hct"
  # Outside the window on both sides, and dropped even though the stub
  # returned them — the portal's filtering is not taken on trust.
  refute_includes out, "Glucose"
  refute_includes out, "Systolic"
end

def test_panel_filters_by_name_case_insensitively
  _code, out = run_labs(["--panel", "chem"])

  assert_includes out, "Glucose"
  refute_includes out, "Hct"
end

def test_vitals_can_be_isolated_or_excluded
  _code, only = run_labs(["--vitals"])
  _code, without = run_labs(["--no-vitals"])

  assert_includes only, "Systolic"
  refute_includes only, "Hct"
  assert_includes without, "Hct"
  refute_includes without, "Systolic"
end

def test_abnormal_keeps_only_out_of_range_results
  _code, out = run_labs(["--abnormal"])

  assert_includes out, "Hct"
  assert_includes out, "Potassium"
  refute_includes out, "Glucose"
end

def test_the_summary_counts_recomputed_flags_and_goes_to_stderr
  _code, out, err = run_labs([])

  assert_match(/4 results, 3 outside the stated reference range \(recomputed\)/, err)
  refute_includes out, "outside the stated"
end

# Silently showing one hematocrit when a decade of them exists would be the
# tool lying by omission.
def test_truncated_history_is_disclosed
  _code, _out, err = run_labs([])
  assert_match(/1 of them have earlier values on record/, err)
end

def test_nothing_is_said_about_truncation_when_there_is_none
  _code, _out, err = run_labs(["--panel", "chem"])
  refute_match(/earlier values/, err)
end

def test_quiet_drops_the_summary
  _code, _out, err = run_labs([], quiet: true)
  assert_empty err
end

def test_json_emits_every_field_including_the_computed_status
  code, out, err = run_labs(["--panel", "cbc"], json: true)
  rows = JSON.parse(out)

  assert_equal 0, code
  assert_equal %w[Hct Potassium], rows.map { |r| r["analyte"] }
  hct, potassium = rows

  assert_equal "low", hct["status"]
  assert_equal "Normal", hct["reported_normalcy"]
  refute hct["critical"]
  assert hct["truncated"]
  assert_equal "high", potassium["status"]
  assert potassium["critical"]
  # stdout stays parseable: nothing but JSON.
  assert_empty err
end

def test_nothing_matching_is_reported_without_failing
  code, out, err = run_labs(["--panel", "nope"])

  assert_equal 0, code
  assert_empty out
  assert_match(/no results matched/, err)
end

def test_nothing_matching_is_an_empty_json_array
  code, out = run_labs(["--panel", "nope"], json: true)

  assert_equal 0, code
  assert_equal [], JSON.parse(out)
end

def test_an_empty_record_does_not_blow_up
  code, _out, err = run_labs([], payload: { "items" => [] })

  assert_equal 0, code
  assert_match(/no results matched/, err)
end

def test_unknown_options_and_missing_values_are_usage_errors
  assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--nope"]) }
  assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--panel"]) }
  assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--since"]) }
end

def test_a_malformed_date_is_a_usage_error
  err = assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--since", "May 7"]) }
  assert_match(/YYYY-MM-DD/, err.message)
end

  # --history answers a different question from the default listing — every
  # draw of one analyte, rather than the latest of each.
  def test_history_shows_every_draw_newest_first
    _code, out, err = run_labs(["--history", "Hct"])

    assert_equal "u-hct", @record.asked_for
    assert_equal %w[2026-01-15 2025-06-10 2018-09-12], out.scan(/\d{4}-\d\d-\d\d/)
    assert_match(/3 draws, 2 outside the stated reference range/, err)
  end

  # The heading already says which analyte this is, so repeating it on every
  # row would be noise; the date takes that column instead.
  def test_a_history_is_headed_by_its_analyte_and_led_by_the_date
    _code, out = run_labs(["--history", "Hct"])

    assert_includes out, "CBC (IQH) — Hct"
    assert_match(/^  2026-01-15\s+40\.2\s+%\s+42\.0 – 53\.0\s+LOW$/, out)
  end

  # "Hgb" is also a prefix of "Hgb A1c". An exact name has to win outright or
  # the common case is unusable.
  def test_an_exact_analyte_name_beats_a_longer_one_containing_it
    run_labs(["--history", "hgb"])
    assert_equal "u-hgb", @record.asked_for
  end

  def test_a_partial_analyte_name_still_resolves
    run_labs(["--history", "a1c"])
    assert_equal "u-a1c", @record.asked_for
  end

  # The same analyte name appears under more than one panel with a different
  # id behind each, so guessing would silently answer the wrong question.
  def test_an_ambiguous_analyte_is_a_usage_error_naming_the_candidates
    err = assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--history", "glucose"]) }

    assert_match(/matches several analytes/, err.message)
    assert_match(/Glucose Level/, err.message)
  end

  def test_panel_disambiguates_a_repeated_analyte_name
    run_labs(["--history", "glucose", "--panel", "chemistry"])
    assert_equal "u-glu", @record.asked_for
  end

  def test_an_unknown_analyte_is_a_usage_error
    err = assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--history", "zzz"]) }
    assert_match(/no analyte matching "zzz"/, err.message)
  end

  def test_history_still_honours_a_window_and_the_abnormal_filter
    _code, out = run_labs(["--history", "Hct", "--since", "2020-01-01", "--abnormal"])

    assert_includes out, "2026-01-15"
    # In range, so dropped by --abnormal.
    refute_includes out, "2025-06-10"
    # Before --since, so dropped by the window.
    refute_includes out, "2018-09-12"
  end

  def test_history_as_json_is_a_flat_list_of_draws
    _code, out = run_labs(["--history", "Hct"], json: true)
    rows = JSON.parse(out)

    assert_equal %w[Hct Hct Hct], rows.map { |r| r["analyte"] }
    assert_equal ["CBC (IQH)"], rows.map { |r| r["panel"] }.uniq
    refute rows.any? { |r| r["truncated"] }
  end

  def test_the_truncation_notice_points_at_the_flag_that_resolves_it
    _code, _out, err = run_labs([])
    assert_match(/health labs --history <analyte>/, err)
  end

  def test_history_needs_a_value
    assert_raises(Health::Commands::Args::BadArgument) { run_labs(["--history"]) }
  end

  # This one builds the real record factory, so `op` has to be taken off PATH
  # first: with a live 1Password session available it would otherwise sign in
  # to the portal for real and pull actual results into the test run.
  def test_the_cli_routes_labs_and_reports_portal_failures_as_exit_one
    code, out, err = with_fake_op(nil) { capture { Health::CLI.run(["labs"]) } }

    assert_equal 1, code
    assert_empty out
    # A missing `op` is a Portal::Error, which is the path that proves the
    # portal's errors reach the CLI's rescue rather than escaping as a crash.
    assert_match(/health: portal sign-in needs the `op` CLI/, err)
  end

  def test_labs_appears_in_the_help
    _code, out, = capture { Health::CLI.run(["help"]) }

    assert_includes out, "labs"
    assert_includes out, "--abnormal"
  end
end

class PortalSessionStoreTest < Minitest::Test
  include XDGSandbox

  SessionStore = Health::Portal::SessionStore

  # A stand-in for `age`, so the store's own logic is what's under test rather
  # than the encryption already covered elsewhere.
  class PlainEncryption
    def encrypt(content, _key, path)
      File.write(path, content)
      path
    end

    def decrypt(path, _key) = File.exist?(path) ? File.read(path) : nil
  end

  def store(encryption: PlainEncryption.new)
    SessionStore.new(config, encryption: encryption)
  end

  def jar_with(*lines, at: "https://uhs-pacentral.patientportal.healtheintent.com/")
    Health::Portal::CookieJar.new.absorb(lines, URI(at))
  end

  def test_a_saved_session_round_trips
    jar = jar_with("cloud-session=abc; Domain=.healtheintent.com; Path=/; Secure",
      "iqh=xyz; Path=/")
    store.save(jar: jar, person_id: "PERSON1")
    saved = store.load

    assert_equal "PERSON1", saved[:person_id]
    assert_equal "abc", saved[:jar]["cloud-session"]
    # Domain semantics have to survive the trip, or the restored cookie stops
    # reaching the host the record is served from.
    assert_equal "cloud-session=abc; iqh=xyz",
      saved[:jar].header_for(URI("https://uhs-pacentral.patientportal.healtheintent.com/x"))
    assert_nil saved[:jar].header_for(URI("https://elsewhere.test/x"))
  end

  def test_nothing_saved_yet_is_simply_nothing
    refute store.exist?
    assert_nil store.load
  end

  # A bad cache means signing in again, which the caller can do — so it must
  # not turn into an exception on the way to a lab result.
  def test_an_unreadable_cache_is_treated_as_absent
    store.save(jar: jar_with("cloud-session=abc"), person_id: "PERSON1")
    File.write(store.path, "{ not json")

    assert_nil store.load
  end

  def test_a_cache_without_a_person_is_treated_as_absent
    File.write(store.path, JSON.generate("cookies" => []))
    assert_nil store.load
  end

  def test_a_failed_decrypt_is_treated_as_absent
    failing = Class.new do
      def decrypt(*) = raise(Health::Encryption::Error, "age decrypt failed")
    end.new
    File.write(SessionStore.new(config).path, "whatever")

    assert_nil store(encryption: failing).load
  end

  def test_rows_that_are_not_cookies_are_skipped
    File.write(store.path, JSON.generate(
      "person_id" => "PERSON1",
      "cookies" => ["not a hash", {}, { "name" => "", "value" => "x" },
        { "name" => "ok", "value" => "1", "domain" => "a.test", "path" => "/",
          "secure" => false, "host_only" => true, "unexpected" => "ignored" }]
    ))

    assert_equal "1", store.load[:jar]["ok"]
  end

  def test_clearing_removes_the_file_and_is_safe_to_repeat
    store.save(jar: jar_with("cloud-session=abc"), person_id: "PERSON1")
    assert store.exist?

    assert store.clear
    refute store.exist?
    assert store.clear
  end
end

class PortalRecordSessionTest < Minitest::Test
  include XDGSandbox

  Record = Health::Portal::Record

  def teardown
    @stub&.stop
    super
  end

  # A store that keeps the session in memory, so these tests exercise the
  # reuse decision rather than the file format.
  class MemoryStore
    attr_reader :saved

    def initialize(seed = nil) = @saved = seed

    def load = @saved
    def save(jar:, person_id:) = @saved = { person_id: person_id, jar: jar }
  end

  LOGIN_ROUTES = {
    "GET /entry" => [200, "<html>results</html>", { "Set-Cookie" => "cloud-session=fresh; Path=/" }],
    "GET /health-record/results/" => [302, "", { "Location" => "/person/PERSON9/health-record/results/" }]
  }.freeze

  def serve(overrides = {})
    @stub = StubHTTP.new(LOGIN_ROUTES.merge(overrides))
  end

  def open_record(store)
    Record.open(nil, store: store, entry: "#{@stub.base}/entry", record_host: @stub.base)
  end

  def with_op(&block)
    json = JSON.generate([{ "label" => "username", "value" => "eric" },
      { "label" => "password", "value" => "pw" }])
    with_fake_op("echo '#{json}'", &block)
  end

  def test_a_live_cached_session_skips_both_op_and_the_sign_in_chain
    serve
    jar = Health::Portal::CookieJar.new.absorb(["cloud-session=cached; Path=/"], URI(@stub.base))
    store = MemoryStore.new({ person_id: "PERSON9", jar: jar })

    # No fake `op` on PATH: reaching 1Password at all would raise here.
    record = with_fake_op(nil) { open_record(store) }

    assert_equal "PERSON9", record.person_id
    assert_equal ["/health-record/results/"], @stub.requests.map(&:path)
    assert_equal "cloud-session=cached", @stub.requests.first.headers["cookie"]
  end

  def test_a_fresh_sign_in_is_cached_for_next_time
    serve
    store = MemoryStore.new

    with_op { open_record(store) }

    assert_equal "PERSON9", store.saved[:person_id]
    assert_equal "fresh", store.saved[:jar]["cloud-session"]
  end

  def test_an_expired_session_falls_back_to_signing_in_again
    # Signed out, the record host sends you to the identity provider rather
    # than to a person.
    serve("GET /health-record/results/" => lambda { |req|
      req.headers["cookie"].to_s.include?("stale") ?
        [302, "", { "Location" => "https://idp.test/login" }] :
        [302, "", { "Location" => "/person/PERSON9/health-record/results/" }]
    })
    jar = Health::Portal::CookieJar.new.absorb(["cloud-session=stale; Path=/"], URI(@stub.base))
    store = MemoryStore.new({ person_id: "PERSON9", jar: jar })
    io = StringIO.new

    record = with_op { Record.open(nil, io: io, store: store, entry: "#{@stub.base}/entry", record_host: @stub.base) }

    assert_equal "PERSON9", record.person_id
    assert_match(/cached session has expired/, io.string)
    assert_equal "fresh", store.saved[:jar]["cloud-session"]
  end

  def test_a_cached_session_for_a_different_person_is_not_trusted
    serve
    jar = Health::Portal::CookieJar.new.absorb(["cloud-session=cached; Path=/"], URI(@stub.base))
    store = MemoryStore.new({ person_id: "SOMEONE-ELSE", jar: jar })

    record = with_op { open_record(store) }

    assert_equal "PERSON9", record.person_id
  end

  def test_auth_logout_removes_the_cached_portal_session
    write_config("client_id" => "x")
    cache = Health::Portal::SessionStore.new(config)
    cache.path.write("encrypted")

    code, out, = capture { Health::CLI.run(["auth", "logout"]) }

    assert_equal 0, code
    assert_match(/Cached portal session removed/, out)
    refute cache.exist?
  end
end
