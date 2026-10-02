// The game in a visionOS window: see visionos_window.hpp.
//
// Data path, per frame:
//   game thread   begin_frame()  waits for the window's tick (the app's RealityKit update)
//                 note_scene()   the camera's projection and focus, if a 3D scene is drawn
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

#include "dusk/visionos/visionos_host.h"
#include "dusk/visionos/visionos_sense_pad.hpp"
#include "dusk/ui/ui.hpp"
#include "f_op/f_op_view.h"

#include "../../../extern/aurora/lib/rmlui.hpp"
#include <aurora/aurora.h>
#include <aurora/gfx.hpp>
#include <aurora/mirror.h>
#include <dolphin/gx/GXAurora.h>
#include <webgpu/webgpu_cpp.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstddef>
#include <mutex>
#include <vector>

#define WINDOW_LOG(...) std::fprintf(stderr, "[dusk::visionos::window] " __VA_ARGS__)

namespace dusk::visionos::window {
namespace {

std::atomic_bool g_enabled{false};
dispatch_semaphore_t g_tick = dispatch_semaphore_create(0);
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
};

// A frame on its way to the app. While Writing it belongs to the game thread (which fills the
// pending fields) and then the render worker; Ready and Reading belong to the app.
struct Slot {
    SlotState state = SlotState::Free;
    Surface scene, distance, final, ui;
    wgpu::Buffer uniforms;
    uint64_t serial = 0;
    CameraInfo camera;
    bool hasScene = false, hasUi = false, hasFinal = false;
    void* event = nullptr;  // MTLSharedEvent (Dawn's), borrowed
    uint64_t value = 0;
    // Snapshots taken on the game thread, copied on the render worker.
    wgpu::TextureView pendingScene, pendingDepth, pendingFinal, pendingUi;
    uint32_t sceneWidth = 0, sceneHeight = 0, finalWidth = 0, finalHeight = 0, uiWidth = 0, uiHeight = 0;
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
bool g_mirrorBegun = false;  // a scene-mirror frame was opened this frame, and must be closed
CameraInfo g_camera;

aurora::gfx::EncoderTaskId g_sceneTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_finalTask = aurora::gfx::InvalidEncoderTask;

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
    slot.pendingScene = nullptr;
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
    g_frameSlot = -1;
    g_sceneThisFrame = false;
    g_scenePushed = false;
    // The Sense controllers, if any, as a gamepad (no controller tracking outside a Full Space).
    sense_pad::update();
    // The scene mirror records the frame's draws from here to before_hud().
    if (aurora::mirror::enabled()) {
        GXAuroraMirrorMark(AURORA_MIRROR_MARK_BEGIN, 0.0f);
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
}

void before_hud() {
    // The scene mirror's frame ends here, whatever happens below, once the snapshots are taken:
    // their resolves wait for the FIFO, and the mirror's finishing work then overlaps the HUD.
    struct CloseMirror {
        ~CloseMirror() {
            if (g_mirrorBegun) {
                g_mirrorBegun = false;
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
    // The shadows the mirror's draws project, read back for the window.
    aurora::mirror::capture_copies();
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
        // or the snapshot failed): its finished frame and scene wouldn't match. Skip it.
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
    frame->event = slot.event;
    frame->value = slot.value;
    frame->tan_half_x = slot.camera.tanHalfX;
    frame->tan_half_y = slot.camera.tanHalfY;
    frame->focus = slot.camera.focus;
    return true;
}

void dusk_visionos_set_mirror_enabled(bool enabled) {
    aurora::mirror::set_enabled(enabled);
}

static_assert(sizeof(dusk_visionos_mirror_vertex) == sizeof(aurora::mirror::Vertex));
static_assert(sizeof(dusk_visionos_mirror_part) == sizeof(aurora::mirror::Part));
static_assert(offsetof(dusk_visionos_mirror_part, wrap_s) == offsetof(aurora::mirror::Part, wrapS));

bool dusk_visionos_mirror_acquire(dusk_visionos_mirror_frame* frame) {
    static std::vector<dusk_visionos_mirror_texture> textures;
    aurora::mirror::Frame source;
    const bool ok = aurora::mirror::acquire(source);
    textures.clear();
    for (uint32_t i = 0; i < source.textureCount; ++i) {
        const auto& t = source.textures[i];
        textures.push_back({t.id, t.rgba, t.width, t.height, t.mipmapped, t.cutout});
    }
    *frame = {};
    frame->serial = source.serial;
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
