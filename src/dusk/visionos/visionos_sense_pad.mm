// Window mode's Sense controllers as one gamepad: see visionos_sense_pad.hpp.

#include "dusk/visionos/visionos_sense_pad.hpp"

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_joystick.h>

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace dusk::visionos::sense_pad {
namespace {

SDL_JoystickID g_pad = 0;

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
        if (name != nullptr && std::strstr(name, "Sense") != nullptr) {
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
        const auto trigger = [](float v) { return static_cast<Sint16>(std::clamp(v, 0.f, 1.f) * 32767.f); };
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
    }
}

}  // namespace dusk::visionos::sense_pad
