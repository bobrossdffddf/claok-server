# Cloak

Changes the location your iPhone reports to every app on it, using the location
simulation service Apple already ships inside iOS for developers. No jailbreak.
No computer after the first install.

Install it once from a Mac or a PC. After that the phone runs on its own, off
Wi-Fi or off cellular, and the computer never has to come back except to renew
the signature.

## What makes it different

The desktop products in this category are all the same shape: plug the phone
in, run one route, unplug, snap back to reality. That is enough to fool
somebody glancing at a map once. It is hopeless against anyone who looks at a
fortnight of history, where the tell is not any single journey but the absence
of all the others.

Cloak is built for the second case.

**Routines.** A routine is a life rather than a trip. It holds the places a
phone actually lives between and runs itself all day: asleep at home, out at
the usual time give or take a few minutes, parked at work with the phone
drifting a few metres the way a real one on a desk does, home again in the
evening. Departure times and pace are drawn from a seed that includes the date,
so no two days come out the same. Nothing else in this category can do this,
because the moment the cable comes out of a tethered product the simulation
dies.

**A believability score.** Every other product sells realism as an adjective.
Cloak grades a plan against the things that actually give a simulated location
away: how far the first point is from where the phone really is, whether the
route runs dead straight, whether twenty minutes of city driving contains a
single stop, whether the speed ever varies, whether the reported heading agrees
with the direction of travel. It shows the number, the reasons, and what to
change.

**Replay with variation.** A recording of your own driving is the most
believable thing a simulator can emit, because it is real. Replayed verbatim it
becomes the worst thing, because a trace repeated to the metre and the second
is easier to spot than any single fake journey. Cloak perturbs it: departure
slides, pace scales, the path drifts sideways along a smooth random walk, and
the pauses come out different lengths.

**Real roads, real limits, real stops.** Routes follow actual streets, drive
each stretch at that stretch's posted speed limit from OpenStreetMap, and stop
at the junctions and crossings that are really there. Driver personas change
how hard the car accelerates and how much it creeps over the limit.

**Everything a phone-first app can do that a desktop one cannot.** A Live
Activity with a Dynamic Island presence, so you can never forget the simulator
is running and can stop it from the lock screen. Shortcuts and App Intents, so
a location can be a step in an automation. Time-based schedules. A geofence
guard that stops everything if your real position leaves an area you set. A
peek button that shows you where you actually are without ending the run.

## Getting it

Run the installer for your platform. It finds the phone, turns on Developer
Mode for you (including making the switch appear in Settings, which iOS hides
until a computer asks), signs Cloak with your own Apple ID, installs it, and
hands the app the pairing key so there is nothing to set up on the phone.

A free Apple ID is enough. Apple's free signature lasts seven days, so the
installer can leave a small job behind that renews it quietly.

Cloak also needs [LocalDevVPN](https://apps.apple.com/app/id6755608044), a free
App Store app, to loop a connection back to the phone. Apple does not allow a
free developer account to sign the piece of software that would do that inside
Cloak itself, which is the entire reason that app exists. Vanish uses it for
the same reason.

**Windows** additionally needs Apple's iPhone driver, which comes with iTunes
from apple.com. Nothing opens iTunes; only the driver is used.

## Building it

```
Scripts/build-bridge.sh        the Rust bridge, as an xcframework
Scripts/build-ipa.sh           the sideloadable Cloak.ipa, unsigned
Scripts/build-installer.sh     the desktop app, with the ipa inside it
Scripts/build-dmg.sh           a disk image for macOS
```

Windows binaries come from `.github/workflows/installer.yml`, since a Mac
cannot cross-compile them.

A signed build for a paid developer account needs a team. Put it in
`Scripts/team.env` as `CLOAK_TEAM_ID=...`; that file is ignored by git.

There are two iOS app targets from one set of sources. `Cloak` is for a paid
team and carries its own packet tunnel. `CloakFree` has no network extension,
because Apple does not issue that entitlement to free accounts, and uses
LocalDevVPN instead. Nothing branches on a compile flag: the app asks its own
bundle whether a tunnel extension is present.

## Layout

```
App/          the iOS app
Shared/       code the app and its extensions both need
Packages/     CloakKit: geometry, motion, routing, realism, models
Bridge/       the Rust bridge to iOS's own developer services
Tunnel/       the loopback packet tunnel, paid builds only
Widgets/      home screen widgets and the Live Activity
Desktop/      the Mac and Windows installer, in Rust
Helper/       an older Mac pairing helper, kept for the QR import path
```

## A note on the developer disk image

The app ships a copy of Apple's developer disk image so a fresh install needs
no Mac to fetch one. That image is Apple's, not ours. If you publish builds of
Cloak, strip it and let `DeveloperImageFetcher` pull one at setup time instead.

## Where this stands legally and practically

Cloak simulates the location your own device reports. Use it on hardware you
own. Using it to deceive a person or a service that relies on your location may
break that service's terms, and in some places the law.

It is also worth being honest about what it cannot do. Anything that only reads
CoreLocation sees what Cloak says. Anything that cross-references Wi-Fi network
names, Bluetooth beacons, cell towers or the motion coprocessor does not, and
nothing running on the phone can change that. Find My, Snap Map and the like
read location. A bank, a rideshare or an insurer reads rather more.
