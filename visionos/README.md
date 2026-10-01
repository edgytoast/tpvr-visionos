# TPVR for Apple Vision Pro

Twilight Princess in first person on Apple Vision Pro: Dusklight 2.0 with
JoeyAW's TPVR mod, built natively for visionOS and rendered in a fully immersive
space. See [PORT_PLAN.md](PORT_PLAN.md) for the design and progress.

You need your own Twilight Princess disc image: GameCube (GZ2E01, GZ2P01) or Wii
(any release except Korean), as `.iso`, `.rvz` or `.wbfs`. Dusklight runs the
GameCube code either way (the decompilation matches the GameCube release), so a
Wii disc plays as the GameCube version, left-handed Link included. Nothing from
the game is in this repository or the app.

## Build

Prerequisites (Apple Silicon Mac):

```bash
brew install cmake ninja xcodegen rustup
rustup toolchain install nightly --profile minimal
rustup target add --toolchain nightly aarch64-apple-visionos
```

Xcode with the visionOS SDK at `/Applications/Xcode.app` (CMake's Xcode lookup
breaks on paths with spaces).

```bash
visionos/scripts/bootstrap.sh                 # submodules + visionos/patches
visionos/scripts/build-visionos.sh --team TEAMID --install
```

- `--game-only` builds only `DusklightGame.framework` (no signing).
- `--bundle-id` overrides the default `dev.tpvr.vision.<TEAMID>`. Keep the team
  suffix: a bare ID may already belong to another team, and automatic signing
  then falls back to a wildcard profile without the memory entitlement.
- `--debug` builds Debug instead of RelWithDebInfo/Release.
- Build products and caches live in `.scratch/` (gitignored). Dawn is built once
  per revision by `visionos/scripts/build-dawn-visionos.sh`.

Homebrew's `rustup` is keg-only; the build script puts
`/opt/homebrew/opt/rustup/bin` on its own `PATH`.

## Play

1. AirDrop the disc image to the headset and open it with Twilight Princess VR,
   or put it in Files › On My Apple Vision Pro › Twilight Princess VR, or use
   Import Disc… in the app.
2. Pick the immersion: Full (with or without your room around the menus) or
   Progressive (a portal you widen with the Digital Crown).
3. Press Play. The game opens around you and the launcher goes away.
4. Press the Digital Crown to leave. The game saves and the app closes; open it
   again to play again.

With your room around the menus, Hyrule also fades into the room if you walk
more than about 1.2 m from where you started, standing in for visionOS's
full-immersion boundary.

### Controls

PS VR2 Sense controllers play TPVR's Touch layout. Bare hands play it too: index
pinch = trigger, middle = A/X, ring = B/Y, little = menu, a fist = grip. Hold the
left hand's thumb-middle pinch and move the hand to walk (a quick tap is still X).

Graphics options for Vision Pro are under VR › Vision Pro (anti-aliasing) and VR
› Performance (render resolution up to 150%).

### Testing in the Simulator

The app takes a few environment variables for headless runs (pass each as
`SIMCTL_CHILD_<NAME>` to `xcrun simctl launch`):

- `TPVR_AUTO_PLAY=1` presses Play.
- `TPVR_ARGS` adds Dusklight options, e.g. `--stage F_SP103` (Ordon Ranch).
- `TPVR_TEST_ACTIONS` scripts Sense controller input:
  `NAME[=x,y]@seconds[~duration]`, measured from the first input sync, e.g.
  `"MENU@30~0.3 B@45~0.3 LSTICK=0,1@50~2"`.
- `TPVR_GPU_TIMING=1` logs the compositor's GPU time every 240 frames (it
  includes waiting for the game's frame, so compare settings by difference).

## Layout

| Path | What |
| --- | --- |
| `visionos/App/` | SwiftUI app shell (xcodegen): launcher, immersive space, C bridge calls |
| `src/dusk/visionos/` | The game framework's C bridge (`visionos_host.h`) |
| `visionos/openxr-provider/` | OpenXR provider over CompositorServices + ARKit, vendored from WiiCompiled Vision (GPL-3.0) |
| `visionos/patches/aurora`, `visionos/patches/borealis` | visionOS changes to the two submodules |
| `visionos/patches/dawn` | Dawn source patches applied by the Dawn build |
| `visionos/scripts/` | bootstrap, Dawn build, full build |

The VR changes themselves are in `src/dusk/vr/` behind `DUSK_VR_XR_GRAPHICS_METAL`
(`vr_xr_bootstrap.hpp`, `vr_xr_submit.hpp`, `vr_main.cpp`).
