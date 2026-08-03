# health-cli

A headless CLI for my own medical records, over SMART on FHIR against Oracle
Health (Cerner). Pure Ruby stdlib — no gems at runtime.

**Status: auth spike.** Only `auth` and `config` exist. The point of this stage
is to prove a real token against the real tenant before any resource commands
get written.

## Install

```sh
brew install age                 # for the encrypted token store
ln -s "$PWD/bin/health" ~/bin/health
health config init <client_id>
```

The client ID lives in 1Password (`health-cli`). Either paste it into the config
or reference it so it never lands on disk:

```json
{ "client_id": "op://Personal/health-cli/client id" }
```

Any config value starting with `op://` is resolved through the `op` CLI at use
time.

## Usage

```sh
health auth login          # browser sign-in, standalone patient launch
health auth status         # is there a usable token? (never prints one)
health auth refresh        # force a refresh
health auth logout         # delete the encrypted token store

health config show         # prints the file as written — op:// stays a reference
health config edit
```

`--json` on any command swaps formatted output for JSON. `--tenant <name>`
overrides the tenant for a single `auth` invocation.

## How the login works

Standalone patient launch, authorization-code grant, public client:

1. `GET {fhir_base}/.well-known/smart-configuration` for the authorize and token
   endpoints. Cached for a day under `~/.local/share/health/cache/`.
2. Bind `127.0.0.1:8412`, open the browser at the authorize endpoint with
   `aud` set to the FHIR base.
3. Sign in to Cerner Health. The redirect lands on the loopback listener, which
   checks `state` and hands back the code.
4. `POST` the code to the token endpoint with `client_id` in the body and no
   client authentication.

The listener 404s anything that isn't exactly the registered redirect path, so a
favicon request doesn't abort a login in progress. It refuses a redirect whose
`state` doesn't match, rather than exchanging a code it didn't ask for.

## Things that are non-obvious

**PKCE.** None of the three UHS tenants advertise
`code_challenge_methods_supported` in their SMART configuration — the sandbox
and other production tenants do. We send `S256` anyway (unknown authorize
parameters are ignored per RFC 6749, and it's real protection on a loopback
redirect), with `"pkce": false` in the config as the escape hatch if a tenant
turns out to reject it.

**SMART v1 scopes, not v2.** `patient/Observation.read`, not
`patient/Observation.rs`. v2 scopes make PKCE mandatory, which the UHS tenants
don't advertise support for. Not worth the risk until a real login has proven
otherwise.

**Refresh tokens don't rotate.** A Cerner refresh response contains no
`refresh_token` field at all. Storing the response as-is would destroy the only
long-lived credential we have; `TokenStore#merge_response` carries the prior one
forward. Access tokens live 570 seconds, so this path runs constantly.

**Requested scopes are a subset of registered ones.** The Oracle console
force-enables `launch` and `profile`. `launch` is an EHR-launch scope and
`profile` is a deprecated alias for `fhirUser`; asking for either in a standalone
flow is noise, so `Config::DEFAULT_SCOPES` omits them.

**Tenant.** `central` (UHS_Ambulatory_Central) is the default, inferred from the
patient portal redirecting through `asp-central.uhs.patientportal.us-1.healtheintent.com`.
All six UHS orgs share one corporate address, so geography proves nothing —
`--tenant west` / `--tenant east` are there as cheap fallbacks if `central` is
wrong.

**Public client.** Every tenant advertises `client-public` yet omits `none` from
`token_endpoint_auth_methods_supported`. The console issued no secret, so we send
none and let the server object if it disagrees.

## Files

| Path | What |
| --- | --- |
| `~/.config/health/config.json` | client id, tenant, redirect URI, scopes |
| `~/.local/share/health/tokens.age` | tokens, age-encrypted to an SSH key, mode 0600 |
| `~/.local/share/health/cache/` | SMART discovery documents |

Tokens are encrypted to an SSH *key* rather than a passphrase, which is what
keeps the tool non-interactive: a read needs the private key on disk, not a
prompt.

Nothing here ever writes a token to a log, an error message, or stdout.
`auth status` reports presence booleans, a scope count, and an expiry — never a
value, not even a prefix.

## Tests

```sh
ruby test/cli_test.rb
```

No network. The OAuth token and discovery paths run against a real loopback HTTP
server rather than a mock, and `auth login` is covered end to end by overriding
the one method that would open a browser. 100% line coverage is enforced; the
two genuinely untestable branches (launching Safari, a browser resetting the
connection mid-write) are marked `:nocov:`.
