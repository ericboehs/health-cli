# health-cli

A headless CLI for my own medical records, against Oracle Health (Cerner) — SMART
on FHIR where that works, the patient portal where it doesn't. Pure Ruby stdlib
— no gems at runtime.

**Status: the record reads.** `health labs` returns real values with real
reference ranges — it does not use FHIR to do it, see *Two backends*, below.
Everything else (`meds`, `problems`, `allergies`, `shots`, `docs`) comes from
FHIR, where those resources are fully populated even though the lab values
aren't.

```
$ health labs --no-vitals
CBC
  Hematocrit     40.2  %      42.0 – 53.0  LOW   2026-01-15
  Hemoglobin     14.1  g/dL   13.0 – 17.0        2026-01-15
  Platelets       231  K/uL   150 – 400          2026-01-15

Lipid Panel
  HDL              52  mg/dL  40 – 60            2026-01-15
  Triglycerides   168  mg/dL  10 – 150     HIGH  2026-01-15

5 results, 2 outside the stated reference range (recomputed).
1 of them has earlier values on record; see `health labs --history <analyte>`.
```

The flags are computed here, not reported — the portal labels every result in
the record "Normal", including the two above. And because the results endpoint
only ever returns the latest value per analyte, `--history` goes and gets the
rest:

```
$ health labs --history Hematocrit
CBC — Hematocrit
  2026-01-15  40.2  %  42.0 – 53.0  LOW
  2025-11-14  43.6  %  42.0 – 53.0
  2025-04-02  41.8  %  42.0 – 53.0  LOW

3 draws, 2 outside the stated reference range (recomputed).
```

(Values throughout this README are illustrative, not mine.)

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

`health labs` needs portal credentials too, and those are read straight from
1Password rather than the config — there is no token to cache, so a username and
password are genuinely required per run. By default it reads the `username` and
`password` fields of an item called `cernerhealth.com` in the `Personal` vault.
Point it elsewhere with:

```json
{ "portal": { "op_item": "cernerhealth.com (me)", "op_vault": "Private" } }
```

The macOS Keychain works too, if you would rather not approve a biometric
prompt:

```json
{ "portal": { "source": "keychain", "keychain_service": "cernerhealth.com" } }
```

Add `keychain_account` if more than one item shares the service name; without
it, the item's own account is the username, which keeps it out of a config file
that is not encrypted. Create the item with `-T /usr/bin/security`, or every
read raises a GUI prompt and the point is lost:

```sh
security add-generic-password -s cernerhealth.com -a you@example.com \
  -T /usr/bin/security -w
```

`-w` must come last and take no value: that is what makes `security` prompt for
the password instead of reading it from a command line that your shell history
would keep.

Know what that trades. `op` gates the password behind Touch ID every time;
`-T /usr/bin/security` gates it behind "anything running as this user can shell
out to `security`" — the same bar the token store already sits at. The password
is the root credential, it does not expire, and a Keychain item does not sync to
your other machines. Given the portal session is cached, `op` runs seldom enough
that the prompt is cheap. `op` stays the default for those reasons.

Either way the password is fetched at the moment it is posted and is never
written to disk, a log line, or `inspect`.

## Usage

```sh
health labs                        # latest value per analyte, with ranges
health labs --abnormal             # only what's outside its reference range
health labs --no-vitals            # labs only; --vitals for the other half
health labs --panel cbc            # one panel
health labs --since 2026-01-15 --until 2026-01-15   # one draw
health labs --history Hct          # every recorded draw of one analyte
health labs --history Hct --trend  # …with a sparkline and the span it's drawn against

health meds                        # active prescriptions; --all for the rest
health problems                    # the problem list; --all adds encounter diagnoses
health allergies                   # never filtered — see below
health shots                       # immunizations, with the CVX product name
health docs                        # clinical notes and visit summaries
health docs --get 197093525        # download one (ids come from `health docs`)
health docs --get 197093525 --out visit.pdf

health auth login          # browser sign-in, standalone patient launch
health auth status         # is there a usable token? (never prints one)
health auth refresh        # force a refresh
health auth logout         # delete the encrypted token store and portal session

health config show         # prints the file as written — op:// stays a reference
health config edit
```

`--json` on any command swaps formatted output for JSON. `--tenant <name>`
overrides the tenant for a single `auth` invocation. `--since` and `--until`
work on every record command, not just `labs`.

Counts and sign-in chatter go to stderr, so `health labs --json | jq` gets
nothing but JSON.

### What the record commands decide for you

Two of these hide rows by default, and both say how many — on every path,
including when the filter empties the list. The third deliberately hides
nothing:

- **`meds`** shows active, on-hold and draft prescriptions, and prints the
  count of what it left out. Its Refills column is what the prescriber
  *authorized*, never what remains — `MedicationDispense` is empty on this
  record, because a prescription filled at a retail pharmacy leaves no dispense
  event in Millennium, so the pharmacy is the only place that knows.
- **`problems`** shows the standing problem list. Condition carries encounter
  diagnoses under the same resource type — 106 of them against 30 problems on
  this record — and printing all 136 as "your problems" would be wrong in the
  direction that alarms people.
- **`allergies`** filters nothing, deliberately. The list is short, and it is
  the one list where an omission is dangerous rather than merely untidy; a
  resolved or refuted entry still says what was once suspected.

`docs` is the only command that writes a file, and only when given `--get`. It
refuses to overwrite. Some documents are listed but not released for download —
intake forms 404 while the visit summary from the same encounter succeeds — so
that 404 gets its own message rather than reading as a broken id.

## Two backends

`auth` and the five record commands talk to Millennium over FHIR. `labs` does
not, because **the FHIR endpoint has no lab values in it**:
`Observation?category=laboratory` returns a full page of resources with zero
`valueQuantity` and zero `referenceRange` — codes and dates and nothing else.
Broadening the app registration to all 37 patient scopes changed the response by
zero bytes, so this is a data problem, not an authorization one.

The gap is specific to Observation. `MedicationRequest`, `Condition`,
`AllergyIntolerance`, `Immunization` and `DocumentReference` all come back
complete over the same grant, which is why those five commands are FHIR and
`labs` alone is not.

The values live in HealtheIntent, the platform behind the patient portal, and
the portal serves them as JSON to anyone who asks for `Accept:
application/json` on the same URL the browser navigates to. So `labs` signs into
the portal and reads that. The two backends see different records — Millennium
is the deeper archive, carrying several times the conditions and documents;
HealtheIntent is the curated current view, and the only source of structured lab
values.

## How the portal login works

No browser, no Playwright — a short chain of `Net::HTTP` requests:

1. `GET` the portal entry page, which bounces to a Cerner Health SAML endpoint.
2. That endpoint renders an ordinary Django login form; post it with credentials
   read from 1Password at that moment and never written down.
3. The response is a SAML POST-binding page whose auto-submitting form hands the
   assertion back to the portal.
4. The portal sets `cloud-session` on `.healtheintent.com`, and that one cookie
   authorizes the whole record.

`Login` walks whatever form it is shown rather than hard-coding the six hops, so
the provider inserting or reordering a step doesn't break it.

The session is then cached — age-encrypted, same as the tokens — so the next
command needs neither 1Password nor the SAML chain. A cold run takes ~7s and one
biometric prompt; a warm one takes ~1s and none. Liveness is decided by trying
it, since the portal publishes no expiry.

## How the FHIR login works

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

**The portal's `normalcy` field never disagreed with itself.** Every result
observed across this record is labelled `"Normal"` — including values below the
floor of their own stated range and above the ceiling of it. A tenth of the
results are outside their own printed range and the field calls each one normal.
The field can evidently hold other strings, so it isn't literally a constant; it
simply never once carried information. So normalcy is always recomputed from the
`referenceRanges` the same payload supplies; the portal's claim is parsed and
carried along as `reported_normalcy`, unused, for comparison. Trusting it would
have meant `--abnormal` printing nothing, ever.

**`results` returns the latest value per analyte, not every draw.** A window
spanning 2010–2026 still yields exactly one hematocrit. A result type with
`hasMore: true` — which is nearly all of them — has its earlier values behind a
second endpoint. The parser surfaces that as `truncated`, `labs` discloses the
count on stderr, and `--history` is what goes and gets them.

**The history endpoint is keyed by an id that exists only in the HTML.**
`results/history/` serves clean JSON like everything else, but only when asked
for a `name_and_type_uuid` — a value that appears on no panel, no result type
and no result in any JSON payload. It is emitted solely into the rendered
page, on the "View all for this result" link. Asking instead for `type=Hct`,
which is what the per-result `detailUrl` uses, answers *"we're unable to find
the results you searched for"* and hands back the default listing — a wrong
answer with a 200 on it. So `--history` scrapes the ids out of the page first.
That is the one place this tool reads HTML, and there is no other way in.

**`page_size` fails open.** It is honoured at 100 and ignored at 500, where the
server quietly reverts to 25 rather than erroring. A request that returns a
prefix of the answer and calls it success is the worst outcome available here,
so `history` asks for a size known to work and follows the cursor — which is
itself only reachable through the `page_key` embedded in each row's detail
link, since the response carries no paging fields of its own.

**Grant storage is per tenant.** Every login rewrites the whole store, so a
single shared file meant `--tenant west` silently destroying the grant for
`central` — no error, just a browser round-trip the next time. Each tenant now
gets its own file, and `auth` moves a pre-split `tokens.age` into place on the
way through, reading the tenant out of the file rather than guessing.

**Nothing in the payload separates labs from vitals.** Blood pressure, BMI and
weight arrive in the same shape as a CBC; `item.type` merely repeats the panel
name, and `category`/`classification` don't exist. `--vitals` / `--no-vitals`
therefore match panel names against a regex list, which is a naming convention
and not a contract. `--panel` is the escape hatch when it guesses wrong.

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
| `~/.local/share/health/tokens/<tenant>.age` | FHIR tokens, one file per tenant, age-encrypted to an SSH key, mode 0600 |
| `~/.local/share/health/portal-session.age` | portal cookies + person id, same encryption |
| `~/.local/share/health/cache/` | SMART discovery documents |

`auth logout` clears every tenant's grant and the portal session, not just the
current tenant's — anything less would not be signing out.

These are encrypted to an SSH *key* rather than a passphrase, which is
what keeps the tool non-interactive: a read needs the private key on disk, not a
prompt. `portal-session.age` gets the same treatment as the tokens because it
deserves it — `cloud-session` is a live credential to the entire record, not a
scoped token. Caching the password instead would have traded one prompt for a
worse secret at rest and still paid the SAML round-trip every run.

Nothing here ever writes a token to a log, an error message, or stdout.
`auth status` reports presence booleans, a scope count, and an expiry — never a
value, not even a prefix. Portal errors name the section and the HTTP status and
deliberately omit the response body, which would be PHI on its way to a crash
report.

## Tests

```sh
ruby test/cli_test.rb
```

No network. The OAuth token and discovery paths run against a real loopback HTTP
server rather than a mock, and `auth login` is covered end to end by overriding
the one method that would open a browser. The portal login is tested the same
way: a loopback server serves the SAML and Django pages, so the redirect chain,
the cookie-domain rules and the session cache are all exercised for real.

100% line *and* branch coverage is enforced; the two genuinely untestable
branches (launching Safari, a browser resetting the connection mid-write) are
marked `:nocov:`. The FHIR commands are tested against a fake client rather than
the loopback server — the client itself is what the loopback server is for, and
the commands are worth testing against payload shapes, not HTTP.

One trap worth knowing about: any test that builds a real record factory has to
take `op` off `PATH` first. With a live 1Password session available it will
happily sign in to the actual portal and pull actual results into the test run.
