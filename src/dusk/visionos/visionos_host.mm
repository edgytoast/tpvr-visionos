#include "dusk/visionos/visionos_host.h"

#include "vr/visionos/xr_visionos.h"

#include <SDL3/SDL_events.h>
#include <SDL3/SDL_init.h>
// Only SDL_SetMainReady() is wanted; without this SDL_main.h supplies a main().
#define SDL_MAIN_HANDLED 1
#include <SDL3/SDL_main.h>

#import <Foundation/Foundation.h>

#include <pthread.h>

#include <atomic>
#include <cstdlib>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

// Dusklight's main(), renamed by <aurora/main.h> (src/dusk/main.cpp). aurora's
// own main() is compiled out on visionOS (extern/aurora/lib/main.cpp).
extern "C" int aurora_main(int argc, char* argv[]);

namespace {

// The game ran on the main thread everywhere else, where the stack is 8 MB on
// macOS; give its thread room to match.
constexpr size_t kGameThreadStackSize = 16 * 1024 * 1024;

std::mutex g_mutex;
std::string g_discPath;
std::string g_lastError;
std::atomic_bool g_started{false};
std::atomic_bool g_running{false};
std::atomic_int g_exitCode{0};
std::atomic_bool g_roomBehindMenus{false};

void SetError(std::string message) {
    NSLog(@"[dusk::visionos] %s", message.c_str());
    std::lock_guard lock(g_mutex);
    g_lastError = std::move(message);
}

void* GameThreadMain(void*) {
    pthread_setname_np("Dusklight game");
    std::string disc;
    {
        std::lock_guard lock(g_mutex);
        disc = g_discPath;
    }
    std::vector<std::string> args = {"Dusklight"};
    if (!disc.empty()) {
        args.push_back("--dvd");
        args.push_back(disc);
    }
    // Headless runs: TPVR_ARGS adds Dusklight options, space-separated, e.g.
    //   SIMCTL_CHILD_TPVR_ARGS="--load-save 1 --stage F_SP103"
    if (const char* extra = std::getenv("TPVR_ARGS"); extra != nullptr) {
        std::istringstream tokens(extra);
        for (std::string token; tokens >> token;) {
            args.push_back(token);
        }
    }
    std::vector<char*> argv;
    for (std::string& arg : args) {
        argv.push_back(arg.data());
    }
    argv.push_back(nullptr);
    const int code = aurora_main(static_cast<int>(args.size()), argv.data());
    g_exitCode.store(code);
    g_running.store(false);
    NSLog(@"[dusk::visionos] game returned %d", code);
    return nullptr;
}

}  // namespace

extern "C" {

void dusk_visionos_set_disc_path(const char* path) {
    std::lock_guard lock(g_mutex);
    g_discPath = path != nullptr ? path : "";
}

void dusk_visionos_set_layer_renderer(void* layer_renderer) {
    xr_visionos_set_layer_renderer(layer_renderer);
}

void dusk_visionos_spatial_event(uint64_t event_id, int phase, int chirality, bool has_ray, float origin_x,
                                 float origin_y, float origin_z, float direction_x, float direction_y,
                                 float direction_z, bool has_pose, float pose_x, float pose_y, float pose_z) {
    xr_visionos_spatial_event(event_id, phase, chirality, has_ray, origin_x, origin_y, origin_z, direction_x,
                              direction_y, direction_z, has_pose, pose_x, pose_y, pose_z);
}

bool dusk_visionos_layer_invalidated(void) {
    return xr_visionos_layer_invalidated();
}

bool dusk_visionos_start_game(void) {
    bool expected = false;
    if (!g_started.compare_exchange_strong(expected, true)) {
        SetError("The game already ran in this process; relaunch the app to play again.");
        return false;
    }
    // main() is SwiftUI's, so tell SDL the platform set-up it would do from its
    // own main() already happened. aurora puts SDL on its offscreen video driver
    // on visionOS (extern/aurora/lib/window.cpp), which needs nothing from UIKit.
    SDL_SetMainReady();

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, kGameThreadStackSize);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    g_running.store(true);
    const int result = pthread_create(&thread, &attributes, &GameThreadMain, nullptr);
    pthread_attr_destroy(&attributes);
    if (result != 0) {
        g_running.store(false);
        SetError("Could not start the game thread (error " + std::to_string(result) + ").");
        return false;
    }
    return true;
}

bool dusk_visionos_game_running(void) {
    return g_running.load();
}

int dusk_visionos_exit_code(void) {
    return g_exitCode.load();
}

void dusk_visionos_request_quit(void) {
    // aurora turns SDL's quit into AURORA_EXIT, the path a closed desktop window
    // takes; the game then saves and shuts down on its own thread.
    if (SDL_WasInit(SDL_INIT_EVENTS) != 0) {
        SDL_Event event{};
        event.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&event);
    }
}

void dusk_visionos_set_room_behind_menus(bool enabled) {
    g_roomBehindMenus.store(enabled);
}

bool dusk_visionos_room_behind_menus(void) {
    return g_roomBehindMenus.load();
}

void dusk_visionos_set_safety_boundary(bool enabled) {
    xr_visionos_set_safety_boundary(enabled);
}

const char* dusk_visionos_last_error(void) {
    static thread_local std::string copy;
    {
        std::lock_guard lock(g_mutex);
        copy = g_lastError;
    }
    if (copy.empty()) {
        if (const char* provider = xr_visionos_last_error(); provider != nullptr) {
            copy = provider;
        }
    }
    return copy.c_str();
}

}  // extern "C"
