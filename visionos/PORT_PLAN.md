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

### 4. Hands and controllers
- [x] PS VR2 Sense controllers, first class: ARKit accessory tracking for grip and aim poses (predicted to display time), buttons, sticks, triggers, haptics (`xr_visionos_controllers.mm`).
- [x] Walking without a thumbstick: the left hand's held thumb-middle pinch is a joystick (the walk clutch, after illixion's RAVEInput); a quick tap still presses X. Needs tuning on the headset.
- [x] Bare-hand turning: the right thumb-little pinch (unused by TPVR), held and moved sideways, is the right stick's x.

### 5. On the headset
- [x] First light, 2026-09-30: VR, the right Sense controller, gameplay. "Works perfectly."
- [ ] Frame pacing and GPU headroom at higher render scales; comfort.

### 6. Vision Pro features (2026-10-01)
- [x] Sword hand: VR > Combat > Sword Hand, Right (default) or Left (Original). Same stored key as the old swap toggle.
- [x] The launcher closes once the game opens; a clean quit (Digital Crown, or Quit) ends the app, so opening it again starts fresh.
- [x] Immersion, chosen in the launcher (visionOS takes a space's style when it opens and ignores later changes, which the Simulator confirmed):
  - Full, with "Show my room around menus" (default): a mixed space with opaque game frames. Dusklight's menus and TP's full-screen ones (Collection, maps, save, options, letters, fishing journal, skills, bugs; not the item ring) float in the room with Hyrule hidden behind them. The provider adds the movement boundary a mixed space lacks: Hyrule fades into the room from 1.2 m to 1.6 m away from where you started.
  - Full without it: a full space, as before.
  - Progressive (visionOS 26): Hyrule through a portrait portal; the Digital Crown widens or narrows it. The layer is layered and the provider draws both eyes in one render pass, which the system's render context finishes with the portal's edge. A portal shows black where frames are transparent, so menus there stay as they were.
- [x] Anti-aliasing: VR > Vision Pro > Anti-Aliasing, Off / FXAA / SMAA (default), live. Measured in the Simulator (`TPVR_GPU_TIMING=1` logs the compositor's GPU time): FXAA costs nothing measurable, SMAA about 1.3 ms on 7680x2160 eyes, so well under 1 ms on the headset's 3776x1792. FXAA runs in the compositor's shader; SMAA 1x (from the SHAR port) on the eye image first.
- [x] Render quality: VR Render Resolution reaches 150% on Vision Pro (supersampling), capped to the runtime's largest image.
- [x] PC-only settings (VR brightness sliders, desktop mirror) hidden on Vision Pro, as on Quest.
- [x] Opaque layers composite with alpha 1 (OpenXR semantics); TPVR's eye images carry undefined alpha.
- [x] Two immersive spaces (full/mixed, and progressive): a space that lists the progressive style makes every drawable require the system's render context, which crashed Full on the headset (fixed 2026-10-01).
- [x] The room behind every black screen (room option on): TP's full-screen menus, file select (load, name entry, brightness check), Game Over, loading frames (held black 0.25 s after game content, then eased in), and TP's fades to black, which crossfade into the room (frame opacity = 1 - fade rate).
- [x] Direct render: the eye pass draws straight into the provider's IOSurface (no gamma pass or copy when the hand-off is an identity). Simulator: the compositor's GPU wait fell from ~21 ms to ~4.5 ms. `TPVR_COPY_EYES=1` restores the copy.
- [x] The game clock holds while the session isn't focused (headset off, visionOS UI over the game): `aurora_set_external_pause`.
- [x] Headless test hooks: `TPVR_AUTO_PLAY=1`, `TPVR_ARGS` (Dusklight options such as `--stage F_SP103`), `TPVR_TEST_ACTIONS` (scripted Sense controller input). Pass them as `SIMCTL_CHILD_*` to `xcrun simctl launch`.

### 7. Window mode (2026-10-01)
- [x] Immersion: Window. A shared-space window (a WindowGroup with a RealityView), third person,
      gamepad. The game plays flat (VR startup skipped) and is paced by the window's RealityKit
      updates. Before and after its HUD it snapshots the scene, its depth (as distances) and the
      finished frame into IOSurfaces (src/dusk/visionos/visionos_window.cpp: Dawn encoder tasks,
      SharedTextureMemory, an MTLSharedEvent the app waits on, four slots handed over by serial).
- [x] The app turns them into a relief behind a portal (GameWindowView.swift, after the SHAR port's
      relief window, single view): a 216-row grid placed along each pixel's ray at its distance,
      cut where neighbouring pixels jump in depth by a visible amount, with a backstop that
      continues the background behind foreground objects (borrowed from just past the nearest
      depth jump) for when you look in from the side. Depth is capped at 3 window widths, and
      telephoto shots are laid out for a normal viewing distance. The HUD (what the 2D pass
      changed) and Dusklight's menus sit flat on the glass.
- [x] Simulator: title attract, Ordon gameplay, straight on and at 15/35 degrees. Headset: untried.
- [x] The scene mirror, as SHAR's window (the user's call: the relief's disocclusion smears are why
      SHAR built one). aurora records every perspective draw of the 3D scene between two in-stream
      marks (extern/aurora/lib/gx/mirror.cpp, GXAuroraMirrorMark) and decodes it on its FIFO
      thread as the generated shaders would: vertices from the raw GX data, matrices, both colour
      channels lit by GX's lights, the primary texture's texgen, fog per vertex, and the TEV run
      with that texture's sample as an unknown, so each vertex carries colour = T x mul + add.
      Other textures stand in as their average; draws sampling only framebuffer copies (bloom,
      refraction, haze) are skipped. Triangles are clipped to the camera's near plane and view
      (40% margin), the sky pushed behind the level, geometry nearer than the glass (0.85 x the
      camera's focus) moved onto it along its sight line after subdividing it (no streaks).
      MirrorScene.swift rebuilds one LowLevelMesh a frame with a part per material (ShaderGraph,
      generated: visionos/scripts/gen-mirror-materials.py); the portal clips at the glass; the HUD
      still comes from the frames. The relief stays as the fallback (TPVR_TEST_WINDOW_RELIEF=1).
- [x] Simulator: Ordon and Faron Woods match the game's picture straight on and stand in depth at
      25 degrees; ~290 draws, ~71k vertices, ~9.4 ms of FIFO-thread time a frame, game at 60 fps.
      Headset: untried.
- [x] Decoding on worker threads (the FIFO thread snapshots each draw; END merges in order):
      FIFO-thread time in Ordon ~10.6 -> ~3.2 ms a frame.
- [x] No z-fighting: decals and second passes nudged nearer, every draw a hair nearer than the
      ones before (SHAR's rules); near geometry keeps its order in a 3% band behind the glass.
- [x] Character shadows: the shadow masks (framebuffer copies sampled through their alpha) read
      back from the GPU each frame (256x256, swizzled as the TEV reads them), a frame late.
- [x] Refracting surfaces (an opaque draw sampling a framebuffer copy) are see-through: the copy
      is a second unknown in the TEV, its weight the transparency. TP has none in the areas tested:
      its water is textured geometry, and where a spring has a layer drawn from a screen copy
      (Ordon Spring, the Lost Woods: the invisible list, blended), that copy is read back like the
      shadow masks (in-scene colour copies too, now) and drawn as the game draws it.
- [x] Sense controllers in the window, as one SDL virtual gamepad (visionos_sense_pad.mm).
      Untested: the Simulator has no Sense controllers.
- [x] Screen effects as a layer. The painter calls window::scene_drawn() once the 3D world is
      drawn (after its particles): the mirror's frame ends there and the picture so far is kept
      (the "base"). Everything after it (bloom, the heat/scent distortion pass, lens flare, cloud
      shadows, the depth of field, moved after it in window mode, the targeting arrow, letterbox
      bars, fades) is what turned base into the scene snapshot taken before the HUD; per pixel,
      scene = base x (1 - a) + e with the least cover a that keeps e non-negative (WindowHud,
      linear): a glow only adds light, a fade only covers, and straight on the window matches the
      game. Pure darkening (fades, letterbox bars) dims the glass with the HUD; the rest is a grid
      mesh with each vertex at the depth of what it lies on (the game's depth buffer, the nearest
      within 8 px), drawn after the level (a ModelSortGroup), so a glow stays on what glows from
      any angle. The mirror and the window frames carry the game's frame number and the window
      shows the mirror frame of its own game frame.
- [x] Telephoto shots (cutscenes reach a 0.27 tangent) have their depths compressed so the
      camera sits as close as for a normal view (same picture straight on); a black backdrop
      behind the level instead of the room where the game drew nothing.
- [x] Simulator: Ordon, Ordon Spring (a cutscene), the Lost Woods, Faron and Lakebed straight on
      and at 25 degrees; offline (mirror dump + effects) the Lost Woods matches the game to 3.9/255
      on average. Headset: untried.
- [ ] Link (and others) come out darker and flatter than the game draws them in Faron and the
      Lost Woods: their material multiplies in a second texture, the canopy's dappled light
      projected from position (256x256, GX_TG_MTX3x4 from POS, texmtx 33), which the mirror
      averages. Needs a second texture slot (AURORA_MIRROR_LOG=2 lists such materials).
- [x] Eyes: TP's eye material samples a grey mask first and the eye's own picture (iris and all)
      second; the mirror kept the first. It now keeps the most telling texture a draw samples: a
      colour picture over an intensity mask, mapped by the model's coordinates over a projection.
- [x] From the SHAR port's window (read 2026-10-02): the face at the front of a 4 pt deep view (it
      sat behind the window's bar and handles on the headset), a tap target on the portal (pinches
      went through to windows behind), handlesGameControllerEvents (controller buttons became
      pinches on whatever was looked at), the material list reset counting new materials (not
      parts), texture uploads checked and retried once, decals lifted min(0.4%, 3 units), runaway
      vertices (beyond 1e6) dropped, the sky's push capped at 100x.

### Next
- Foveation (launcher option, off): try on the headset; make it the default if it holds frame rate.
- Per-pixel depth for the compositor's reprojection (today the eyes are placed on a plane 3 m out).
