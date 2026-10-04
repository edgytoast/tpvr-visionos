# Twilight Princess VR for Apple Vision Pro

**By [trevorbilt](https://trevorbilt.com)** · [Install guide](AVP-INSTALL.md) · [Support trevorbilt](https://trevorbilt.com)
<!-- Buy Me a Coffee: add the link here, next to trevorbilt.com, once it exists. -->

Twilight Princess, natively on Apple Vision Pro. Stand in Hyrule with your PlayStation VR2 Sense
controllers or your bare hands as Link's hands, step in through a portal you widen with the
Digital Crown, or play the GameCube game in a window beside your other apps, with real 3D depth.

> This repository contains no game data. Bring your own copy of Twilight Princess (GameCube or
> Wii) and build the app yourself: [AVP-INSTALL.md](AVP-INSTALL.md) walks through it.

## Ways to play

- **Full immersion.** First person at life scale. Swing the sword, raise the shield and aim the bow
  with your hands or Sense controllers; walk and turn with a gamepad-style stick or hand gestures.
  Menus, loading and black screens can float in your room instead of the void, and the game fades
  into your room if you walk too far from where you started.
- **Progressive.** The same game through a portal in your room; turn the Digital Crown to widen it.
- **Window.** The GameCube game in third person, in a window you move and resize beside other
  apps, played with a gamepad or both Sense controllers held as one. Behind the window's glass the
  game's own 3D scene is rebuilt every frame, so Hyrule holds up from any angle as you lean and
  look; the HUD sits on the glass, and the game's bloom, mist and fades are laid over the scene.

## Get it running

You need an Apple Silicon Mac with Xcode, your own disc image (`.iso`, `.rvz` or `.wbfs`), and an
Apple Vision Pro in Developer Mode. One script builds everything and installs it on the headset:

```bash
visionos/scripts/bootstrap.sh
visionos/scripts/build-visionos.sh --team YOURTEAMID --install
```

Requirements, game files, pairing, controls and troubleshooting: [AVP-INSTALL.md](AVP-INSTALL.md).

## How it works

- **The game** is Dusklight (Twilight Princess on PC, built on the zeldaret decompilation) with
  JoeyAW's TPVR VR mod, compiled for visionOS as a framework the SwiftUI app runs behind a small C
  bridge.
- **The headset path:** TPVR's OpenXR layer talks to a visionOS OpenXR provider (from WiiCompiled
  Vision) built on CompositorServices and ARKit. The game renders with Metal straight into the
  compositor's images, in a full, mixed or progressive immersive space.
- **The window:** the GameCube graphics stream is decoded on the CPU as the game draws, each draw's
  material reduced to what RealityKit can render, and the scene rebuilt as one RealityKit mesh per
  frame behind a portal. Screen effects come across as a separate layer, each glow at the depth of
  what it lights.

Design notes, decisions and measurements: [visionos/README.md](visionos/README.md) and
[visionos/PORT_PLAN.md](visionos/PORT_PLAN.md).

## How it was built

Built by trevorbilt with Claude Code as an AI pair programmer; every commit is co-authored. Each
change was measured (frame times, GPU cost), checked in the visionOS Simulator, where window
frames were rendered offline and compared with the game's own picture, and tested on Apple Vision
Pro at each milestone, with an independent review agent checking the larger builds before they
reached the headset.

## Lineage and credits

This port stands on years of work by others:

- **[TPVR](https://github.com/JoeyAW/TPVR)** by JoeyAW, the VR mod this port is built on (PC VR on
  Windows). Support JoeyAW: [Patreon](https://www.patreon.com/cw/JoeyAW) ·
  [Discord](https://discord.gg/CxQJ9PjnjA).
- **[Dusklight](https://twilitrealm.dev/)** by the Twilit Realm team and its
  [contributors](https://github.com/TwilitRealm/dusklight/graphs/contributors): Twilight Princess
  on PC. Dusklight's official website is twilitrealm.dev.
- **[The Twilight Princess decompilation](https://github.com/zeldaret/tp)** by zeldaret, and the
  GameCube and Wii decompilation community.
- **[Aurora](https://github.com/encounter/aurora)** by encounter, the GameCube and Wii graphics layer.
- **[WiiCompiled Vision](https://github.com/iChris4/Wiicompiled_VR)** by iChris4, the source of the
  visionOS OpenXR provider.
- TPVR also thanks [Automata](https://github.com/automata-rtx/dusklight-mods) and the
  [TP speedrunning community](https://zsrtp.link).

For PC VR on Windows, use JoeyAW's [TPVR](https://github.com/JoeyAW/TPVR) itself.

## Licence

Dusklight, the decompilation and TPVR are CC0-1.0 ([LICENSE.md](LICENSE.md)). The vendored OpenXR
provider is GPL-3.0-or-later ([visionos/openxr-provider/LICENSE](visionos/openxr-provider/LICENSE)),
so the built app is GPL-3.0. Twilight Princess is Nintendo's; this project isn't affiliated with
or endorsed by Nintendo and includes nothing from the game.

---

Made by [trevorbilt](https://trevorbilt.com) · [admin@trevorbilt.com](mailto:admin@trevorbilt.com)
