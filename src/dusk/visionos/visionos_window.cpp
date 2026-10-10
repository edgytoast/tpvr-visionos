// The game in a visionOS window: see visionos_window.hpp.
//
// Data path, per frame:
//   game thread   begin_frame()  waits for the window's tick (the app's RealityKit update)
//                 note_scene()   the camera's projection and focus, if a 3D scene is drawn
//                 scene_drawn()  with the scene mirror: resolve_pass(colour) -> encoder task: the
//                                3D picture before the screen effects (bloom, mist, fades)
//                 before_hud()   resolve_pass(colour + depth) -> encoder task: scene, distance
//                 after_hud()    resolve_pass(colour) -> encoder task: final frame, Dusklight UI
//   render worker the tasks copy the snapshots into the slot's IOSurfaces (Dawn imports them),
//                 then, after the frame's command buffer is submitted, end Dawn's access and
//                 publish the slot with the MTLSharedEvent the reads must wait on.
//   app (main)    dusk_visionos_window_acquire() takes the newest slot, its GPU reads wait on
//                 that event, and dusk_visionos_window_release() hands the slot back once they
//                 finish.
// Every Dawn call happens on the render worker (inside encoder tasks and their after-submit
// callbacks), the thread aurora encodes on.

#include "dusk/visionos/visionos_window.hpp"

#include "dusk/audio/DuskAudioSystem.h"
#include "dusk/commands.hpp"
#include "dusk/visionos/visionos_host.h"
#include "dusk/visionos/visionos_sense_pad.hpp"
#include "dusk/ui/ui.hpp"
#include "f_op/f_op_view.h"
#include "d/d_com_inf_game.h"
#include "m_Do/m_Do_graphic.h"

#include "../../../extern/aurora/lib/rmlui.hpp"
#include <aurora/aurora.h>
#include <aurora/gfx.hpp>
#include <aurora/mirror.h>
#include <dolphin/gx/GXAurora.h>
#include <dolphin/pad.h>
#include <webgpu/webgpu_cpp.h>

#include <SDL3/SDL_events.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstddef>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#define WINDOW_LOG(...) std::fprintf(stderr, "[dusk::visionos::window] " __VA_ARGS__)

namespace dusk::visionos::window {
namespace {

std::atomic_bool g_enabled{false};
dispatch_semaphore_t g_tick = dispatch_semaphore_create(0);
// The window in the background (dusk_visionos_set_paused): begin_frame holds the game there.
std::atomic_bool g_held{false};
// Bumped whenever any slot's surfaces are (re)made: the app drops its textures over them.
std::atomic<uint64_t> g_surfaceGeneration{1};

// One IOSurface the app reads, imported into Dawn.
struct Surface {
    IOSurfaceRef surface = nullptr;
    wgpu::SharedTextureMemory memory;
    wgpu::Texture texture;
    wgpu::TextureFormat format = wgpu::TextureFormat::Undefined;
    uint32_t width = 0, height = 0;
    bool accessOpen = false;
};

enum class SlotState { Free, Writing, Ready, Reading };

struct CameraInfo {
    float tanHalfX = 0, tanHalfY = 0, focus = 0, nearZ = 0, farZ = 0;
    float subject = 0;  // the player's nearest view depth (0: none), for the mirror (AURORA_MIRROR_MARK_SUBJECT)
};

// A frame on its way to the app. While Writing it belongs to the game thread (which fills the
// pending fields) and then the render worker; Ready and Reading belong to the app.
struct Slot {
    SlotState state = SlotState::Free;
    Surface scene, distance, final, ui, base;
    wgpu::Buffer uniforms;
    uint64_t serial = 0;
    uint32_t gameFrame = 0;
    CameraInfo camera;
    bool hasScene = false, hasUi = false, hasFinal = false, hasBase = false;
    void* event = nullptr;  // MTLSharedEvent (Dawn's), borrowed
    uint64_t value = 0;
    // Snapshots taken on the game thread, copied on the render worker.
    wgpu::TextureView pendingScene, pendingDepth, pendingFinal, pendingUi, pendingBase;
    uint32_t sceneWidth = 0, sceneHeight = 0, finalWidth = 0, finalHeight = 0, uiWidth = 0, uiHeight = 0;
    uint32_t baseWidth = 0, baseHeight = 0;
    // The game's fade over its 3D scene this frame (sRGB colour 0-1, then its cover): drawn
    // before the scene is taken, so the scene and the finished frame both have it.
    float fade[4]{};
};

constexpr size_t kSlots = 4;
std::mutex g_mutex;  // slot states, serials, g_latest
std::array<Slot, kSlots> g_slots;
uint64_t g_nextSerial = 1;
int g_latest = -1;
uint64_t g_handed = 0;

// Game-thread state for the frame being built.
int g_frameSlot = -1;
bool g_sceneThisFrame = false;
bool g_scenePushed = false;  // this frame's scene task is on its way for g_frameSlot
bool g_basePushed = false;   // and its base task (the picture before the screen effects)
bool g_mirrorBegun = false;  // a scene-mirror frame was opened this frame, and must be closed
uint32_t g_gameFrame = 0;     // this frame's number (24 bits), shared by its window frame and mirror frame
CameraInfo g_camera;

aurora::gfx::EncoderTaskId g_sceneTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_finalTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_baseTask = aurora::gfx::InvalidEncoderTask;

struct TaskPayload {
    uint32_t slot;
};

// The copies: a fullscreen triangle that loads the source texel for texel. fs_distance turns
// aurora's reversed-Z depth (near 1, far 0) into the distance from the camera in game units:
// d = n (f - z) / ((f - n) z)  =>  z = n f / (n + d (f - n)).
constexpr const char* kShader = R"(
struct Params { nearZ: f32, farZ: f32, unused0: f32, unused1: f32 };
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var<uniform> params: Params;

@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment fn fs_copy(@builtin(position) at: vec4f) -> @location(0) vec4f {
    return textureLoad(source, vec2i(at.xy), 0);
}

@fragment fn fs_distance(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let depth = textureLoad(source, vec2i(at.xy), 0).r;
    let n = params.nearZ;
    let f = params.farZ;
    let distance = n * f / max(n + depth * (f - n), 1e-6);
    return vec4f(min(distance, 60000.0), depth, 0.0, 1.0);
}
)";

struct Pipelines {
    wgpu::BindGroupLayout layout;
    wgpu::RenderPipeline copyBgra8, copyRgba16f, distance;
    bool failed = false;
};
Pipelines g_pipelines;

wgpu::RenderPipeline MakePipeline(const wgpu::Device& device, const wgpu::ShaderModule& module,
                                  const wgpu::PipelineLayout& layout, const char* fragment,
                                  wgpu::TextureFormat format) {
    wgpu::ColorTargetState target{};
    target.format = format;
    wgpu::FragmentState fs{};
    fs.module = module;
    fs.entryPoint = fragment;
    fs.targetCount = 1;
    fs.targets = &target;
    wgpu::RenderPipelineDescriptor desc{};
    desc.label = "visionOS window copy";
    desc.layout = layout;
    desc.vertex.module = module;
    desc.vertex.entryPoint = "vs";
    desc.primitive.topology = wgpu::PrimitiveTopology::TriangleList;
    desc.fragment = &fs;
    return device.CreateRenderPipeline(&desc);
}

bool EnsurePipelines(const wgpu::Device& device) {
    if (g_pipelines.copyBgra8 || g_pipelines.failed) {
        return !g_pipelines.failed;
    }
    wgpu::ShaderSourceWGSL wgsl{};
    wgsl.code = kShader;
    wgpu::ShaderModuleDescriptor moduleDesc{};
    moduleDesc.nextInChain = &wgsl;
    moduleDesc.label = "visionOS window copy";
    wgpu::ShaderModule module = device.CreateShaderModule(&moduleDesc);

    std::array<wgpu::BindGroupLayoutEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].visibility = wgpu::ShaderStage::Fragment;
    entries[0].texture.sampleType = wgpu::TextureSampleType::UnfilterableFloat;
    entries[0].texture.viewDimension = wgpu::TextureViewDimension::e2D;
    entries[1].binding = 1;
    entries[1].visibility = wgpu::ShaderStage::Fragment;
    entries[1].buffer.type = wgpu::BufferBindingType::Uniform;
    entries[1].buffer.minBindingSize = 16;
    wgpu::BindGroupLayoutDescriptor layoutDesc{};
    layoutDesc.entryCount = entries.size();
    layoutDesc.entries = entries.data();
    g_pipelines.layout = device.CreateBindGroupLayout(&layoutDesc);
    wgpu::PipelineLayoutDescriptor pipelineLayoutDesc{};
    pipelineLayoutDesc.bindGroupLayoutCount = 1;
    pipelineLayoutDesc.bindGroupLayouts = &g_pipelines.layout;
    wgpu::PipelineLayout layout = device.CreatePipelineLayout(&pipelineLayoutDesc);

    g_pipelines.copyBgra8 = MakePipeline(device, module, layout, "fs_copy", wgpu::TextureFormat::BGRA8Unorm);
    g_pipelines.copyRgba16f = MakePipeline(device, module, layout, "fs_copy", wgpu::TextureFormat::RGBA16Float);
    g_pipelines.distance = MakePipeline(device, module, layout, "fs_distance", wgpu::TextureFormat::RGBA16Float);
    g_pipelines.failed = !g_pipelines.copyBgra8 || !g_pipelines.distance;
    if (g_pipelines.failed) {
        WINDOW_LOG("copy pipelines failed\n");
    }
    return !g_pipelines.failed;
}

IOSurfaceRef CreateSurface(uint32_t width, uint32_t height, uint32_t fourcc, int bytesPerElement) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const auto set = [&](CFStringRef key, int value) {
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
        CFDictionarySetValue(properties, key, number);
        CFRelease(number);
    };
    set(kIOSurfaceWidth, static_cast<int>(width));
    set(kIOSurfaceHeight, static_cast<int>(height));
    set(kIOSurfaceBytesPerElement, bytesPerElement);
    set(kIOSurfacePixelFormat, static_cast<int>(fourcc));
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}

void Release(Surface& surface) {
    surface.texture = nullptr;
    surface.memory = nullptr;
    if (surface.surface != nullptr) {
        CFRelease(surface.surface);
    }
    surface = Surface{};
}

// An IOSurface of this size and format, imported into Dawn (made, or remade on a size change).
bool EnsureSurface(const wgpu::Device& device, Slot& slot, Surface& surface, uint32_t width, uint32_t height,
                   bool halfFloat) {
    if (surface.surface != nullptr && surface.width == width && surface.height == height) {
        return surface.texture != nullptr;
    }
    Release(surface);
    surface.surface = halfFloat ? CreateSurface(width, height, 'RGhA', 8) : CreateSurface(width, height, 'BGRA', 4);
    if (surface.surface == nullptr) {
        WINDOW_LOG("IOSurfaceCreate %ux%u failed\n", width, height);
        return false;
    }
    wgpu::SharedTextureMemoryIOSurfaceDescriptor ioDesc{};
    ioDesc.ioSurface = surface.surface;
    wgpu::SharedTextureMemoryDescriptor memoryDesc{};
    memoryDesc.nextInChain = &ioDesc;
    memoryDesc.label = "visionOS window surface";
    surface.memory = device.ImportSharedTextureMemory(&memoryDesc);
    if (surface.memory) {
        wgpu::SharedTextureMemoryProperties props{};
        surface.memory.GetProperties(&props);
        wgpu::TextureDescriptor textureDesc{};
        textureDesc.label = "visionOS window surface";
        textureDesc.usage = wgpu::TextureUsage::RenderAttachment;
        textureDesc.size = {width, height, 1};
        textureDesc.format = props.format;
        surface.texture = surface.memory.CreateTexture(&textureDesc);
        surface.format = props.format;
    }
    if (!surface.texture) {
        WINDOW_LOG("Dawn could not import a %ux%u window surface\n", width, height);
        Release(surface);
        return false;
    }
    surface.width = width;
    surface.height = height;
    g_surfaceGeneration.fetch_add(1);
    return true;
}

bool BeginAccess(Surface& surface) {
    if (surface.accessOpen) {
        return true;
    }
    wgpu::SharedTextureMemoryBeginAccessDescriptor begin{};
    begin.initialized = true;
    if (surface.memory.BeginAccess(surface.texture, &begin) != wgpu::Status::Success) {
        WINDOW_LOG("BeginAccess failed\n");
        return false;
    }
    surface.accessOpen = true;
    return true;
}

// Ends Dawn's access, keeping the MTLSharedEvent and the value its writes complete at.
void EndAccess(Surface& surface, void*& event, uint64_t& value) {
    if (!surface.accessOpen) {
        return;
    }
    surface.accessOpen = false;
    wgpu::SharedTextureMemoryEndAccessState end{};
    surface.memory.EndAccess(surface.texture, &end);
    for (size_t i = 0; i < end.fenceCount && i < end.signaledValueCount; ++i) {
        wgpu::SharedFenceMTLSharedEventExportInfo metal{};
        wgpu::SharedFenceExportInfo info{};
        info.nextInChain = &metal;
        end.fences[i].ExportInfo(&info);
        if (info.type == wgpu::SharedFenceType::MTLSharedEvent && metal.sharedEvent != nullptr) {
            event = metal.sharedEvent;
            value = std::max(value, end.signaledValues[i]);
        }
    }
}

void Draw(const wgpu::Device& device, wgpu::CommandEncoder& encoder, const wgpu::RenderPipeline& pipeline,
          const wgpu::TextureView& source, const wgpu::Buffer& uniforms, Surface& target) {
    std::array<wgpu::BindGroupEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].textureView = source;
    entries[1].binding = 1;
    entries[1].buffer = uniforms;
    entries[1].size = 16;
    wgpu::BindGroupDescriptor groupDesc{};
    groupDesc.layout = g_pipelines.layout;
    groupDesc.entryCount = entries.size();
    groupDesc.entries = entries.data();
    wgpu::BindGroup group = device.CreateBindGroup(&groupDesc);

    wgpu::RenderPassColorAttachment colour{};
    colour.view = target.texture.CreateView();
    colour.loadOp = wgpu::LoadOp::Clear;
    colour.storeOp = wgpu::StoreOp::Store;
    colour.clearValue = {0, 0, 0, 0};
    wgpu::RenderPassDescriptor passDesc{};
    passDesc.label = "visionOS window copy";
    passDesc.colorAttachmentCount = 1;
    passDesc.colorAttachments = &colour;
    wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&passDesc);
    pass.SetPipeline(pipeline);
    pass.SetBindGroup(0, group);
    pass.Draw(3);
    pass.End();
}

const wgpu::RenderPipeline& CopyPipelineFor(const Surface& target) {
    return target.format == wgpu::TextureFormat::RGBA16Float ? g_pipelines.copyRgba16f : g_pipelines.copyBgra8;
}

void EnsureUniforms(const wgpu::Device& device, Slot& slot) {
    if (!slot.uniforms) {
        wgpu::BufferDescriptor desc{};
        desc.label = "visionOS window params";
        desc.size = 16;
        desc.usage = wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst;
        slot.uniforms = device.CreateBuffer(&desc);
    }
}

// Render worker: the scene and its distances into the slot.
void SceneTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
               size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasScene = false;
    if (!EnsurePipelines(ctx.device) || !slot.pendingScene || !slot.pendingDepth) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    const float params[4] = {slot.camera.nearZ, slot.camera.farZ, 0, 0};
    ctx.queue.WriteBuffer(slot.uniforms, 0, params, sizeof(params));
    if (!EnsureSurface(ctx.device, slot, slot.scene, slot.sceneWidth, slot.sceneHeight, false) ||
        !EnsureSurface(ctx.device, slot, slot.distance, slot.sceneWidth, slot.sceneHeight, true) ||
        !BeginAccess(slot.scene) || !BeginAccess(slot.distance)) {
        return;
    }
    Draw(ctx.device, encoder, CopyPipelineFor(slot.scene), slot.pendingScene, slot.uniforms, slot.scene);
    Draw(ctx.device, encoder, g_pipelines.distance, slot.pendingDepth, slot.uniforms, slot.distance);
    slot.hasScene = true;
}

// Render worker: the 3D picture before the screen effects into the slot.
void BaseTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
              size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasBase = false;
    if (!EnsurePipelines(ctx.device) || !slot.pendingBase) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    if (!EnsureSurface(ctx.device, slot, slot.base, slot.baseWidth, slot.baseHeight, false) ||
        !BeginAccess(slot.base)) {
        return;
    }
    Draw(ctx.device, encoder, CopyPipelineFor(slot.base), slot.pendingBase, slot.uniforms, slot.base);
    slot.hasBase = true;
}

// Render worker: the finished frame and Dusklight's UI into the slot.
void FinalTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
               size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasFinal = false;
    slot.hasUi = false;
    if (!EnsurePipelines(ctx.device) || !slot.pendingFinal) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    if (EnsureSurface(ctx.device, slot, slot.final, slot.finalWidth, slot.finalHeight, false) &&
        BeginAccess(slot.final)) {
        Draw(ctx.device, encoder, CopyPipelineFor(slot.final), slot.pendingFinal, slot.uniforms, slot.final);
        slot.hasFinal = true;
    }
    if (slot.pendingUi && EnsureSurface(ctx.device, slot, slot.ui, slot.uiWidth, slot.uiHeight, false) &&
        BeginAccess(slot.ui)) {
        Draw(ctx.device, encoder, CopyPipelineFor(slot.ui), slot.pendingUi, slot.uniforms, slot.ui);
        slot.hasUi = true;
    }
}

// Render worker, after the frame's command buffer went to the GPU: end Dawn's access and hand
// the slot to the app.
void FinalSubmitted(const aurora::gfx::EncoderTaskCompletionContext&, const void* payload, size_t, void*) {
    const uint32_t index = static_cast<const TaskPayload*>(payload)->slot;
    Slot& slot = g_slots[index];
    void* event = nullptr;
    uint64_t value = 0;
    EndAccess(slot.scene, event, value);
    EndAccess(slot.distance, event, value);
    EndAccess(slot.final, event, value);
    EndAccess(slot.ui, event, value);
    EndAccess(slot.base, event, value);
    slot.pendingScene = nullptr;
    slot.pendingBase = nullptr;
    slot.pendingDepth = nullptr;
    slot.pendingFinal = nullptr;
    slot.pendingUi = nullptr;
    std::lock_guard lock(g_mutex);
    if (!slot.hasFinal) {
        slot.state = SlotState::Free;
        return;
    }
    slot.event = event;
    slot.value = value;
    slot.serial = g_nextSerial++;
    if (g_latest >= 0 && g_latest != static_cast<int>(index) && g_slots[g_latest].state == SlotState::Ready) {
        g_slots[g_latest].state = SlotState::Free;  // never shown: a newer frame replaces it
    }
    slot.state = SlotState::Ready;
    g_latest = static_cast<int>(index);
}

void RegisterTasks() {
    if (g_sceneTask != aurora::gfx::InvalidEncoderTask) {
        return;
    }
    aurora::gfx::EncoderTaskDescriptor scene{};
    scene.label = "visionOS window scene";
    scene.callback = &SceneTask;
    g_sceneTask = aurora::gfx::register_encoder_task_type(scene);
    aurora::gfx::EncoderTaskDescriptor final{};
    final.label = "visionOS window frame";
    final.callback = &FinalTask;
    final.afterSubmit = &FinalSubmitted;
    g_finalTask = aurora::gfx::register_encoder_task_type(final);
    aurora::gfx::EncoderTaskDescriptor base{};
    base.label = "visionOS window base";
    base.callback = &BaseTask;
    g_baseTask = aurora::gfx::register_encoder_task_type(base);
}

// Game thread: a free slot for this frame, or -1 (the app holds them all: skip this frame).
int ClaimSlot() {
    if (g_frameSlot >= 0) {
        return g_frameSlot;
    }
    std::lock_guard lock(g_mutex);
    for (size_t i = 0; i < kSlots; ++i) {
        if (g_slots[i].state == SlotState::Free) {
            g_slots[i].state = SlotState::Writing;
            g_frameSlot = static_cast<int>(i);
            return g_frameSlot;
        }
    }
    return -1;
}

#if TARGET_OS_SIMULATOR
// Test runs: TPVR_TEST_COMMANDS="<seconds>:<command>;..." runs Dusklight console commands at those
// times after the first frame, their output in the log, e.g. to find an actor and look at it:
//   SIMCTL_CHILD_TPVR_TEST_COMMANDS="40:list;42:camera tp 100 200 300 16384 -2000"
void RunTestCommands() {
    using Clock = std::chrono::steady_clock;
    static const Clock::time_point started = Clock::now();
    static std::vector<std::pair<double, std::string>> pending = [] {
        std::vector<std::pair<double, std::string>> list;
        const char* value = std::getenv("TPVR_TEST_COMMANDS");
        std::istringstream entries(value != nullptr ? value : "");
        for (std::string entry; std::getline(entries, entry, ';');) {
            const size_t colon = entry.find(':');
            if (colon != std::string::npos) {
                list.emplace_back(std::strtod(entry.substr(0, colon).c_str(), nullptr), entry.substr(colon + 1));
            }
        }
        std::stable_sort(list.begin(), list.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        return list;
    }();
    static dusk::CommandState state;
    const double seconds = std::chrono::duration<double>(Clock::now() - started).count();
    while (!pending.empty() && pending.front().first <= seconds) {
        WINDOW_LOG("test command at %.1f s: %s\n", seconds, pending.front().second.c_str());
        dusk::runCommand(pending.front().second, state,
                         [](std::string line) { WINDOW_LOG("  %s\n", line.c_str()); });
        pending.erase(pending.begin());
    }
}
#endif

}  // namespace

void set_enabled(bool enabled) {
    g_enabled.store(enabled);
}

bool enabled() {
    return g_enabled.load(std::memory_order_relaxed);
}

void begin_frame() {
    if (!enabled()) {
        return;
    }
    static bool started = false;
    if (!started) {
        started = true;
        // Nobody sees the offscreen SDL window's surface.
        aurora::gfx::set_surface_present_suppressed(true);
        RegisterTasks();
        WINDOW_LOG("window mode: the game paces to the window and hands it each frame\n");
    }
    // A frame per window update: wait for the next, at most 100 ms (a hidden window stops
    // ticking), then forget any that piled up so the game never races ahead to catch up.
    dispatch_semaphore_wait(g_tick, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    while (dispatch_semaphore_wait(g_tick, DISPATCH_TIME_NOW) == 0) {
    }
    // In the background: the game holds here, its sound paused and any rumble stopped, until the
    // window is back or closed (closing pushes a quit to SDL's queue, which the frame then takes).
    // Holding only the game clock, as before, left the game playing at the 100 ms pace above, its
    // music on, drawing into a window nobody saw.
    if (g_held.load() && !SDL_HasEvent(SDL_EVENT_QUIT)) {
        WINDOW_LOG("in the background: the game holds\n");
        dusk::audio::SetPaused(true);
        for (u32 port = 0; port < 4; ++port) {
            PADControlMotor(port, PAD_MOTOR_STOP_HARD);
        }
        while (g_held.load() && !SDL_HasEvent(SDL_EVENT_QUIT)) {
            dispatch_semaphore_wait(g_tick, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
        }
        // Closed while held: the sound stays off for the frame that takes the quit.
        if (!SDL_HasEvent(SDL_EVENT_QUIT)) {
            dusk::audio::SetPaused(false);
            WINDOW_LOG("back: the game carries on\n");
        }
    }
    g_frameSlot = -1;
    g_sceneThisFrame = false;
    g_scenePushed = false;
    g_basePushed = false;
    g_gameFrame = (g_gameFrame + 1) & 0xFFFFFFu;
    // The Sense controllers, if any, as a gamepad (no controller tracking outside a Full Space).
    sense_pad::update();
#if TARGET_OS_SIMULATOR
    RunTestCommands();
#endif
    // The scene mirror records the frame's draws from here to before_hud().
    if (aurora::mirror::enabled()) {
        GXAuroraMirrorMark(AURORA_MIRROR_MARK_BEGIN, static_cast<float>(g_gameFrame));
        g_mirrorBegun = true;
    }
}

void note_scene(const view_class* view) {
    if (!enabled() || view == nullptr) {
        return;
    }
    g_sceneThisFrame = true;
    const float p00 = view->projMtx[0][0], p11 = view->projMtx[1][1];
    g_camera.tanHalfX = p00 != 0 ? 1.0f / std::fabs(p00) : 1.0f;
    g_camera.tanHalfY = p11 != 0 ? 1.0f / std::fabs(p11) : 0.5625f;
    const float dx = view->lookat.center.x - view->lookat.eye.x;
    const float dy = view->lookat.center.y - view->lookat.eye.y;
    const float dz = view->lookat.center.z - view->lookat.eye.z;
    g_camera.focus = std::sqrt(dx * dx + dy * dy + dz * dz);
    g_camera.nearZ = view->near_;
    g_camera.farZ = view->far_;
    // How near the camera the player comes (his feet, middle and head, less his girth), when he's
    // in the picture (or just outside it): the mirror keeps him whole (a lock-on or a camera
    // pushed in behind him can put him well short of the camera's focus, where the window
    // compresses and cuts off what's nearest the camera). Off the picture he's no one's subject.
    g_camera.subject = 0;
    if (const fopAc_ac_c* player = dComIfGp_getPlayer(0)) {
        const auto& m = view->viewMtx;
        const cXyz& at = player->current.pos;
        float nearest = INFINITY;
        bool seen = false;
        for (const float rise : {0.f, 80.f, 160.f}) {
            const float y = at.y + rise;
            const float depth = -(m[2][0] * at.x + m[2][1] * y + m[2][2] * at.z + m[2][3]);
            const float across = m[0][0] * at.x + m[0][1] * y + m[0][2] * at.z + m[0][3];
            const float up = m[1][0] * at.x + m[1][1] * y + m[1][2] * at.z + m[1][3];
            nearest = std::min(nearest, depth);
            seen = seen || (depth > 0.f && std::fabs(across) <= 1.25f * g_camera.tanHalfX * depth &&
                            std::fabs(up) <= 1.25f * g_camera.tanHalfY * depth);
        }
        g_camera.subject = seen && std::isfinite(nearest) ? std::max(nearest - 50.f, 0.f) : 0.f;
    }
}

bool mirroring() {
    return g_mirrorBegun;
}

void scene_drawn() {
    if (!g_mirrorBegun) {
        return;
    }
    // The scene mirror's frame ends here, once the snapshot is taken (its resolve waits for the
    // FIFO; the mirror's finishing work then overlaps the screen effects and the HUD).
    struct CloseMirror {
        ~CloseMirror() {
            g_mirrorBegun = false;
            if (g_sceneThisFrame) {
                GXAuroraMirrorMark(AURORA_MIRROR_MARK_SUBJECT, g_camera.subject);
            }
            GXAuroraMirrorMark(g_sceneThisFrame ? AURORA_MIRROR_MARK_END : AURORA_MIRROR_MARK_NO_SCENE,
                               g_camera.focus);
        }
    } closeMirror;
    if (!enabled() || !g_sceneThisFrame) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    aurora::gfx::ResolvedTargets targets;
    if (!aurora::gfx::resolve_pass({.color = true}, targets) || !targets.color) {
        return;
    }
    Slot& slot = g_slots[index];
    slot.pendingBase = targets.color;
    slot.baseWidth = targets.width;
    slot.baseHeight = targets.height;
    const TaskPayload payload{static_cast<uint32_t>(index)};
    g_basePushed = aurora::gfx::push_encoder_task(g_baseTask, &payload, sizeof(payload));
}

void before_hud() {
    // The scene mirror's frame ends here if scene_drawn() didn't end it, whatever happens below,
    // once the snapshots are taken:
    // their resolves wait for the FIFO, and the mirror's finishing work then overlaps the HUD.
    struct CloseMirror {
        ~CloseMirror() {
            if (g_mirrorBegun) {
                g_mirrorBegun = false;
                if (g_sceneThisFrame) {
                    GXAuroraMirrorMark(AURORA_MIRROR_MARK_SUBJECT, g_camera.subject);
                }
                GXAuroraMirrorMark(g_sceneThisFrame ? AURORA_MIRROR_MARK_END : AURORA_MIRROR_MARK_NO_SCENE,
                                   g_camera.focus);
            }
        }
    } closeMirror;
    if (!enabled()) {
        return;
    }
    if (!g_sceneThisFrame) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    aurora::gfx::ResolvedTargets targets;
    if (!aurora::gfx::resolve_pass({.color = true, .depth = true}, targets) || !targets.color || !targets.depth) {
        return;
    }
    Slot& slot = g_slots[index];
    slot.pendingScene = targets.color;
    slot.pendingDepth = targets.depth;
    slot.sceneWidth = targets.width;
    slot.sceneHeight = targets.height;
    slot.camera = g_camera;
    // The fade (or the brightness's darkening) calcFade drew over the 3D scene, just before here
    // (m_Do_graphic.cpp, the camera pass): the window lays it on the glass over its own 3D. A
    // fade drawn over the HUD (isFade() & 0x80) comes later and is in the finished frame only.
    slot.fade[0] = slot.fade[1] = slot.fade[2] = slot.fade[3] = 0.f;
    if (std::strcmp(dComIfGp_getStartStageName(), "F_SP127") != 0 && (mDoGph_gInf_c::isFade() & 0x80) == 0) {
        const GXColor& fade = mDoGph_gInf_c::getFadeColor();
        slot.fade[0] = fade.r / 255.f;
        slot.fade[1] = fade.g / 255.f;
        slot.fade[2] = fade.b / 255.f;
        slot.fade[3] = fade.a / 255.f;
    }
    const TaskPayload payload{static_cast<uint32_t>(index)};
    g_scenePushed = aurora::gfx::push_encoder_task(g_sceneTask, &payload, sizeof(payload));
}

void after_hud() {
    if (!enabled()) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    Slot& slot = g_slots[index];
    if (g_sceneThisFrame && !g_scenePushed) {
        // A 3D frame whose scene didn't make it into this slot (no slot was free before the HUD,
        // or the snapshot failed): its finished frame and scene wouldn't match. Skip it. If its
        // base task is queued, that still uses the slot: the final task, with nothing to copy,
        // hands it back on the render worker after it.
        if (g_basePushed) {
            slot.pendingFinal = nullptr;
            slot.pendingUi = nullptr;
            const TaskPayload payload{static_cast<uint32_t>(index)};
            if (aurora::gfx::push_encoder_task(g_finalTask, &payload, sizeof(payload))) {
                return;
            }
        }
        std::lock_guard lock(g_mutex);
        slot.state = SlotState::Free;
        g_frameSlot = -1;
        return;
    }
    if (!g_sceneThisFrame) {
        // No scene task for this slot this frame: don't let its last use's scene through.
        slot.hasScene = false;
        slot.pendingScene = nullptr;
        slot.pendingDepth = nullptr;
    }
    if (!g_basePushed) {
        slot.hasBase = false;
        slot.pendingBase = nullptr;
    }
    aurora::gfx::ResolvedTargets targets;
    if (aurora::gfx::resolve_pass({.color = true}, targets) && targets.color) {
        slot.pendingFinal = targets.color;
        slot.finalWidth = targets.width;
        slot.finalHeight = targets.height;
    } else {
        slot.pendingFinal = nullptr;
    }
    // Dusklight's own menus (RmlUi) draw over the window's surface at present, outside the game's
    // frame: last frame's canvas, as VR's menu billboard uses it.
    slot.pendingUi = nullptr;
    if (dusk::ui::any_document_visible()) {
        const auto& canvas = aurora::rmlui::get_render_target();
        if (canvas.view && canvas.size.width > 0 && canvas.size.height > 0) {
            slot.pendingUi = canvas.view;
            slot.uiWidth = canvas.size.width;
            slot.uiHeight = canvas.size.height;
        }
    }
    slot.gameFrame = g_gameFrame;
    const TaskPayload payload{static_cast<uint32_t>(index)};
    if (!aurora::gfx::push_encoder_task(g_finalTask, &payload, sizeof(payload))) {
        // No pass to put it in: the scene task (if any) still ran, so its access ends with the next
        // frame's publish; give the slot back now.
        std::lock_guard lock(g_mutex);
        slot.state = SlotState::Free;
    }
}

}  // namespace dusk::visionos::window

using namespace dusk::visionos::window;

extern "C" {

void dusk_visionos_set_window_mode(bool enabled) {
    set_enabled(enabled);
}

void dusk_visionos_set_paused(bool paused) {
    aurora_set_external_pause(paused);
    g_held.store(paused && enabled());
}

void dusk_visionos_window_tick(void) {
    dispatch_semaphore_signal(g_tick);
}

bool dusk_visionos_window_acquire(dusk_visionos_window_frame* frame) {
    if (frame == nullptr) {
        return false;
    }
    std::lock_guard lock(g_mutex);
    if (g_latest < 0) {
        return false;
    }
    Slot& slot = g_slots[g_latest];
    if (slot.state != SlotState::Ready || slot.serial == g_handed) {
        return false;
    }
    slot.state = SlotState::Reading;
    g_handed = slot.serial;
    *frame = dusk_visionos_window_frame{};
    frame->serial = slot.serial;
    frame->generation = g_surfaceGeneration.load();
    frame->scene = slot.hasScene ? slot.scene.surface : nullptr;
    frame->distance = slot.hasScene ? slot.distance.surface : nullptr;
    frame->final = slot.final.surface;
    frame->ui = slot.hasUi ? slot.ui.surface : nullptr;
    frame->base = slot.hasScene && slot.hasBase ? slot.base.surface : nullptr;
    frame->event = slot.event;
    frame->value = slot.value;
    frame->tan_half_x = slot.camera.tanHalfX;
    frame->tan_half_y = slot.camera.tanHalfY;
    frame->focus = slot.camera.focus;
    frame->game_frame = slot.gameFrame;
    frame->fade_r = slot.fade[0];
    frame->fade_g = slot.fade[1];
    frame->fade_b = slot.fade[2];
    frame->fade_a = slot.fade[3];
    return true;
}

void dusk_visionos_set_mirror_enabled(bool enabled) {
    aurora::mirror::set_enabled(enabled);
}

void dusk_visionos_set_mirror_front_allowance(float widths, float min_view_tangent) {
    aurora::mirror::set_front_allowance(widths, min_view_tangent);
}

static_assert(sizeof(dusk_visionos_mirror_vertex) == sizeof(aurora::mirror::Vertex));
static_assert(sizeof(dusk_visionos_mirror_part) == sizeof(aurora::mirror::Part));
static_assert(offsetof(dusk_visionos_mirror_part, wrap_s) == offsetof(aurora::mirror::Part, wrapS));

bool dusk_visionos_mirror_acquire(dusk_visionos_mirror_frame* frame, uint32_t up_to) {
    static std::vector<dusk_visionos_mirror_texture> textures;
    aurora::mirror::Frame source;
    const bool ok = aurora::mirror::acquire(source, up_to);
    textures.clear();
    for (uint32_t i = 0; i < source.textureCount; ++i) {
        const auto& t = source.textures[i];
        textures.push_back({t.id, t.rgba, t.width, t.height, t.mipmapped, t.cutout});
    }
    *frame = {};
    frame->serial = source.serial;
    frame->game_frame = source.tag;
    frame->scene = source.scene;
    frame->vertices = reinterpret_cast<const dusk_visionos_mirror_vertex*>(source.vertices);
    frame->vertex_count = source.vertexCount;
    frame->indices = source.indices;
    frame->index_count = source.indexCount;
    frame->parts = reinterpret_cast<const dusk_visionos_mirror_part*>(source.parts);
    frame->part_count = source.partCount;
    std::copy(source.boundsMin, source.boundsMin + 3, frame->bounds_min);
    std::copy(source.boundsMax, source.boundsMax + 3, frame->bounds_max);
    frame->tan_half_x = source.tanHalfX;
    frame->tan_half_y = source.tanHalfY;
    frame->focus = source.focus;
    frame->plane = source.plane;
    frame->textures = textures.data();
    frame->texture_count = static_cast<uint32_t>(textures.size());
    frame->removed = source.removed;
    frame->removed_count = source.removedCount;
    return ok;
}

void dusk_visionos_window_release(uint64_t serial) {
    std::lock_guard lock(g_mutex);
    for (Slot& slot : g_slots) {
        if (slot.state == SlotState::Reading && slot.serial == serial) {
            slot.state = SlotState::Free;
        }
    }
}

}  // extern "C"
