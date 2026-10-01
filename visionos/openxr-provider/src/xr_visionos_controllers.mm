// SPDX-License-Identifier: GPL-3.0-or-later
//
// PS VR2 Sense controllers for the visionOS provider (visionOS 26+). A local
// addition for TPVR, adapted from SHAR VR's visionos_controllers.mm.
//
// GameController reports one GCController per hand (product category
// GCProductCategorySpatialController) for the buttons, triggers and sticks;
// ARKit accessory tracking gives each one's grip and aim poses in the same world
// origin the drawables use. While a hand holds a Sense controller, that hand's
// Touch bindings (xr_visionos_input.mm) answer from the controller instead of
// the hand skeleton, so a game written for Quest Touch controllers plays as it
// does there; the other hand can stay bare.
//
// Sense to Touch: Square/Triangle are X/Y and Cross/Circle are A/B (each half
// names its face buttons "Button A"/"Button B"), L2/R2 are the triggers, L1/R1
// under the middle finger the grips, Create/Options the menu button.
//
// The accessory tracking runs on an ARKit session of its own, restarted when the
// set of controllers changes, so the head and hand tracking session is never
// interrupted. Everything except the accessory loads runs on the thread that
// calls xrSyncActions and xrApplyHapticFeedback.

#include "xr_visionos_internal.h"

#import <ARKit/ARKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <mutex>

namespace mkw::vr::visionos {
namespace {

constexpr int kLeft = 0;
constexpr int kRight = 1;

// Accessory loads complete on an ARKit queue; what they produce is guarded.
std::mutex g_accessoryMutex;
NSMutableArray* g_accessories = [NSMutableArray new]; // ar_accessory_t
bool g_accessoriesChanged = false;
NSMutableSet<GCController*>* g_requested = [NSMutableSet new];
ar_session_t g_session = nil;
ar_accessory_tracking_provider_t g_provider = nil;

std::array<ControllerSample, 2> g_samples{};
std::array<ControllerSample, 2> g_previous{};

bool IsSpatial(GCController* controller) {
    return [controller.productCategory isEqualToString:GCProductCategorySpatialController];
}

int HandOfChirality(ar_accessory_chirality_t chirality) {
    if (chirality == ar_accessory_chirality_left) return kLeft;
    if (chirality == ar_accessory_chirality_right) return kRight;
    return -1;
}

// Both halves report the same element names, so the hand comes from the name
// ("... Sense Controller (L)") or else the loaded accessory's chirality.
int HandOfController(GCController* controller) {
    NSString* name = controller.vendorName;
    if ([name hasSuffix:@"(L)"]) return kLeft;
    if ([name hasSuffix:@"(R)"]) return kRight;
    std::lock_guard lock(g_accessoryMutex);
    for (ar_accessory_t accessory in g_accessories) {
        if (ar_accessory_get_source_device(accessory) == controller) {
            const int hand = HandOfChirality(ar_accessory_get_inherent_chirality(accessory));
            if (hand >= 0) return hand;
        }
    }
    return -1;
}

// Asks ARKit for an accessory for each newly connected spatial controller and
// drops the ones whose controller has gone.
void UpdateAccessories() {
    NSArray<GCController*>* controllers = GCController.controllers;
    for (GCController* controller in [g_requested allObjects]) {
        if ([controllers containsObject:controller]) continue;
        [g_requested removeObject:controller];
        std::lock_guard lock(g_accessoryMutex);
        NSIndexSet* gone = [g_accessories indexesOfObjectsPassingTest:^BOOL(id accessory, NSUInteger, BOOL*) {
            return ar_accessory_get_source_device(accessory) == controller;
        }];
        if (gone.count) {
            [g_accessories removeObjectsAtIndexes:gone];
            g_accessoriesChanged = true;
        }
        NSLog(@"[visionos-provider] spatial controller disconnected: %@", controller.vendorName);
    }
    for (GCController* controller in controllers) {
        if (!IsSpatial(controller) || [g_requested containsObject:controller]) continue;
        [g_requested addObject:controller];
        NSLog(@"[visionos-provider] spatial controller connected: %@", controller.vendorName);
        ar_accessory_load_from_device(controller, ^(id<GCDevice>, bool successful, ar_error_t error,
                                                    ar_accessory_t accessory) {
            if (!successful || !accessory) {
                CFErrorRef cfError = error ? ar_error_copy_cf_error(error) : NULL;
                NSLog(@"[visionos-provider] loading the accessory for %@ failed: %@", controller.vendorName,
                      cfError ? (__bridge NSError*)cfError : @"no error");
                if (cfError) CFRelease(cfError);
                return;
            }
            std::lock_guard lock(g_accessoryMutex);
            [g_accessories addObject:accessory];
            g_accessoriesChanged = true;
        });
    }
}

// An accessory tracking provider tracks a fixed set of accessories, so a new one
// replaces it whenever that set changes, on its own session.
void RestartTrackingIfNeeded() {
    NSArray* accessories = nil;
    {
        std::lock_guard lock(g_accessoryMutex);
        if (!g_accessoriesChanged) return;
        g_accessoriesChanged = false;
        accessories = [g_accessories copy];
    }
    if (g_session) ar_session_stop(g_session);
    g_session = nil;
    g_provider = nil;
    if (accessories.count == 0) return;
    if (!ar_accessory_tracking_provider_is_supported()) {
        NSLog(@"[visionos-provider] accessory tracking is not supported here");
        return;
    }
    ar_accessories_t tracked = ar_accessories_create();
    for (ar_accessory_t accessory in accessories) ar_accessories_add_accessory(tracked, accessory);
    ar_accessory_tracking_configuration_t configuration = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(configuration, tracked);
    g_provider = ar_accessory_tracking_provider_create(configuration);
    g_session = ar_session_create();
    ar_session_run(g_session, ar_data_providers_create_with_data_providers(g_provider, nil));
    NSLog(@"[visionos-provider] tracking %lu spatial controller(s)", (unsigned long)accessories.count);
}

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

void ReadButtons(GCController* controller, int hand, ControllerSample& out) {
    GCPhysicalInputProfile* profile = controller.physicalInputProfile;
    if (!profile) return;
    const bool left = hand == kLeft;
    GCControllerDirectionPad* stick =
        Stick(profile, @[left ? GCInputLeftThumbstick : GCInputRightThumbstick, GCInputThumbstick]);
    out.stick = simd_make_float2(stick.xAxis.value, stick.yAxis.value);
    out.primary = Button(profile, left ? @[GCInputButtonX, GCInputButtonA] : @[GCInputButtonA]) > 0.5f;
    out.secondary = Button(profile, left ? @[GCInputButtonY, GCInputButtonB] : @[GCInputButtonB]) > 0.5f;
    out.trigger = Button(profile, @[left ? GCInputLeftTrigger : GCInputRightTrigger, GCInputTrigger]);
    out.squeeze = Button(profile, @[@"Grip", left ? GCInputLeftShoulder : GCInputRightShoulder,
                                    left ? GCInputLeftBumper : GCInputRightBumper]);
    out.stickClick =
        Button(profile, @[left ? GCInputLeftThumbstickButton : GCInputRightThumbstickButton, GCInputThumbstickButton]) >
        0.5f;
    out.menu = Button(profile, left ? @[GCInputButtonShare, GCInputButtonMenu, GCInputButtonOptions]
                                    : @[GCInputButtonOptions, GCInputButtonMenu]) > 0.5f;
}

// Grip and aim poses, predicted to the frame's display time like the head's.
void LocatePoses(int64_t displayNanos) {
    if (!g_provider || ar_data_provider_get_state(g_provider) != ar_data_provider_state_running) return;
    const CFTimeInterval time = displayNanos > 0 ? static_cast<CFTimeInterval>(displayNanos) * 1.0e-9 : 0.0;
    ar_accessory_tracking_provider_t provider = g_provider;
    ar_accessory_anchors_enumerate_anchors(
        ar_accessory_tracking_provider_get_latest_anchors(provider), ^bool(ar_accessory_anchor_t latest) {
            if (!ar_accessory_anchor_is_tracked(latest)) return true;
            ar_accessory_anchor_t anchor = latest;
            ar_accessory_anchor_t predicted = ar_accessory_anchor_create();
            if (time > 0 && ar_accessory_tracking_provider_predict_anchor_at_timestamp(provider, latest, time, predicted)) {
                anchor = predicted;
            }
            int hand = HandOfChirality(ar_accessory_anchor_get_held_chirality(anchor));
            if (hand < 0) {
                hand = HandOfChirality(ar_accessory_get_inherent_chirality(ar_accessory_anchor_get_accessory(anchor)));
            }
            if (hand < 0 || g_samples[hand].tracked) return true;
            const ar_accessory_anchor_tracking_state_t tracking = ar_accessory_anchor_get_tracking_state(anchor);
            if (tracking != ar_accessory_anchor_tracking_state_position_orientation_tracked &&
                tracking != ar_accessory_anchor_tracking_state_position_orientation_tracked_low_accuracy) {
                return true;
            }
            const simd_float4x4 originFromAnchor =
                ar_accessory_anchor_get_origin_from_anchor_transform_with_correction(anchor, ar_transform_correction_rendered);
            ControllerSample& sample = g_samples[hand];
            sample.worldFromGrip = simd_mul(originFromAnchor, ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
                                                                  anchor, ar_accessory_location_name_grip,
                                                                  ar_transform_correction_rendered));
            sample.worldFromAim = simd_mul(originFromAnchor, ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
                                                                 anchor, ar_accessory_location_name_aim,
                                                                 ar_transform_correction_rendered));
            sample.tracked = true;
            return true;
        });
}

// Haptics: one engine per controller, created on first use.
NSMutableDictionary<NSString*, CHHapticEngine*>* g_hapticEngines = [NSMutableDictionary new];
CFTimeInterval g_lastPulse[2] = {0, 0};

CHHapticEngine* HapticEngine(int hand) {
    GCController* controller = nil;
    for (GCController* candidate in GCController.controllers) {
        if (IsSpatial(candidate) && HandOfController(candidate) == hand) {
            controller = candidate;
            break;
        }
    }
    if (!controller.haptics) return nil;
    NSString* key = [NSString stringWithFormat:@"%p", controller];
    if (CHHapticEngine* engine = g_hapticEngines[key]) return engine;
    CHHapticEngine* engine = [controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    if (!engine) return nil;
    engine.playsHapticsOnly = YES;
    __weak CHHapticEngine* weakEngine = engine;
    engine.resetHandler = ^{ [weakEngine startAndReturnError:nil]; };
    if (![engine startAndReturnError:nil]) return nil;
    g_hapticEngines[key] = engine;
    return engine;
}

} // namespace

void SampleControllers(int64_t displayNanos) noexcept {
    @autoreleasepool {
        UpdateAccessories();
        RestartTrackingIfNeeded();
        const std::array<ControllerSample, 2> before = g_samples;
        g_samples = {};
        for (GCController* controller in GCController.controllers) {
            if (!IsSpatial(controller)) continue;
            const int hand = HandOfController(controller);
            if (hand < 0 || g_samples[hand].connected) continue;
            g_samples[hand].connected = true;
            ReadButtons(controller, hand, g_samples[hand]);
        }
        LocatePoses(displayNanos);
        const int64_t now = NowNanos();
        for (int hand = kLeft; hand <= kRight; ++hand) {
            g_samples[hand].timeNanos = now;
            g_previous[hand] = before[hand];
        }
    }
}

const ControllerSample& ControllerOf(uint32_t hand) noexcept {
    static const ControllerSample none{};
    return hand < 2 ? g_samples[hand] : none;
}

const ControllerSample& PreviousControllerOf(uint32_t hand) noexcept {
    static const ControllerSample none{};
    return hand < 2 ? g_previous[hand] : none;
}

bool ControllerComponentValue(const ControllerSample& c, const std::string& component, float& value,
                              bool& boolean) noexcept {
    value = 0.0f;
    boolean = false;
    if (component == "trigger/value" || component == "trigger") {
        value = c.trigger;
        boolean = c.trigger > 0.5f;
        return true;
    }
    if (component == "trigger/click" || component == "select/click" || component == "select") {
        boolean = c.trigger > 0.5f;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "squeeze/value" || component == "squeeze") {
        value = c.squeeze;
        boolean = c.squeeze > 0.5f;
        return true;
    }
    if (component == "squeeze/click") {
        boolean = c.squeeze > 0.5f;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "a/click" || component == "x/click") {
        boolean = c.primary;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "b/click" || component == "y/click") {
        boolean = c.secondary;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "menu/click") {
        boolean = c.menu;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "thumbstick/click") {
        boolean = c.stickClick;
        value = boolean ? 1.0f : 0.0f;
        return true;
    }
    if (component == "thumbstick/x") {
        value = c.stick.x;
        return true;
    }
    if (component == "thumbstick/y") {
        value = c.stick.y;
        return true;
    }
    return false;
}

void ControllerPulse(uint32_t hand, float amplitude, int64_t durationNanos) noexcept {
    if (hand > 1 || amplitude <= 0.0f) return;
    // A game may ask every frame; one pulse at a time is enough.
    const CFTimeInterval now = CACurrentMediaTime();
    if (now - g_lastPulse[hand] < 0.03) return;
    g_lastPulse[hand] = now;
    @autoreleasepool {
        CHHapticEngine* engine = HapticEngine(static_cast<int>(hand));
        if (!engine) return;
        // XR_MIN_HAPTIC_DURATION (-1) and 0 mean "the shortest the device does".
        const double seconds = durationNanos > 0 ? std::min(static_cast<double>(durationNanos) * 1.0e-9, 2.0) : 0.03;
        CHHapticEvent* event = [[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticContinuous
                   parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                                              value:std::min(amplitude, 1.0f)],
                                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                                              value:0.4f]]
                 relativeTime:0
                     duration:seconds];
        CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:nil];
        id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:nil] : nil;
        [player startAtTime:CHHapticTimeImmediate error:nil];
    }
}

} // namespace mkw::vr::visionos
