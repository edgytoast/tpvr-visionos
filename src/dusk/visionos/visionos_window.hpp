#pragma once

// The game in a window in the shared space (Immersion: Window). visionOS gives an app no head
// pose outside a Full Space, so the game plays flat (its own third-person camera) and hands each
// frame to the app as images in IOSurfaces: the 3D scene before the 2D/HUD, the distance of every
// pixel from the camera, the finished frame and Dusklight's own menus. The app turns the scene
// and its distances into a relief behind a portal in its RealityKit window, which RealityKit draws
// from the viewer's real eyes (depth and parallax), and puts the HUD flat on the window's glass
// (visionos/App/Sources/GameWindowView.swift; the approach is the SHAR port's relief window).
//
// With the app's scene mirror on (aurora/mirror.h), the frame's 3D draws between begin_frame()
// and before_hud() are also recorded for the window to draw itself.
//
// Every function is a no-op unless window mode was set before the game started.

struct view_class;

namespace dusk::visionos::window {

// Window mode for this run (set by the app's bridge before the game starts).
void set_enabled(bool enabled);
bool enabled();

// Game thread, once per frame before it is built: waits for the window's next display update
// (at most 100 ms, so a hidden window doesn't stop the game dead), which paces the game to the
// window instead of the swapchain it doesn't present.
void begin_frame();

// The 3D camera rendered this frame (mDoGph_Painter's camera block): its projection and focus.
void note_scene(const view_class* view);

// mDoGph_drawHud2D's two stages: the scene and its depth before the HUD, then the finished frame.
void before_hud();
void after_hud();

}  // namespace dusk::visionos::window
