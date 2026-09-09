# Cloak Installer

Puts Cloak on your iPhone without the App Store, and keeps it there.

## What it does

1. Finds your iPhone over the cable.
2. Turns on Developer Mode for you, including making the switch appear in
   Settings in the first place. iOS hides it until a computer asks.
3. Signs Cloak with your own Apple ID. A free one is fine.
4. Installs it, and hands it the pairing key so the app needs no setup of its
   own — no six digit code, no restarts.
5. Optionally renews the signature every few days on its own, because Apple's
   free signature only lasts seven.

Your Apple ID password is sent to Apple and nowhere else. It is only written
down at all if you ask for automatic renewal, and then it goes into the
operating system's keychain, not into a file.

## Before you start

**macOS** — nothing. Plug the phone in.

**Windows** — install iTunes from apple.com, not the Microsoft Store version.
The installer only needs the iPhone driver that comes with it; it never opens
iTunes. If the installer says it cannot find the driver, that is what is
missing.

Your iPhone needs to trust this computer. Unlock it and tap Trust when asked.

## After it finishes

Cloak needs one free app from the App Store, LocalDevVPN, to loop a connection
back to the phone. Apple does not let a free developer account sign the piece
of software that would do that inside Cloak itself, which is the whole reason
that app exists. Install it, open it once, switch it on, and you are done.

## Renewal

Apple's free signature lasts seven days. Turn on automatic renewal at the end
and this computer re-signs Cloak every few days, quietly, as long as the phone
is plugged in or has been recently. Nothing is lost when it renews: your places,
routes and recordings stay where they are.

If you would rather not store the password, leave renewal off and run the
installer again once a week. It takes about a minute the second time.

## Running it by hand

    cloak-installer            open the window
    cloak-installer --refresh  renew if the signature is nearly out, then quit
    cloak-installer --force    renew now, whatever the state
    cloak-installer --ipa PATH use a different Cloak app file
