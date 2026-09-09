# Server payload

What the licence server hands out, not what ships inside the app.

`DeveloperImage/` holds Apple's developer disk image: `Image.dmg`, its trust
cache, and the build manifest. iOS will not expose its location service until
that image is mounted, which is what makes the licence a dependency rather
than a switch. A copy of Cloak with every check torn out still has nothing to
simulate with.

Two consequences worth knowing:

- Apple's image is not redistributed inside the app, which is the right answer
  legally as well as commercially.
- The server must have these three files before anybody can finish setting
  Cloak up. `Scripts/upload-ddi.sh user@host` puts them there.
