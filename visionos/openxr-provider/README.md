# visionOS OpenXR provider (vendored)

visionOS ships no OpenXR runtime and no loader. This library implements the
OpenXR 1.0 entry points TPVR's VR layer calls (`src/dusk/vr/`) on top of
CompositorServices (frames, drawables, the compositor) and ARKit (the device
pose, the hands), and is linked in place of the Khronos loader.

It is vendored unchanged from WiiCompiled Vision:

- Source: `runtime/src/vr/visionos/` and `runtime/include/vr/visionos/xr_visionos.h`
  in [iChris4/Wiicompiled_VR](https://github.com/iChris4/Wiicompiled_VR), branch `vision-pro`.
- Commit: see `UPSTREAM_COMMIT` (the last commit that touched these files).
- Licence: GPL-3.0-or-later (`LICENSE`). Linking it makes the built app
  GPL-3.0; TPVR and Dusklight are CC0, which is compatible.

Keep local changes small and note them here, so fixes can flow both ways.

## What TPVR uses from it

| TPVR | Provider |
| --- | --- |
| `xrCreateInstance`, `xrGetSystem`, `xrCreateSession` with `XrGraphicsBindingMetalMKW` | `xr_visionos_runtime.mm` |
| `xrWaitFrame` / `xrBeginFrame` / `xrLocateViews` / `xrEndFrame` | `xr_visionos_runtime.mm`, `xr_visionos_compositor.mm` |
| Swapchains: `XrSwapchainImageMetalMKW` (IOSurface + MTLTexture), MTLSharedEvent fences | `xr_visionos_runtime.mm`, `xr_visionos.h` |
| Actions (grip/aim poses, buttons, sticks, haptics) from PS VR2 Sense controllers when held, else from the ARKit hand skeletons | `xr_visionos_input.mm`, `xr_visionos_controllers.mm` |
| `XR_EXT_hand_tracking` | `xr_visionos_hand_tracking.mm` |

Only `xrInitializeLoaderKHR` is missing, and TPVR calls it on Android only.

## Local changes

- **PS VR2 Sense controllers** (`src/xr_visionos_controllers.mm`, new; hooks in
  `xr_visionos_input.mm`'s `SyncActions`, the action-state getters,
  `LocateActionSpaceInWorld` and `ApplyHapticFeedback`; declarations at the end of
  `xr_visionos_internal.h`). Adapted from SHAR VR's `visionos_controllers.mm`.
  While a hand holds a Sense half, that hand's Touch bindings (buttons, triggers,
  grip, thumbstick), grip and aim poses (ARKit accessory tracking, predicted to
  display time) and haptics come from the controller; otherwise from the hand
  skeleton as before. Worth upstreaming to WiiCompiled Vision.
