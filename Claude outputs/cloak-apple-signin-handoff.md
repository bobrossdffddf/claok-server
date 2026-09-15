# Cloak: Apple sign-in failure — technical handoff

Written 2026-09-11. Everything below is either measured or read from source. Where
something is a hypothesis it says so.

---

## 1. What the project is

**Cloak** is an iOS GPS location-simulation app (comparable to Vanish / getvanish.app
and GhostMe), built on Apple's real developer location-simulation mechanism. Intended
to run phone-only after a one-time desktop install.

**Critical product constraint: it must work for people with a FREE Apple ID.** The
author has a paid Apple Developer Program account under a *different* Apple ID, but
that is irrelevant to the product and must not become a dependency. Any fix that only
works for paid accounts is not a fix.

### Components

| Part | Location | Notes |
|---|---|---|
| Desktop installer | `Desktop/` | Rust, egui 0.31.1 / eframe 0.31.1 |
| iOS app | `App/`, `Packages/CloakKit/` | SwiftUI, `@Observable`, iOS 17+ floor |
| Native bridge | `Bridge/cloak-bridge/` | Rust staticlib → xcframework |
| Repo root | `/Users/wacko/Downloads/Cloak` (macOS) | |

### Key dependencies

- **`isideload` 0.3.17** (nab138) — Apple GSA/grandslam login, SRP, anisette v3,
  `developerservices2`, CSR, resigning, install.
  **Now vendored at `Desktop/vendor/isideload` with `[patch.crates-io]` in
  `Desktop/Cargo.toml`.** Several fixes below are patches to this vendored copy.
- **`idevice` 0.1.65** (jkcoxson) — usbmuxd, lockdown (port 62078), AFC,
  installation_proxy, misagent, house_arrest, AmfiClient, remote_pairing, RSD.

---

## 2. The goal that is currently blocked

Sign in to an Apple ID from the desktop installer, so it can request a signing
certificate and provisioning profile, resign the IPA, and install it on the phone.

**Sign-in currently fails at the two-factor step.** Everything before that works.

---

## 3. Current status

Working, verified against Apple:

- Network path to Apple
- Anisette provisioning against a public helper
- Machine identity accepted by Apple
- Apple ID accepted
- **Password accepted** — Apple returns `au: trustedDeviceSecondaryAuth`

Failing:

- **Every `/auth/*` two-factor endpoint returns `403` with an empty body.**

```
GET  https://gsa.apple.com/auth                       -> 403, empty body   (list trusted numbers)
GET  https://gsa.apple.com/auth/verify/trusteddevice  -> 403, empty body   (push code to devices)
PUT  https://gsa.apple.com/auth/verify/phone          -> 403, empty body   (send code by SMS)
```

Response headers on the 403 (the only thing Apple returns):

```
x-apple-i-request-id: b11f05fb-ae21-11f1-a9cd-dfb93a781b7d
x-apple-id-session-id: B59ABE92C924876FA0D36F0371A717FF
```

No `Retry-After`, no `X-Apple-I-Error`, no body.

Consequence: no verification code is ever delivered to any device, so the sign-in
cannot complete.

---

## 4. Root causes found and fixed (chronological)

Each was real and each was masking the next. All are committed.

### 4.1 Apple blocks the Xcode identity — `38bb541`

**This is the change that started everything and it is external to us.**

Apple now refuses any request whose `X-Mme-Client-Info` header names
`com.apple.dt.Xcode`. Measured from the affected Mac against
`https://gsa.apple.com/grandslam/GsService2`, varying only that header:

| `X-Mme-Client-Info` | Status |
|---|---|
| `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>` | **503** |
| `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>` | **503** |
| `<MacBookPro18,3> <macOS;15.3.1;24D70> <com.apple.AuthKit/1 (com.apple.dt.Xcode/23504)>` | **503** |
| `<MacBookPro18,3> <macOS;15.3.1;24D70> <com.apple.AuthKit/1>` | **200** |
| `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>` | **200** |
| `<MacBookPro18,3> <macOS;14.4.1;23E224> <com.apple.akd/1.0>` | **200** |
| absent / empty / `totally-not-a-client-info` | **200** |

Nine values × four User-Agents. Every value naming Xcode: 503. Every value without
it: 200 with a real GSA plist response. The 503 comes from Apple's edge (nginx-style
HTML page), so the request never reaches the sign-in service, which is why it reads
as an outage.

Every public anisette helper reports itself as Xcode, so **every** helper failed
identically and walking the helper list changed nothing.

**Fix:** `Desktop/src/anisette.rs::without_xcode()` strips the
` (com.apple.dt.Xcode/…)` clause from whatever the helper reports, leaving the Mac
model and macOS build untouched so they still match the identity data the helper
minted. Covered by three unit tests.

This matches a report from the Vanish developer: *"at 6am apple stopped accepting a
certain ID card we flash to apple … so to fix it i swapped the card out"*. Vanish
broke at the same moment for the same reason.

### 4.2 Dead trust key on the default helper — `4ae2998`

`isideload` hardcodes `DEFAULT_ANISETTE_V3_URL = "https://ani.stikstore.app"`, whose
trust key Apple invalidated:

```
Anisette provisioning failed: end provisioning error
invalid Trust Key (-45003)
```

**Fix:** `Desktop/src/anisette.rs` keeps a helper list with SideStore's maintained
servers first and the dead default last, remembers rejected helpers in config, and
walks the list on a provisioning rejection.

### 4.3 Health check probed the wrong endpoint — `7c4f5c2`

The check fetched each helper's homepage. The endpoint the sign-in depends on is
`POST /v3/get_headers`, which fails independently on these volunteer-run servers —
`ani.sidestore.io` served its homepage fine while returning 502 there, so it passed
the check, got selected, and sank the sign-in.

**Fix:** the check now posts to `/v3/get_headers` the way the sign-in will, with the
homepage check as a fallback for older servers.

**Note for whoever picks this up:** this is still imperfect. A v3 server returns
HTTP 200 with a JSON *error* body for an unprovisioned identifier:

```json
{"message":"provision.adi.ADIException: not provisioned (-45061)","result":"GetHeadersError"}
```

The check only inspects the HTTP status, so it still accepts a server that answers
200-with-error. Worth tightening.

### 4.4 Error bodies were discarded — `5e1b008`

`isideload` used `error_for_status()`, which throws the response away on a bad
status. Apple explains refusals in the body and in `Retry-After`, so every failure
looked identical and said nothing. Several rounds were debugged blind because of
this.

**Fix (vendored):** `src/auth/grandslam.rs` reads the response before judging the
status and logs body + `Retry-After`.

### 4.5 Apple's per-IP burst throttle — `8e84e78`, `4a3b625`

Apple's edge returns 429 to bursts from one internet address. No `Retry-After`, no
account involvement, escalates with volume, clears after a short quiet period.
Measured with paired requests, one idle minute before each pair:

```
gap=0s   first=429  second=429
gap=2s   first=200  second=200     (two minutes later)
```

Waiting 12 hours achieved nothing because attempts kept arriving.

**Fix (vendored `grandslam.rs`):** nothing is delayed until Apple actually returns
429; that sets a cooling-off period later requests wait out, and the first success
clears it. Retries with backoff, max 4 attempts.

### 4.6 macOS resolver wedged — `076f3d0`

The Mac's `mDNSResponder` stopped resolving names. Direct DNS worked, the system
resolver did not:

```
dscacheutil -q host -a name gsa.apple.com          -> (nothing)
nslookup apple.com 8.8.8.8                         -> 17.253.144.10
nc -z 17.32.194.34 443                             -> TCP_OK
curl --resolve gsa.apple.com:443:17.32.194.34 …    -> 401 from Apple
```

Caused by VPN clients removed/quit untidily. The machine had Hotspot Shield, VPN
Proxy Master and VPN Super installed and **31 leftover `utun` interfaces** up.
Fixed by rebooting.

**Fix:** the preflight now distinguishes a broken resolver (name fails but a fixed
Apple address answers on 443) from a blocked network, and says to restart the Mac
instead of suggesting a different network.

### 4.7 VPN carrying all traffic — part of `076f3d0`

At one point Hotspot Shield was connected and holding the default route
(`utun26`), exit IP `103.111.32.9` vs `169.241.65.73` direct. A shared free-VPN exit
is permanently over Apple's per-address limit.

**Fix:** the app reads the default route, and if it is a tunnel it names the
connected VPN service via `scutil --nc list` and tells the user to turn that one off.

### 4.8 `-22406` reported as a lockout — `cdb9164`

`-22406` is Apple's code for "enter the correct password". It was listed inside
`looks_rate_limited()`, so the one response meaning Apple actually examined the
account was displayed as a two-hour lockout telling the user to change nothing and
wait. This check ran first and masked the real answer completely.

**Fix:** checked first and reported accurately. A saved password Apple rejected is
also forgotten so it is not silently reused.

### 4.9 Two-factor failures were fatal — `2e64c0a`, `8d065d8`, `233a962`, `d594a55`

A chain of places where an optional step ended the whole sign-in:

- fetching trusted phone numbers (only needed to *offer* SMS) was fatal
- the request that nudges Apple to push a code was fatal
- choosing a number to text validated it against a list Apple refuses to supply,
  failing with `Selected trusted number ID not found in trusted numbers`

**Fix:** all made non-fatal; the SMS option is offered whether or not the list
arrives, defaulting to the first number on the account.

---

## 5. Bugs introduced during this session (all fixed, listed for honesty)

| Bug | Effect | Fixed in |
|---|---|---|
| Overrode `client_info` with the *host* Mac's values | Identity data minted for the helper's machine sent alongside a claim to be a different machine → 503 | `868c5e6` |
| Fixed 6-second gap in front of every request | Starved the provisioning websocket, which times out waiting for us to relay Apple's answers → `Anisette provisioning timed out` on 3 helpers | `4a3b625` |
| 429 → immediately try next helper | 8 sign-ins in 30 seconds, deepening the very throttle it reacted to | `8e84e78` |
| Timeout classified as "Apple refused the identity" | Blamed Apple, and spent one of the 3 attempts reserved for real Apple answers | `4a3b625` |
| UI said "Apple sent you a code" when the push had 403'd | User waits for a code that was never sent | `233a962` |
| Shipped iPhone Settings instructions for "Get Verification Code" | That menu path does not exist on the user's iOS version | `233a962` (removed) |

---

## 6. The open problem

**All three `/auth/*` two-factor endpoints return 403 with an empty body.**

### Ruled out by measurement

- **Not the Xcode identity on these endpoints.** Tried `X-Apple-App-Info` values
  `com.apple.gs.xcode.auth`, `com.apple.gs.idms.auth`, `com.apple.gs.appleid.auth`,
  and absent, each with and without `X-Xcode-Version`. All 403.
- **Not the per-IP 429 throttle.** Different status, and 429s are absent from these runs.
- **Not the password.** Apple accepted it and moved to 2FA.
- **Not the network or DNS.** Both verified working at the time of these 403s.
- **Not a VPN.** Default route was `en0` during these runs.
- **Probably not "no trusted device".** The user confirms the iPhone is signed in to
  the same Apple ID (`seth.mann@icloud.com`) and Apple itself returned
  `au: trustedDeviceSecondaryAuth`.

### Latest hypothesis — implemented but UNTESTED at time of writing (`5d3faf3`)

`isideload`'s `AnisetteData::get_headers()` deliberately omits five headers:

```rust
// Some headers don't seem to be required. I guess not including them is
// technically more efficient soooo
```

Omitted: `X-Apple-I-MD-LU`, `X-Apple-I-MD-RINFO`, `X-Apple-I-Client-Time`,
`X-Apple-I-TimeZone`, `X-Apple-Locale`.

This is harmless for `GsService2`, because that endpoint carries the same values
inside the request body (`cpd`), which is why sign-in works. **The `/auth/*`
endpoints have no body — headers are the only channel — so those five values are
simply absent from every 2FA request.** One omission presenting as three broken
endpoints.

**Fix implemented:** new `AnisetteData::get_full_headers()` in the vendored
`src/anisette/mod.rs`, used by `build_2fa_headers()`. Includes a dependency-free
RFC3339 timestamp with a unit test (`clock_tests`).

**This has not yet been confirmed to work.** If the next run still 403s, this
hypothesis is wrong.

### If that fails, next steps in order

1. **Sign in at `appleid.apple.com` in a browser with that Apple ID.** This is the
   highest-value step and has not been done. Apple's own flow returns real error
   messages instead of an empty 403, and will establish whether the account can
   receive verification codes at all. If Apple's own site cannot send a code, the
   problem is the account's 2FA state, not the client.
2. Compare against a currently-working tool (SideStore/AltStore/Vanish) on the same
   account and capture the exact 2FA request headers they send. A byte-level diff
   against ours would settle this immediately.
3. Investigate whether `spd` decryption is yielding a correct `adsid` /
   `GsIdmsToken`. `X-Apple-Identity-Token` is `base64(adsid + ":" + GsIdmsToken)`. A
   subtly wrong token would produce exactly this uniform 403. Log both values (they
   are session-scoped, not long-lived secrets) and sanity-check their shape.
4. Consider that `x-apple-id-session-id` in the response is characteristic of the
   **idmsa** web auth flow rather than GSA. Worth checking whether Apple now expects
   an `scnt` header or a session cookie carried from the sign-in response.

---

## 7. Environment and build

The repo lives on a macOS machine. All Rust/Xcode/git work runs there.

```bash
cd /Users/wacko/Downloads/Cloak

# check
cd Desktop && cargo check --release
cargo test --release -p isideload            # vendored library tests
cargo test --release                         # installer tests

# build + package
bash Scripts/build-installer.sh              # -> dist/Cloak Installer.app
bash Scripts/build-dmg.sh                    # -> dist/CloakInstaller-macos.dmg

# install for testing
rm -rf "/Applications/Cloak Installer.app"
cp -R "dist/Cloak Installer.app" /Applications/
rm -f ~/Library/Application\ Support/app.Cloak.CloakInstaller/anisette.json
```

Log: `~/Library/Logs/Cloak/installer.log`
Config: `~/Library/Application Support/app.Cloak.CloakInstaller/config.json`
Version: `VERSION` file (currently `1.3`), `Scripts/version.sh` derives build
`10300` as `MAJOR*10000 + MINOR*100 + PATCH`.

**Note:** `Scripts/build-installer.sh` can exceed a 120s command timeout on a cold
build. Run `cargo check` first to warm the cache, then the build script.

---

## 8. Files that matter

| File | Why |
|---|---|
| `Desktop/src/anisette.rs` | Helper list, health check, `without_xcode()`, error classification |
| `Desktop/src/worker.rs` | Sign-in loop, preflight, VPN/resolver detection, user-facing error text |
| `Desktop/src/ui.rs` | 2FA code window |
| `Desktop/vendor/isideload/src/auth/apple_account.rs` | Login state machine, 2FA, `build_2fa_headers` |
| `Desktop/vendor/isideload/src/auth/grandslam.rs` | HTTP to Apple, base headers, pacing/backoff |
| `Desktop/vendor/isideload/src/anisette/mod.rs` | `AnisetteData`, `get_full_headers()` |
| `Desktop/vendor/isideload/src/anisette/remote_v3/mod.rs` | Helper protocol, websocket provisioning |

---

## 9. Hard constraints

**Must work for free Apple IDs.** No paid-account dependency, ever.

**Never commit:** `cloak-signing.key`, `Scripts/server.env`, `Server/.env`, `*.p8`,
`*.p12`, `*.mobileprovision`. The App Store Connect key lives outside the repo at
`~/.appstoreconnect/private_keys/` (chmod 600).

**Apple's developer disk image is Apple's property.** It must not ship inside the app
or be committed. It lives in gitignored `ServerPayload/DeveloperImage/` and is
uploaded to the server.

**The admin token was pasted into a chat and should be rotated.**

**Do not retry sign-in aggressively.** Apple rate-limits per internet address and
per account. A 429 costs nothing against the account (no password was judged) but
feeds the address throttle. A rejected password does count. Paced backoff only.

**`NetworkExtension` entitlement is a property of the signature** and is unavailable
to free Apple IDs. This is why Cloak depends on the separate LocalDevVPN app for the
loopback reflector. Both Cloak's own reflector and LocalDevVPN use peer `10.7.0.1`;
Cloak uses `10.7.0.0`, LocalDevVPN uses `10.7.1.1`.

---

## 10. Other known-pending work (unrelated to this bug)

- Windows `.exe`: `.github/workflows/installer.yml` restructured but **never run**.
- On-device renewal: `Bridge/cloak-bridge/src/renew.rs` compiles for
  `aarch64-apple-ios` but nothing calls it from Swift. Needs server IPA endpoint,
  expiry tracking, Keychain credentials, `BGProcessingTask`.
- Lockdown pairing (`Bridge/cloak-bridge/src/lpair.rs`) compiles, never run on a
  real device.
- DMG is ad-hoc signed; `spctl` rejects it. Notarization not done.
- TestFlight is not a viable distribution path (developer disk image + private
  services + location spoofing → App Store rejection).

---

## 11. Advice for the next assistant

The failure modes here look identical from the outside — sign-in fails, error is
vague — while having completely unrelated causes, and they stack. Several rounds
were lost to fixing a real bug, declaring success, and hitting the next one.

1. **Read the log before theorising.** `~/Library/Logs/Cloak/installer.log`. The
   decisive line is usually already in it.
2. **Never trust an error message's own claim about its cause.** Two of the worst
   detours came from the app confidently reporting a lockout when Apple had said
   "wrong password", and reporting an Apple refusal when a helper had timed out.
3. **Measure against Apple directly rather than reasoning about it.** `curl` from
   the affected machine, varying one header at a time, settled in 30 seconds what
   hours of inference could not. Both real breakthroughs came from that.
4. **Check the machine, not just the app.** The VPN and the wedged resolver were
   both invisible from inside the code and cost hours. `route -n get default`,
   `scutil --nc list`, `dscacheutil -q host -a name <host>` are cheap.
5. **Do not add fixed delays to anything.** The provisioning websocket times out
   waiting on relayed responses.
6. **Do not send the user into OS settings menus.** The paths change between OS
   versions and the target audience is non-technical. Fix it in the app.
