# visionOS OpenXR provider (vendored)

visionOS ships no OpenXR runtime and no loader. This library implements the
OpenXR 1.0 entry points TPVR's VR layer calls (`src/dusk/vr/`) on top of
CompositorServices (frames, drawables, the compositor) and ARKit (the device
pose, the hands), and is linked in place of the Khronos loader.

It is vendored from WiiCompiled Vision and modified for Twilight Princess VR:

- Source: `runtime/src/vr/visionos/` and `runtime/include/vr/visionos/xr_visionos.h`
  in [iChris4/Wiicompiled_VR](https://github.com/iChris4/Wiicompiled_VR), branch `vision-pro`.
- Commit: see `UPSTREAM_COMMIT` (the last commit that touched these files).
- Licence: GPL-3.0-or-later (`LICENSE`). Linking it makes the built app
  GPL-3.0; TPVR and Dusklight are CC0, which is compatible.

As GPL-3.0 section 5(a) asks, every upstream file changed here says so at its top
("Modified by Trevorbilt, 2026"), and the changes are listed with their dates
below. Keep local changes small and list them there, so fixes can flow both ways.

## What TPVR uses from it

| TPVR | Provider |
| --- | --- |
| `xrCreateInstance`, `xrGetSystem`, `xrCreateSession` with `XrGraphicsBindingMetalMKW` | `xr_visionos_runtime.mm` |
| `xrWaitFrame` / `xrBeginFrame` / `xrLocateViews` / `xrEndFrame` | `xr_visionos_runtime.mm`, `xr_visionos_compositor.mm` |
| Swapchains: `XrSwapchainImageMetalMKW` (IOSurface + MTLTexture), MTLSharedEvent fences | `xr_visionos_runtime.mm`, `xr_visionos.h` |
| Actions (grip/aim poses, buttons, sticks, haptics) from PS VR2 Sense controllers when held, else from the ARKit hand skeletons | `xr_visionos_input.mm`, `xr_visionos_controllers.mm` |
| `XR_EXT_hand_tracking` | `xr_visionos_hand_tracking.mm` |

Only `xrInitializeLoaderKHR` is missing, and TPVR calls it on Android only.

## Changes from upstream

By Trevorbilt. Dates are when each change was committed to this repo; the commits
are in its history. Files are under `src/` unless shown otherwise.

| Date | Change | Files |
| --- | --- | --- |
| 2026-09-30 | PS VR2 Sense controllers as the Touch controllers' actions, grip and aim poses and haptics (details below). | `xr_visionos_controllers.mm` (new), `xr_visionos_input.mm`, `xr_visionos_internal.h` |
| 2026-10-01 | Sense controllers follow TPVR's Sword Hand setting; scripted controller input for headless tests. | `xr_visionos_controllers.mm` |
| 2026-10-01 | Progressive immersion: layered drawables drawn in one render pass that the system's render context finishes (the portal's edge), with a device anchor on every present. | `xr_visionos_compositor.mm`, `xr_visionos_internal.h`, `xr_visionos_runtime.mm` |
| 2026-10-01 | Anti-aliasing on projection layers: FXAA in the compositor's shader, or SMAA 1x on the eye images (SMAA by default); optional GPU timing log. | `xr_visionos_compositor.mm`, `xr_visionos_smaa.mm` (new), `smaa/` (from the SHAR port, MIT), `include/vr/visionos/xr_visionos.h` |
| 2026-10-01 | The room around menus: see-through layers, empty frames that ease from black to the room, fades to black that cross into the room (`xr_visionos_set_frame_opacity`), and a safety boundary that fades Hyrule into the room past about 1.2 m. | `xr_visionos_compositor.mm`, `xr_visionos_internal.h`, `xr_visionos_runtime.mm`, `include/vr/visionos/xr_visionos.h` |
| 2026-10-01 | Foveated rendering: every pass draws through the drawable's rasterization rate map. | `xr_visionos_compositor.mm` |
| 2026-10-01 | Bare-hand walking and turning: pinch clutches as the sticks. | `xr_visionos_input.mm` |
| 2026-10-06 | Frames: a frame without a drawable is dropped, not ended; the drawable comes from the single-drawable query (as in the SHAR port), not the first of `cp_frame_query_drawables`; each drawable gets a device anchor of its own. | `xr_visionos_compositor.mm`, `xr_visionos_internal.h` |
| 2026-10-06 | Bare hands predicted to the frame's display time in `xrSyncActions`. | `xr_visionos_input.mm` |
| 2026-10-06 | Hand tracking in its own ARKit session, with provider state changes logged. | `xr_visionos_compositor.mm`, `xr_visionos_internal.h` |

## Local additions in detail

- **PS VR2 Sense controllers** (`src/xr_visionos_controllers.mm`, new; hooks in
  `xr_visionos_input.mm`'s `SyncActions`, the action-state getters,
  `LocateActionSpaceInWorld` and `ApplyHapticFeedback`; declarations at the end of
  `xr_visionos_internal.h`). Adapted from SHAR VR's `visionos_controllers.mm`.
  While a hand holds a Sense half, that hand's Touch bindings (buttons, triggers,
  grip, thumbstick), grip and aim poses (ARKit accessory tracking, predicted to
  display time) and haptics come from the controller; otherwise from the hand
  skeleton as before. Worth upstreaming to WiiCompiled Vision.
