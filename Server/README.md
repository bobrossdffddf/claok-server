# Cloak server

Licences and update notices. One binary, one SQLite file, no runtime
dependencies. Put it behind whatever already terminates TLS on your box.

## Running it

```
export CLOAK_ADMIN_TOKEN="$(openssl rand -hex 32)"
export CLOAK_DB=/var/lib/cloak/cloak.sqlite
export CLOAK_KEY=/var/lib/cloak/cloak-signing.key
export CLOAK_PORT=8787
./cloak-server
```

On first run it prints a public key. Paste it into
`Licensing.serverPublicKey` in `Packages/CloakKit/Sources/CloakKit/Licensing/Licensing.swift`
and set `Licensing.serverBase` to your host. While that key is empty the app
runs unlocked, which is what a development build wants.

**Back up `cloak-signing.key`.** Lose it and every token in the field stops
verifying, which locks out everyone who paid until they reactivate.

## nginx

```nginx
location /v1/ {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## systemd

```ini
[Unit]
Description=Cloak licence server
After=network-online.target

[Service]
User=cloak
WorkingDirectory=/var/lib/cloak
Environment=CLOAK_DB=/var/lib/cloak/cloak.sqlite
Environment=CLOAK_KEY=/var/lib/cloak/cloak-signing.key
Environment=CLOAK_PORT=8787
EnvironmentFile=/etc/cloak/secrets
ExecStart=/usr/local/bin/cloak-server
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/cloak

[Install]
WantedBy=multi-user.target
```

`/etc/cloak/secrets` holds one line, `CLOAK_ADMIN_TOKEN=...`, mode 600.

## Making licences

```
# ten of them
curl -sX POST https://your.host/v1/admin/licenses \
  -H "x-admin-token: $CLOAK_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"count":10,"plan":"standard","note":"launch batch"}'

# one that runs out in a year
curl -sX POST https://your.host/v1/admin/licenses \
  -H "x-admin-token: $CLOAK_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"count":1,"days":365}'

# who has what
curl -s https://your.host/v1/admin/licenses -H "x-admin-token: $CLOAK_ADMIN_TOKEN"

# withdraw one, and free the phone it was on
curl -sX POST https://your.host/v1/admin/revoke \
  -H "x-admin-token: $CLOAK_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"license":"CLOAK-XXXXX-XXXXX-XXXXX-XXXXX","revoked":true,"release_device":true}'
```

Keys look like `CLOAK-A7K2M-9PQRT-4XZWB-HN3JD`. The alphabet leaves out
everything that looks like something else, so nobody misreads a nought for an
O down a phone line.

## Announcing an update

```
curl -sX POST https://your.host/v1/admin/release \
  -H "x-admin-token: $CLOAK_ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"platform":"ios","build":14,"version":"1.2",
       "url":"https://your.host/downloads/CloakInstaller-macos.dmg",
       "notes":"Routines can take a lunch trip now.","required":false}'
```

The app compares its own `CFBundleVersion` against `build` and shows a banner
when yours is higher. `required` makes the banner insistent rather than
dismissible. Setting a release for `platform: "macos"` or `"windows"` lets the
desktop installer check the same way.

## How the one-device rule works

The `activations` table has one row per licence, so a second device cannot get
one. Activating on a phone that already holds the licence is a no-op and
refreshes the token. Somebody moving to a new phone releases it from Settings
on the old one, or you release it for them with `release_device`.

## What the token is

Activation returns a small Ed25519-signed statement — licence, device, plan,
expiry — that the phone verifies with the public key baked into the app. It is
good for fourteen days, and the app quietly asks for a fresh one once five days
are left.

That grace is deliberate. A licence check that fails closed the moment your
server hiccups turns an outage into every paying customer's app going dark.

## What this does not do

It raises the cost of casual sharing. It does not stop a determined person:
the app is sideloaded, they control the device, and a patched binary can skip
the check. Signature verification means they have to patch rather than just
point the app at their own server, which is the honest limit of what any
client-side licence check achieves.
