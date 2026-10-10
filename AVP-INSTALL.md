# Twilight Princess VR on Apple Vision Pro: install guide

Ported to Apple Vision Pro by [Trevorbilt](https://trevorbilt.com).

Twilight Princess, natively on Apple Vision Pro. It's Dusklight (the Twilight Princess PC port,
built on the zeldaret decompilation) with JoeyAW's TPVR mod, built for visionOS. You can play:

- **Full immersion:** first person, standing in Hyrule. Your PS VR2 Sense controllers or your bare
  hands are Link's hands: swing the sword, raise the shield, aim the bow.
- **Progressive:** the same, through a portal you widen with the Digital Crown.
- **Window:** the GameCube game in third person, in a window beside your other apps, played with a
  gamepad. The game's 3D scene is rebuilt inside the window, so it has real depth from any angle.

This repository contains no game data. You need your own copy of the game, and you build the app
yourself with Xcode and install it on your own headset.

## Requirements

- **Your own copy of Twilight Princess** on GameCube or Wii (see Game files).
- **An Apple Silicon Mac** with about 15 GB free (the first build compiles Google's Dawn graphics
  library, which takes up to an hour; later builds take minutes).
- **Xcode with the visionOS SDK**, installed at `/Applications/Xcode.app` (the path must not contain
  a space). Built and tested with Xcode 27 on macOS 27.
- **Homebrew**, from https://brew.sh.
- **Apple Vision Pro** with visionOS 26 or later, Developer Mode on, paired with your Mac (below).
  Tested on visionOS 27.
- **An Apple ID signed in to Xcode** (Xcode > Settings > Accounts). The app asks for the
  increased-memory-limit entitlement. It has been built with a paid Apple Developer Program team;
  whether a free personal team can sign it is untested.
- Optional: PlayStation VR2 Sense controllers, or a Bluetooth gamepad for Window mode.

## Game files

You supply your own game; this repository contains none.

1. Dump your own disc as `.iso`, `.rvz` or `.wbfs`. Dolphin's guide explains how:
   https://wiki.dolphin-emu.org/index.php?title=Ripping_Games
2. Use a supported release: GameCube GZ2E01 (USA), GZ2P01 (Europe) or GZ2J01 (Japan), or any Wii
   release except the Korean one. Dolphin shows a disc's game ID in its game list. A Wii disc plays
   as the GameCube version, which the decompilation matches.
3. After installing the app (below), put the disc image on the headset: AirDrop it and open it with
   Twilight Princess VR, copy it to Files > On My Apple Vision Pro > Twilight Princess VR, or use
   Import Disc in the app. The app uses the newest disc image in that folder.

## Build

Start in a checkout of this repository, with its submodules (the index's clone command does this;
otherwise `git submodule update --init --recursive`).

1. Install the build tools, once:

   ```bash
   brew install cmake ninja xcodegen rustup
   export PATH="$(brew --prefix rustup)/bin:$PATH"
   rustup toolchain install nightly-2026-09-30 --profile minimal
   rustup target add --toolchain nightly-2026-09-30 aarch64-apple-visionos
   ```

   Homebrew installs `rustup` keg-only, off your `PATH`, so the `export` line puts it there for
   the next two commands (the build script finds it on its own). The Rust nightly is pinned to
   the one this port is built and tested with.

2. Prepare the checkout. This fetches the two graphics submodules at their pinned commits and
   applies this port's patches to them:

   ```bash
   visionos/scripts/bootstrap.sh
   ```

3. Find your team ID: the 10-character ID shown for your team in Xcode > Settings > Accounts, or the
   "OU" in your Apple Development certificate (Keychain Access).

## Install on Apple Vision Pro

1. On the headset, turn on Developer Mode: Settings > Privacy & Security > Developer Mode (it
   restarts).
2. Pair it with your Mac: open Xcode > Window > Devices and Simulators, then on the headset open
   Settings > General > Remote Devices and pick your Mac. Keep the headset on and unlocked while
   installing.
3. Build and install:

   ```bash
   visionos/scripts/build-visionos.sh --team YOURTEAMID --install
   ```

   The bundle ID is `dev.tpvr.vision.YOURTEAMID`. Keep the team suffix: a bare ID can belong to
   someone else's team, and signing then fails on the memory entitlement. With several headsets,
   add `--device <UDID>`.

4. If visionOS says the developer isn't trusted, allow it in Settings > General > VPN & Device
   Management. Apps signed with a free personal team stop opening after 7 days until you build and
   install again.

## Update

The index's clone command checks out the exact commit it reviewed, so the checkout isn't on a branch
and `git pull` has nothing to pull into. To move to the newest code, then rebuild:

```bash
git fetch origin
git checkout visionos
git pull
visionos/scripts/bootstrap.sh --reset
visionos/scripts/build-visionos.sh --team YOURTEAMID --install
```

`bootstrap.sh --reset` puts the two graphics submodules back at their pinned commits and applies this
port's patches again, which an update that changes a patch needs. The build checks this and stops
with that command if the submodules don't match their pinned commits plus the patches. Your disc
and saves stay on the headset.

## Play

1. Open Twilight Princess VR, choose how to play (Full, Progressive or Window) and press Play. The
   launcher's Controls tab shows every button and gesture for what you're holding.
2. In Full or Progressive, press the Digital Crown to pause. The game holds where you are, and the
   launcher offers Resume or Quit (if it doesn't appear, open the app from Home). In Window, close
   the window to quit. The game autosaves when you enter a new area or open a dungeon door
   (Settings > Gameplay > Autosave, on by default), so quitting loses only what you've done since
   then.

Saves live next to the disc image in Files > On My Apple Vision Pro > Twilight Princess VR. iCloud
Backup includes the saves but leaves out the disc image, which you can always copy in again. Copy
the saves out to keep your own backup; deleting the app deletes them.

### Controls

- **Sense controllers:** TPVR's controller layout (the sword follows your right hand, the shield
  your left).
- **Bare hands:** index pinch is the trigger, middle pinch A/X, ring pinch B/Y, left little-finger
  pinch the menu, a fist the grip. Hold the left thumb-middle pinch and move your hand to walk; hold
  the right thumb-little pinch and move it sideways to turn.
- **Window mode:** a gamepad (whenever one is on, it plays), or both Sense controllers held as one pad: right half Cross A,
  Circle B, R2 R (shield), R1 Z (Midna), Options Start; left half Square X, Triangle Y, L2 L
  (targeting); D-pad on L1 (up, item ring), Create (left, map), L3 (down, item ring) and R3
  (right, map). Close the window to quit.
- Vision Pro options are in the game's VR menu: VR > Vision Pro (anti-aliasing) and VR >
  Performance (render resolution up to 150%).

### Known issues

- Window mode is newer than the immersive modes: characters look a little flatter and darker
  than in the game, and the game's bloom and mist aren't drawn in it.
- The first build takes up to an hour (it compiles Dawn); later builds take minutes.

## Troubleshooting

- **CMake can't find Xcode:** Xcode must be at `/Applications/Xcode.app`, not a path with a space.
- **The install hangs:** wake and unlock the headset, then run the build command again.
- **Signing fails on the memory entitlement:** keep the team suffix on the bundle ID (the
  default); a bare ID may already belong to another team.

More detail on the design, the test hooks and what has been verified is in
[visionos/README.md](visionos/README.md) and [visionos/PORT_PLAN.md](visionos/PORT_PLAN.md).

## Credits and licences

- The Apple Vision Pro port by [Trevorbilt](https://trevorbilt.com) (@edgytoast).
- [Dusklight](https://twilitrealm.dev/) by the Twilit Realm team, built on the
  [Twilight Princess decompilation](https://github.com/zeldaret/tp) by zeldaret (both CC0-1.0).
- [TPVR](https://github.com/JoeyAW/TPVR), the VR mod, by JoeyAW.
- [Aurora](https://github.com/encounter/aurora), the GameCube/Wii graphics layer, by encounter (MIT).
- The visionOS OpenXR provider from [WiiCompiled Vision](https://github.com/iChris4/Wiicompiled_VR)
  (GPL-3.0-or-later), so the built app is GPL-3.0.

Twilight Princess is Nintendo's. This project isn't affiliated with or endorsed by Nintendo. None of
the game's files are in the app or the repository, which has only screenshots of it.
