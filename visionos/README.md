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
2. Pick the immersion: Full (with or without your room around the menus),
   Progressive (a portal you widen with the Digital Crown), or Window (the game
   beside your other apps; see below).
3. Press Play. The game opens around you and the launcher goes away.
4. Press the Digital Crown to leave. The game saves and the app closes; open it
   again to play again.

With your room around the menus, every black screen shows your room instead:
menus, file select, Game Over, loading, and TP's fades to black, which cross
into the room. Hyrule also fades into the room if you walk more than about
1.2 m from where you started, standing in for visionOS's full-immersion
boundary. The game pauses while the headset is off.

### Window

Window plays Twilight Princess as the GameCube game, in third person, in a
window you can move and resize beside your other apps. visionOS gives an app no
head tracking outside a full space, so the VR mod is off there and you play with
a gamepad (DualSense, Xbox or another Bluetooth controller) or the two Sense
controllers held as one: right half Cross A, Circle B, R2 R, R1 Z, Options
Start; left half Square X, Triangle Y, L2 L (targeting); the D-pad is L1 up
(Midna), Create left (map), L3 down, R3 right. The picture isn't
flat: behind the window's glass, the game's own 3D scene is rebuilt every frame
(its models, textures and lighting, mirrored into RealityKit), so Hyrule has real
depth and holds up from any angle as you look and lean. The HUD and Dusklight's
menus sit on the glass. Characters cast their shadows. The game's screen effects
(bloom, mist, light shafts, fades and cutscene bars) are laid
over the scene, each glow on what it lights. Close the window to quit (the game
saves); the game pauses while the window is in the background.

Your saves live in the app's folder (Files › On My Apple Vision Pro › Twilight
Princess VR), next to the disc: copy them out to back them up. Deleting the app
deletes them.

### Controls

PS VR2 Sense controllers play TPVR's Touch layout. Bare hands play it too: index
pinch = trigger, middle = A/X, ring = B/Y, left little = menu, a fist = grip.
Hold the left hand's thumb-middle pinch and move the hand to walk (a quick tap
is still X); hold the right hand's thumb-little pinch and move it sideways to
turn.

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
- Window mode (`defaults write dev.tpvr.vision.simulator immersion window` in
  the Simulator, then `TPVR_AUTO_PLAY=1`): `TPVR_TEST_WINDOW_TILT=<degrees>`
  turns the window to show the relief from the side, `TPVR_TEST_WINDOW_LAYERS=p`
  or `=b` shows one relief layer, `TPVR_TEST_WINDOW_FLAT=1` lays the picture flat
  for comparison, and `TPVR_TEST_WINDOW_DUMP=<frame>` writes that frame's scene,
  distances, final image and (with the mirror) the scene before its screen effects
  raw into Documents. `TPVR_TEST_WINDOW_EFFECTS=0` leaves the screen effects out,
  `=ghost` shows the game's own picture in their layer at half opacity (one Link
  if the layer lines up with the mirror, two if not); `AURORA_MIRROR_GROUPS=1`
  (in a build with `-DDUSK_GFX_DEBUG_GROUPS=ON`) logs, per draw list, what the
  mirror kept and skipped. The scene mirror is the default;
  `TPVR_TEST_WINDOW_RELIEF=1` shows the relief instead,
  `TPVR_TEST_MIRROR_DUMP=<frame>` writes that mirror frame (vertices, indices,
  parts, textures) into Documents/mirror-dump, which
  `visionos/scripts/render-mirror-dump.py` renders from the game camera.

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
