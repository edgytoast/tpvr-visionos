# TPVR on Apple Vision Pro: port plan

Goal: TPVR (Dusklight 2.0 + JoeyAW's first-person VR mod: sword swings, shield,
aimed bow and clawshot) running natively on Apple Vision Pro in a fully
immersive space, played with bare hands (ARKit hand tracking) or PS VR2 Sense
controllers.

This branch (`visionos`) is a fork of [JoeyAW/TPVR](https://github.com/JoeyAW/TPVR)
(CC0). `upstream` is fetch-only; its push URL is disabled.

## What it reuses

| Piece | From | Why it fits |
| --- | --- | --- |
| OpenXR provider over CompositorServices + ARKit | WiiCompiled Vision (`runtime/src/vr/visionos`, GPL-3.0-or-later), vendored in `visionos/openxr-provider/` | TPVR's VR layer is written against OpenXR. The provider answers the ~45 `xr*` calls it makes and serves hand joints as `XR_EXT_hand_tracking`. |
| App shell pattern | WiiCompiled Vision (`visionos/App`, `visionos_host.mm`) | SwiftUI owns `main()`; the game is a static library on its own thread, started once the CompositorLayer exists. SDL runs on its offscreen video driver. |
| aurora visionOS changes | WiiCompiled Vision's aurora | Offscreen SDL window, detached CAMetalLayer, frame worker on, Metal sharing features. Re-applied to TPVR's aurora as `visionos/patches/aurora/`. |
| Dawn build for xrOS | `visionos/scripts/build-dawn-visionos.sh` | No visionOS Dawn prebuilt exists. Built at aurora's pinned `AURORA_DAWN_REF`, with the BC-format fix in `visionos/patches/dawn/`. |
| visionOS CMake and UIKit-side fixes | rebelancap/dusklight-ios (CC0), for Dusklight 1.4 | A map of what Dusklight needs on visionOS; re-derived against 2.0 rather than applied. |

Licence note: linking the GPL-3.0 provider makes the built app GPL-3.0. TPVR and
Dusklight are CC0, which is compatible.

## Architecture

```
SwiftUI App (main thread)
  ├─ Launcher window: disc import, settings, Play
  └─ ImmersiveSpace ─ CompositorLayer ─▶ xr_visionos_set_layer_renderer()
Game thread (pthread, large stack)
  └─ Dusklight main loop (SDL offscreen, aurora on Dawn/Metal)
       └─ dusk::vr::tick()  ── OpenXR ──▶ visionOS provider
            ├─ xrWaitFrame/BeginFrame/EndFrame  → cp_frame_*, device anchor
            ├─ swapchain images = IOSurface + MTLTexture (XrSwapchainImageMetalMKW)
            │    Dawn imports each IOSurface (SharedTextureMemoryIOSurface),
            │    waits on the compositor's MTLSharedEvent, copies the eye in,
            │    hands back its own MTLSharedEvent (xr_visionos_swapchain_image_*_fence)
            └─ actions + XR_EXT_hand_tracking  → ARKit hand skeletons / Sense controllers
```

TPVR's VR code has two graphics branches today, D3D12 (PC) and Vulkan (Quest),
in `src/dusk/vr/vr_xr_bootstrap.hpp` and `vr_xr_submit.hpp`. visionOS adds a
third, `DUSK_VR_XR_GRAPHICS_METAL`, modelled on the Quest branch: the XR runtime
owns the swapchain images and Dawn imports them.

## Phases

### 0. Toolchain
- [x] Clone, `visionos` branch, fetch-only upstream; aurora submodule from JoeyAW/aurora-vr (the pinned commit is not on encounter/aurora).
- [x] Dawn for xrOS: `visionos/scripts/build-dawn-visionos.sh`, patch 0001 (BC formats).
- [x] Rust nightly + `aarch64-apple-visionos` via Homebrew `rustup` (nod, the disc reader, has no visionOS prebuilt).

### 1. Flat build
- [x] CMake: visionOS platform; code mods off (symgen cannot read xrOS); the game is `DusklightGame.framework` exporting only the C bridge; host packages (Homebrew, Conda) excluded.
- [x] aurora patches: offscreen SDL, detached CAMetalLayer, no SDL `main`, Metal sharing features, SDL virtual joystick. borealis: Documents data path, no file dialogs.
- [x] `DusklightGame.framework` links for `xros` and the Simulator (44 MB, exports only the 9 bridge functions).
- [x] Signed app (`dev.tpvr.vision.<TEAM>`, increased-memory-limit) installed on the headset, 2026-09-30.
- [x] Simulator run (visionOS 27): app, framework, game thread, SDL offscreen, Dawn Metal device with
      SharedTextureMemoryIOSurface + SharedFenceMTLSharedEvent, RmlUi fonts, frames. Stops at Dusklight's
      disc picker without a disc; TPVR's VR startup runs from the main game loop, so it needs the disc.

### 2. VR on Metal
- [x] Vendor the provider; CMake branch in the VR fragment for visionOS.
- [x] `vr_xr_bootstrap.hpp`: Metal branch (instance, system, session with `XrGraphicsBindingMetalMKW`).
- [x] `vr_xr_submit.hpp`: Metal branch (IOSurface import, MTLSharedEvent fences both ways, no CPU fallback). `vr_stereo_render.hpp` needed nothing. `vr_main.cpp`: Metal startup and present suppression.

### 3. App shell
- [x] SwiftUI launcher + ImmersiveSpace + CompositorLayer; C bridge (disc path, layer renderer, spatial events, start, quit).
- [x] Disc import into Documents (Import Disc…, AirDrop "Open with", Files); passed to the game as `--dvd`.

### 4. Hands
- [ ] Bare hands: fist = sword grip, swing detector on the grip pose, left hand shield, bow with two hands, pinch variants for buttons.
- [ ] Walking without a thumbstick: an off-hand hold-to-walk gesture (see illixion's RAVEInput, MIT).
- [ ] PS VR2 Sense controllers as a first-class alternative.

### 5. On the headset (needs the user's disc)
- [ ] First light, frame pacing, comfort, gesture thresholds.
