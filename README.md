# Acknowledgement Force

A daily contract for your Mac. Acknowledgement Force gates your screen behind
your own words: the window won't close until you've read today's contract,
ticked the box, and named the one thing that matters most. Free, open source,
and native to macOS.

![macOS](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-6-orange)

---

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon or Intel
- Xcode or the Command Line Tools (provides the `swift` compiler):

  ```sh
  xcode-select --install
  ```

## Install

Clone the repo and run the installer. It builds a release binary, packages it
into a native `Acknowledgement Force.app`, and installs it.

```sh
git clone https://github.com/Clupai8o0/force.git
cd force
./install.sh
```

By default the app is installed to `~/Applications` (no `sudo` needed) and
launches when the build finishes.

| Command | What it does |
| --- | --- |
| `./install.sh` | Install to `~/Applications` |
| `./install.sh --system` | Install to `/Applications` (prompts for `sudo`) |
| `./install.sh --prefix DIR` | Install into a custom directory |
| `./install.sh --no-open` | Don't launch the app after installing |
| `./install.sh --replace-others` | Remove copies in other locations without asking |
| `./install.sh --keep-others` | Leave copies in other locations in place |

`install.sh` is safe to re-run — it cleanly replaces any previous copy, so it
doubles as the upgrade path.

### No accidental duplicates

Before installing, the script checks the common locations (`~/Applications`,
`/Applications`) and anywhere it has installed before for an existing
`Acknowledgement Force.app` outside the current target. If it finds one — e.g.
you ran the default once and `--system` later — it offers to remove the stray
copy so you don't accumulate duplicates. In an interactive shell it asks;
otherwise pass `--replace-others` or `--keep-others` to decide up front.

Note that even if duplicate bundles exist on disk, the app enforces a
single-instance lock at runtime, so only one copy can ever actually run.

> The app is **ad-hoc signed** for local use. It is not notarized, so if you
> move the `.app` to another Mac, Gatekeeper may warn you. Building from source
> on the target machine (the steps above) avoids that.

## Usage

1. Launch **Acknowledgement Force** from Spotlight or Launchpad.
2. Read the day's contract, tick the acknowledgement box, and write your single
   highest-leverage action. The window stays locked until you do.
3. Once acknowledged, the gate opens and you can close the window.

### Auto-launch

Enable auto-launch from the app's onboarding screen or **Settings**. This
installs a user LaunchAgent (`~/Library/LaunchAgents/com.acknowledgementforce.agent.plist`)
so Force resurfaces on your chosen cadence:

| Frequency | Behaviour |
| --- | --- |
| Every launch | Re-acknowledge each time Force opens |
| Every hour | Re-locks one hour after each acknowledgement |
| Every 12 hours | Re-locks twelve hours after each acknowledgement |
| Once a day | One acknowledgement carries the whole day |
| Once a week | One acknowledgement carries the whole week |
| On login / restart | Re-acknowledge on every login and restart |

Your acknowledgement history is stored locally at
`~/Library/Application Support/Force/acknowledgements.log`.

### Make it stop

If you need to immediately quit the app and stop it from relaunching without a
full uninstall, run:

```sh
./stop.sh
```

## Uninstall

```sh
./uninstall.sh            # remove the app + auto-launch agent (keeps your data)
./uninstall.sh --purge    # also delete saved history and preferences
./uninstall.sh --system   # also look in /Applications
```

## Build from source (development)

```sh
swift build                 # debug build
swift run Force             # build & run
swift build -c release      # optimized release binary
```

The release binary and its resource bundle (`Force_Force.bundle`) land in the
directory printed by `swift build -c release --show-bin-path`.

## Project layout

```
Sources/Force/      SwiftUI app source + bundled fonts
landing/            Marketing site (static HTML/CSS/JS)
install.sh          Build + package + install the .app
uninstall.sh        Remove the app, agent, and (optionally) data
stop.sh             Quit now + disable auto-launch (no uninstall)
VERSION             Release version (drives the bundle version)
```

## Releasing

1. Bump `VERSION` (e.g. `0.2.0`).
2. Commit the change.
3. Tag and push:

   ```sh
   git tag -a "v$(cat VERSION)" -m "Release v$(cat VERSION)"
   git push origin "v$(cat VERSION)"
   ```

The version in `VERSION` is baked into the `.app` bundle's
`CFBundleShortVersionString` at install time.

## License

See repository for license details.
