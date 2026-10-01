# TPVR for Apple Vision Pro

Twilight Princess in first person on Apple Vision Pro: Dusklight 2.0 with
JoeyAW's TPVR mod, built natively for visionOS and rendered in a fully immersive
space. See [PORT_PLAN.md](PORT_PLAN.md) for the design and progress.

You need your own GameCube Twilight Princess disc image (GZ2E01 or GZ2P01, `.iso`
or `.rvz`). Nothing from the game is in this repository or the app.

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
2. Press Play. The game opens around you.
3. Press the Digital Crown to leave. The game cannot restart in the same
   process; relaunch the app to play again.

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
