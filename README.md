# Cloak

Changes the location your iPhone reports to every app on it, using the location
simulator Apple already ships inside iOS for developers. No jailbreak. No
computer needed after the first install.

---

# Part 1: what is actually going on here

Three separate things live in this repo. It helps to know which is which
before you start, because the instructions below keep referring to them.

**The phone app.** Swift. This is Cloak itself, the thing with the map.

**The installer.** A small desktop program, Mac and Windows, that puts the
phone app onto an iPhone. Apple will not let you just download an app from
anywhere, so the installer signs it with your own Apple ID first. That is the
same thing Xcode does when a developer runs an app on their own phone.

**The server.** Optional. It does two jobs: it checks licence keys so only
people who paid can use Cloak, and it tells people when a new version is out.
If you are only building this for yourself, skip Part 3 entirely and the app
runs unlocked.

---

# Part 2: put Cloak on a phone

1. Build the installer, or use one somebody already built:

   ```
   Scripts/fetch-assets.sh        # downloads the fonts and icons, once
   Scripts/build-ipa.sh           # builds the phone app
   Scripts/build-installer.sh     # builds the Mac installer
   Scripts/build-dmg.sh           # wraps it in a .dmg you can hand out
   ```

   Everything lands in `dist/`.

2. Open **Cloak Installer**, plug in an iPhone, and follow it. It turns on
   Developer Mode for you, asks for an Apple ID, signs Cloak, installs it, and
   tells iOS to trust it so there is no "Untrusted Developer" warning.

3. Open Cloak on the phone. It walks you through the last step, which is one
   free App Store app called LocalDevVPN.

That is the whole user-facing story. Everything below is for you, the person
running it as a product.

---

# Part 3: the server

## What it is for, in plain words

Right now anybody who gets your `.dmg` can use Cloak forever. The server fixes
that. It hands out licence keys, allows **one phone per key**, and can switch
a key off if somebody shares it.

It also holds one file the app cannot work without. iOS keeps its location
simulator locked behind a signed image from Apple, and Cloak does not ship
that image inside itself. It downloads it from your server after a licence is
accepted. That is what makes the licence real rather than a switch somebody
can flip: with no licence there is no image, and with no image there is
nothing to simulate with.

Same server also tells everybody when you release a new version, since Cloak
is not on the App Store and nothing else would tell them.

## What you need before you start

- A computer in your homelab that runs **Docker**. Any of them. It does not
  need to be powerful; this thing handles a few requests a day.
- A **Cloudflare account** with your domain on it. Free tier is fine.
- Your Mac, with this repo on it.

You do **not** need to forward any ports, buy a certificate, set a static IP,
or touch your router. Cloudflare's tunnel makes the connection outward from
your homelab, so there is nothing exposed to the internet.

## Step 1: get the container built

You already pushed this repo to GitHub. Every time you push, GitHub builds the
server into a **container image** and stores it for you. A container image is
just a packaged program with everything it needs, so your homelab does not
have to compile anything.

Go to your repo on GitHub and click the **Actions** tab. You should see a run
called **Server image**. Wait for the green tick, three or four minutes the
first time.

If you see nothing there, the workflow file did not make it into the push.
Check that `.github/workflows/server.yml` exists in the repo on GitHub.

Then make the image downloadable without a login:

1. Go to your GitHub profile page.
2. Click **Packages**.
3. Click **cloak-server**.
4. Click **Package settings**, scroll to **Danger Zone**, and **Change
   visibility** to **Public**.

That is safe. The image contains the program only. Your signing key, your
database and your licences all live on your own disk and never go near it.

## Step 2: make the Cloudflare tunnel

A tunnel is a little program that runs next to your server and dials out to
Cloudflare. Cloudflare then sends traffic for your domain back down that
connection. Nothing has to be open on your side.

1. Go to **one.dash.cloudflare.com** (that is Cloudflare Zero Trust).
2. In the left menu: **Networks**, then **Tunnels**.
3. Click **Create a tunnel**, choose **Cloudflared**, name it `cloak`, save.
4. The next screen shows an install command with a very long string in it
   after `--token`. **Copy just that long string.** Ignore the rest of the
   command; you will not run it.
5. Click **Next**. Now fill in the Public Hostname:

   | Field | What to put |
   | --- | --- |
   | Subdomain | `cloak` |
   | Domain | pick your domain |
   | Type | `HTTP` |
   | URL | `cloak:8787` |

   `cloak:8787` looks wrong but is right. It is the name of the server
   container on its own private network, not an address on your LAN.

6. Save.

Cloudflare creates the DNS record itself. There is nothing to do at your
registrar.

## Step 3: start it on your homelab

SSH into whichever box runs Docker, then:

```bash
sudo mkdir -p /opt/cloak && sudo chown $USER /opt/cloak
cd /opt/cloak

curl -O https://raw.githubusercontent.com/bobrossdffddf/claok-server/main/Server/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/bobrossdffddf/claok-server/main/Server/.env.example
```

If your repo is private, those two `curl` lines will fail. Copy the two files
across from your Mac instead:

```bash
scp Server/docker-compose.yml Server/.env.example you@your-box:/opt/cloak/
ssh you@your-box 'mv /opt/cloak/.env.example /opt/cloak/.env'
```

Now open `.env` and fill in three lines:

```bash
nano /opt/cloak/.env
```

```
CLOAK_IMAGE=ghcr.io/bobrossdffddf/cloak-server:latest
CLOAK_ADMIN_TOKEN=
CLOUDFLARE_TUNNEL_TOKEN=
```

- `CLOAK_IMAGE` is where GitHub put the image. Lowercase.
- `CLOAK_ADMIN_TOKEN` is a password you invent, which lets you create licences.
  Make one with `openssl rand -hex 32` and paste the output.
- `CLOUDFLARE_TUNNEL_TOKEN` is the long string from step 2.

Save with `Ctrl+O`, `Enter`, then `Ctrl+X`.

Start it:

```bash
cd /opt/cloak
docker compose up -d
docker compose logs cloak
```

In that log is a line like:

```
Public key for the app: qN7x...=
```

You do not need to copy it. Step 5 fetches it automatically. It is there so
you can see the thing worked.

Now check it from your phone, **on cellular, not on your Wi-Fi**, by visiting:

```
https://cloak.yourdomain.com/v1/health
```

You want to see `{"ok":true}`. If you do, the hard part is done.

## Step 4: send it the Apple image

This is the file the app cannot work without. Run this **on your Mac**, in
this repo:

```bash
Scripts/upload-ddi.sh you@your-homelab-box
```

It copies three files into `/opt/cloak/data/ddi/`. If your stack is somewhere
other than `/opt/cloak`, add the path as a second argument.

You can check it landed:

```bash
ssh you@your-box 'ls -lh /opt/cloak/data/ddi'
```

You should see `Image.dmg` at about 16 MB, plus two smaller files.

## Step 5: point the app at your server

One command, on your Mac. It asks your server for its public key and writes
both settings into the code for you.

```bash
Scripts/configure.sh https://cloak.yourdomain.com
```

It prints what it wrote so you can see it worked.

To turn licensing back off while you are testing, run it with no arguments.

## Step 6: rebuild and try it

```bash
Scripts/build-ipa.sh
Scripts/build-installer.sh
Scripts/build-dmg.sh
```

Make yourself a licence key:

```bash
Scripts/license.sh new 1 "my own phone"
```

The very first time, that command creates a file called `Scripts/server.env`
and stops, asking you to fill it in. Put your server address and the admin
token you invented in step 3 into it, then run the command again.

You get back something like `CLOAK-A7K2M-9PQRT-4XZWB-HN3JD`.

Install Cloak from the new `.dmg`, enter that key on the phone, and watch the
server:

```bash
ssh you@your-box 'cd /opt/cloak && docker compose logs -f cloak'
```

You should see the activation, then three requests for the setup files. That
is the whole thing working end to end.

---

# Part 4: running it day to day

All from your Mac, in this repo:

```bash
Scripts/license.sh new 10 "launch batch"     # ten keys to sell
Scripts/license.sh list                      # who has what, and on which phone
Scripts/license.sh revoke CLOAK-...          # switch one off for good
Scripts/license.sh free CLOAK-...            # let someone move to a new phone
Scripts/license.sh health                    # is the server up
```

## Releasing a new version

1. Open `project.yml` and increase `CURRENT_PROJECT_VERSION` by one.
2. Rebuild everything (`Scripts/build-ipa.sh`, `build-installer.sh`,
   `build-dmg.sh`).
3. Put the new `.dmg` somewhere people can download it.
4. Tell the server:

   ```bash
   Scripts/license.sh release 14 1.2 \
     https://your-download-link/CloakInstaller-macos.dmg \
     "Routines can take a lunch trip now."
   ```

   `14` is the build number you just set, `1.2` is what people see.

Every phone on an older build shows a banner with your note and the link.

## Updating the server itself

```bash
git push                                    # on your Mac
ssh you@your-box 'cd /opt/cloak && docker compose pull && docker compose up -d'
```

## Back this up

Everything that matters is in `/opt/cloak/data`:

- **`cloak-signing.key`** — irreplaceable. If you lose it, every licence in
  the world stops working until each person re-enters their key.
- **`cloak.sqlite`** — every licence you have sold and which phone has it.
- **`ddi/`** — you can re-upload this, but keep it anyway.

```bash
ssh you@your-box 'tar czf ~/cloak-backup-$(date +%F).tar.gz -C /opt/cloak data'
```

Worth putting on a schedule.

---

# When something goes wrong

**Look at the logs first.** Almost everything shows up here:

```bash
cd /opt/cloak
docker compose logs -f cloak     # the server
docker compose logs -f tunnel    # the Cloudflare connection
```

| What you see | What it means |
| --- | --- |
| `/v1/health` does not load | The tunnel is not connected, or the hostname points somewhere other than `cloak:8787` |
| `docker compose up` says it cannot pull the image | The GitHub package is still private, or `CLOAK_IMAGE` has a typo |
| The app never asks for a licence | `Scripts/configure.sh` was not run, so the key is still empty and Cloak runs unlocked |
| The phone says the setup files are missing | Step 4 was skipped, or they went to the wrong folder |
| The installer says a certificate failed | It clears it and retries once by itself. If it fails twice, you have used up your free Apple account's certificates, and you delete one at developer.apple.com |

---

# Building from source

```
Scripts/fetch-assets.sh        Inter and Phosphor, the fonts and icons
Scripts/build-bridge.sh        the Rust bridge, as an xcframework
Scripts/build-ipa.sh           the phone app, unsigned
Scripts/build-installer.sh     the Mac installer, with the app inside it
Scripts/build-dmg.sh           a disk image to hand out
Scripts/configure.sh URL       point the app at a licence server
```

Windows binaries come from `.github/workflows/installer.yml`, because a Mac
cannot build them.

A signed build for a paid Apple developer account needs a team ID. Put it in
`Scripts/team.env` as `CLOAK_TEAM_ID=...`; that file is ignored by git.

## Where things live

```
App/            the iOS app
Shared/         code the app and its extensions both need
Packages/       CloakKit: geometry, motion, routing, realism, licensing
Bridge/         the Rust bridge to iOS's own developer services
Tunnel/         the loopback packet tunnel, paid builds only
Widgets/        home screen widgets and the Live Activity
Desktop/        the Mac and Windows installer, in Rust
Server/         the licence and update server, in Rust
ServerPayload/  what the server hands out, not what ships in the app
Scripts/        everything above
```

---

# What Cloak can and cannot do

Anything that only reads CoreLocation sees what Cloak says, which covers Find
My, Snap Map, Life360 and most apps.

Anything that cross-references Wi-Fi network names, Bluetooth beacons, cell
towers or the motion coprocessor does not, and nothing running on a phone can
change that. A bank, a rideshare or an insurer reads rather more than
CoreLocation.

Cloak simulates the location of a device you own. Using it to deceive a person
or a service that relies on your location may break that service's terms, and
in some places the law.
