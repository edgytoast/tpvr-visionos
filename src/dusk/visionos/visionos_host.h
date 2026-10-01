#pragma once

// The bridge between the Apple Vision Pro app (visionos/App) and the game.
//
// On visionOS the game is a framework (DusklightGame.framework) the SwiftUI app
// embeds. main() belongs to SwiftUI, so the game runs on a thread of its own,
// started once the immersive space's CompositorLayer exists: TPVR's VR layer
// creates its OpenXR session against that layer through the visionOS OpenXR
// provider (visionos/openxr-provider). These are the only symbols the framework
// exports (visionos/visionos_exports.txt). Every function is safe to call from
// the main thread.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The disc image to load (GZ2E01 or GZ2P01, .iso or .rvz), passed to the game as
// --dvd. NULL or "" leaves the choice to the saved setting. Call before
// dusk_visionos_start_game.
void dusk_visionos_set_disc_path(const char* path);

// The cp_layer_renderer_t of the immersive space's CompositorLayer, retained by
// the provider. Set it before starting the game; NULL detaches it.
void dusk_visionos_set_layer_renderer(void* layer_renderer);

// A spatial event of the immersive space (the CompositorLayer's
// onSpatialEvent): visionOS's look-and-pinch selection, which the provider turns
// into a pointer and a select press. `phase`: 0 active, 1 ended, 2 cancelled.
// `chirality`: 0 unknown, 1 left, 2 right. The ray and the pose are in the
// immersive space's coordinates.
void dusk_visionos_spatial_event(uint64_t event_id, int phase, int chirality, bool has_ray, float origin_x,
                                 float origin_y, float origin_z, float direction_x, float direction_y,
                                 float direction_z, bool has_pose, float pose_x, float pose_y, float pose_z);

// True once the layer renderer was invalidated (the immersive space closed).
bool dusk_visionos_layer_invalidated(void);

// Starts the game on its thread. False when it already ran or the thread could
// not be created (see dusk_visionos_last_error).
bool dusk_visionos_start_game(void);
bool dusk_visionos_game_running(void);

// The game's exit code once it returned; 0 before.
int dusk_visionos_exit_code(void);

// Asks the game to quit the way closing its window would. Returns once the
// request is posted, not once the game stopped.
void dusk_visionos_request_quit(void);

// The last error the bridge or the provider reported, or "".
const char* dusk_visionos_last_error(void);

// Whether the immersive space shows the room wherever the game's frames are
// transparent (it opened mixed or progressive). The game then hides Hyrule behind
// its menus -- Dusklight's and TP's own full-screen ones -- so they float in the
// room. visionOS takes an immersive space's style when it opens and ignores later
// changes, so the app decides this before the space opens. Call before starting
// the game.
void dusk_visionos_set_room_behind_menus(bool enabled);

// A mixed space has no visionOS movement boundary. With this on, the provider
// fades Hyrule into the room as you walk away from where you started, the way a
// full space does. Call before starting the game.
void dusk_visionos_set_safety_boundary(bool enabled);

// Game -> bridge (not exported): dusk_visionos_set_room_behind_menus's value.
bool dusk_visionos_room_behind_menus(void);

#ifdef __cplusplus
}
#endif
