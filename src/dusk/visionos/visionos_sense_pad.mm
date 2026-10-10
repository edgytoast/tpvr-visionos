// Window mode's Sense controllers as one gamepad: see visionos_sense_pad.hpp.

#include "dusk/visionos/visionos_sense_pad.hpp"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <SDL3/SDL_events.h>
#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_joystick.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace dusk::visionos::sense_pad {
namespace {

SDL_JoystickID g_pad = 0;

// SDL names each Sense half after its GameController vendorName, "… Sense Controller (L)" or
// "(R)". A plain "Sense" also matched "DualSense Wireless Controller": a DualSense was ignored
// and lost player 1 every frame, so its Start (and every other button) never reached the game.
bool IsSenseHalf(const char* name) {
    return name != nullptr && std::strstr(name, "Sense Controller") != nullptr &&
           std::strstr(name, "DualSense") == nullptr;
}

// One half's state.
struct Half {
    bool present = false;
    float stickX = 0, stickY = 0, trigger = 0, grip = 0;
    bool face1 = false, face2 = false, stickClick = false, menu = false;
};

float Button(GCPhysicalInputProfile* profile, NSArray<NSString*>* names) {
    for (NSString* name in names) {
        if (GCControllerButtonInput* button = profile.buttons[name]) return button.value;
    }
    return 0.0f;
}

GCControllerDirectionPad* Stick(GCPhysicalInputProfile* profile, NSArray<NSString*>* names) {
    for (NSString* name in names) {
        if (GCControllerDirectionPad* stick = profile.dpads[name]) return stick;
    }
    return nil;
}

// The element names as the OpenXR provider reads them (xr_visionos_controllers.mm): each half
// names its face buttons "Button A"/"Button B" (or X/Y on the left).
void Read(GCController* controller, bool left, Half& half) {
    GCPhysicalInputProfile* profile = controller.physicalInputProfile;
    if (!profile) return;
    half.present = true;
    GCControllerDirectionPad* stick =
        Stick(profile, @[left ? GCInputLeftThumbstick : GCInputRightThumbstick, GCInputThumbstick]);
    half.stickX = stick.xAxis.value;
    half.stickY = stick.yAxis.value;
    half.face1 = Button(profile, left ? @[GCInputButtonX, GCInputButtonA] : @[GCInputButtonA]) > 0.5f;
    half.face2 = Button(profile, left ? @[GCInputButtonY, GCInputButtonB] : @[GCInputButtonB]) > 0.5f;
    half.trigger = Button(profile, @[left ? GCInputLeftTrigger : GCInputRightTrigger, GCInputTrigger]);
    half.grip = Button(profile, @[@"Grip", left ? GCInputLeftShoulder : GCInputRightShoulder,
                                  left ? GCInputLeftBumper : GCInputRightBumper]);
    half.stickClick =
        Button(profile, @[left ? GCInputLeftThumbstickButton : GCInputRightThumbstickButton, GCInputThumbstickButton]) >
        0.5f;
    half.menu = Button(profile, left ? @[GCInputButtonShare, GCInputButtonMenu, GCInputButtonOptions]
                                     : @[GCInputButtonOptions, GCInputButtonMenu]) > 0.5f;
}

bool Attach() {
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.name = "PS VR2 Sense Controllers";
    // Every standard button and axis: with gaps, SDL compacts the indices and writes land on the
    // wrong ones (vr_menu_gamepad.hpp found this the hard way).
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.button_mask = (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1u;
    desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1u;
    g_pad = SDL_AttachVirtualJoystick(&desc);
    if (g_pad == 0) {
        std::fprintf(stderr, "[dusk::visionos::sense] attaching the gamepad failed: %s\n", SDL_GetError());
        return false;
    }
    std::fprintf(stderr, "[dusk::visionos::sense] Sense controllers joined as one gamepad\n");
    return true;
}

// Player 1, unless a real gamepad holds it; SDL's own view of a Sense half (if it has one) none.
void ClaimPort() {
    int count = 0;
    SDL_JoystickID* gamepads = SDL_GetGamepads(&count);
    if (gamepads == nullptr) return;
    bool taken = false;
    for (int i = 0; i < count; ++i) {
        const SDL_JoystickID id = gamepads[i];
        if (id == g_pad) continue;
        SDL_Gamepad* gamepad = SDL_GetGamepadFromID(id);
        if (gamepad == nullptr) continue;
        const char* name = SDL_GetGamepadName(gamepad);
        if (IsSenseHalf(name)) {
            if (SDL_GetGamepadPlayerIndex(gamepad) != -1) SDL_SetGamepadPlayerIndex(gamepad, -1);
            continue;
        }
        taken = taken || SDL_GetGamepadPlayerIndex(gamepad) == 0;
    }
    SDL_free(gamepads);
    SDL_Gamepad* pad = SDL_GetGamepadFromID(g_pad);
    if (pad != nullptr && !taken && SDL_GetGamepadPlayerIndex(pad) != 0) {
        SDL_SetGamepadPlayerIndex(pad, 0);
    }
}

}  // namespace

void update() {
    // Spatial controllers (and their element names) arrived with visionOS 26.
    if (@available(visionOS 26.0, *)) {
    } else {
        return;
    }
    @autoreleasepool {
        Half halves[2];
        GCController* unnamed[2] = {nil, nil};
        int unnamedCount = 0;
        for (GCController* controller in GCController.controllers) {
            if (![controller.productCategory isEqualToString:GCProductCategorySpatialController]) continue;
            NSString* name = controller.vendorName;
            if ([name hasSuffix:@"(L)"]) {
                Read(controller, true, halves[0]);
            } else if ([name hasSuffix:@"(R)"]) {
                Read(controller, false, halves[1]);
            } else if (unnamedCount < 2) {
                unnamed[unnamedCount++] = controller;
            }
        }
        // Halves that don't say which they are fill the missing ones, left first.
        for (int i = 0; i < unnamedCount; ++i) {
            const int hand = !halves[0].present ? 0 : 1;
            if (!halves[hand].present) Read(unnamed[i], hand == 0, halves[hand]);
        }

        if (!halves[0].present && !halves[1].present) {
            if (g_pad != 0) {
                SDL_DetachVirtualJoystick(g_pad);
                g_pad = 0;
                std::fprintf(stderr, "[dusk::visionos::sense] Sense controllers gone\n");
            }
            return;
        }
        if (g_pad == 0 && !Attach()) return;
        // Opened by aurora when SDL reports it added (at most a frame later).
        SDL_Joystick* joystick = SDL_GetJoystickFromID(g_pad);
        if (joystick == nullptr) return;
        const Half& left = halves[0];
        const Half& right = halves[1];
        const auto axis = [](float v) { return static_cast<Sint16>(std::clamp(v, -1.f, 1.f) * 32767.f); };
        // A virtual gamepad's trigger reads the whole axis range: released is the minimum (written as 0,
        // it read half pressed, and TP's L and R holds never let go).
        const auto trigger = [](float v) {
            return static_cast<Sint16>(std::lround(std::clamp(v, 0.f, 1.f) * 65535.f) - 32768);
        };
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTX, axis(left.stickX));
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTY, axis(-left.stickY));
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHTX, axis(right.stickX));
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHTY, axis(-right.stickY));
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, trigger(left.trigger));
        SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, trigger(right.trigger));
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_SOUTH, right.face1);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_EAST, right.face2);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_WEST, left.face1);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_NORTH, left.face2);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, right.grip > 0.5f);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_START, right.menu);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_DPAD_UP, left.grip > 0.5f);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_DPAD_LEFT, left.menu);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_DPAD_DOWN, left.stickClick);
        SDL_SetJoystickVirtualButton(joystick, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, right.stickClick);
        ClaimPort();
        // The writes are only staged until SDL next updates its joysticks: now, not a frame later.
        SDL_UpdateJoysticks();
    }
}

void tidy_ports() {
    // The gamepads seen last frame, and whether the joined Sense pad was there: a gamepad is moved
    // to player 1 only when it arrives, or when the joined pad it gave way to leaves. Every frame,
    // it undid the player's own choice in Settings › Input (a gamepad set to None, or to player 2).
    static std::vector<SDL_JoystickID> s_seen;
    static bool s_padWas = false;
    const bool padLeft = s_padWas && g_pad == 0;
    s_padWas = g_pad != 0;
    int count = 0;
    SDL_JoystickID* gamepads = SDL_GetGamepads(&count);
    if (gamepads == nullptr) return;
    std::vector<SDL_JoystickID> seen;
    bool taken = false;
    SDL_Gamepad* waiting = nullptr;
    for (int i = 0; i < count; ++i) {
        // Opened by aurora when SDL reports it added (at most a frame later): seen once it is.
        SDL_Gamepad* gamepad = SDL_GetGamepadFromID(gamepads[i]);
        if (gamepad == nullptr) continue;
        seen.push_back(gamepads[i]);
        const char* name = SDL_GetGamepadName(gamepad);
        const int player = SDL_GetGamepadPlayerIndex(gamepad);
        if (gamepads[i] != g_pad && IsSenseHalf(name)) {
            if (player != -1) SDL_SetGamepadPlayerIndex(gamepad, -1);
            continue;
        }
        // The VR mod's menu gamepad keeps player 2 (vr_menu_gamepad.hpp).
        if (name != nullptr && std::strcmp(name, "Dusklight VR Menu Controller") == 0) continue;
        if (player == 0) {
            taken = true;
            continue;
        }
        const bool arrived = std::find(s_seen.begin(), s_seen.end(), gamepads[i]) == s_seen.end();
        // (On -1 it's been set to no player: Settings › Input's None, kept.)
        if (waiting == nullptr && gamepads[i] != g_pad && player > 0 && (arrived || padLeft)) {
            waiting = gamepad;
        }
    }
    SDL_free(gamepads);
    s_seen = std::move(seen);
    if (!taken && waiting != nullptr) {
        SDL_SetGamepadPlayerIndex(waiting, 0);
        const char* name = SDL_GetGamepadName(waiting);
        std::fprintf(stderr, "[dusk::visionos::sense] %s takes player 1\n", name != nullptr ? name : "a gamepad");
    }
}

bool ignores(const SDL_Event& event) {
    SDL_JoystickID which = 0;
    switch (event.type) {
    case SDL_EVENT_GAMEPAD_AXIS_MOTION:
        which = event.gaxis.which;
        break;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP:
        which = event.gbutton.which;
        break;
    case SDL_EVENT_GAMEPAD_ADDED:
    case SDL_EVENT_GAMEPAD_REMOVED:
    case SDL_EVENT_GAMEPAD_REMAPPED:
        which = event.gdevice.which;
        break;
    case SDL_EVENT_JOYSTICK_AXIS_MOTION:
        which = event.jaxis.which;
        break;
    case SDL_EVENT_JOYSTICK_BUTTON_DOWN:
    case SDL_EVENT_JOYSTICK_BUTTON_UP:
        which = event.jbutton.which;
        break;
    default:
        return false;
    }
    if (which == 0 || which == g_pad) {
        return false;
    }
    const char* name = SDL_GetGamepadNameForID(which);
    if (name == nullptr) {
        name = SDL_GetJoystickNameForID(which);
    }
    return IsSenseHalf(name);
}

}  // namespace dusk::visionos::sense_pad
