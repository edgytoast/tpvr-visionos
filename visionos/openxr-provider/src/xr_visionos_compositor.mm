// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CompositorServices, ARKit and Metal half of the visionOS OpenXR
// provider: frames and drawables, the device pose and hands, and the render
// passes that put the runtime's layers onto the compositor's drawable.
//
// CompositorServices composites exactly one thing: the drawable the app
// renders for the frame. There is no quad layer and no retained layer, so
// every OpenXR layer the runtime submits is drawn into the drawable here: a
// projection layer as a full-view textured triangle pair sampling the eye's
// swapchain image (the swapchain images are IOSurfaces, wrapped in an
// MTLTexture in the swapchain's sRGB format, so a UNORM image Aurora wrote is
// decoded exactly as an OpenXR runtime would decode an sRGB swapchain), and a
// quad layer as a textured rectangle placed in the world with the eye's
// projection. Depth is written too, a constant for a projection layer and the
// quad's own for a quad, so the compositor can reproject the image for the
// head's motion between render and display.

#include "xr_visionos_internal.h"

#include <mach/mach_time.h>
#include <time.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace mkw::vr::visionos {

// ---------------------------------------------------------------------------
// Time

int64_t NowNanos() noexcept {
    // mach_absolute_time in nanoseconds: the clock behind cp_time_t and the
    // CFTimeInterval timestamps ARKit and CACurrentMediaTime speak.
    return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}

int64_t CpTimeToNanos(cp_time_t time) noexcept {
    return SecondsToNanos(cp_time_to_cf_time_interval(time));
}

int64_t MonotonicMinusXrTimeNanos() noexcept {
    // libc++'s steady_clock and the runtime's timespec conversions run on
    // CLOCK_MONOTONIC, which keeps counting through sleep where mach_absolute_time
    // does not; the two are related by an offset that only moves across a sleep.
    const int64_t monotonic = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC));
    const int64_t xr = NowNanos();
    return monotonic - xr;
}

// ---------------------------------------------------------------------------
// Poses

XrPosef IdentityPose() noexcept { return {{0.0f, 0.0f, 0.0f, 1.0f}, {0.0f, 0.0f, 0.0f}}; }

XrPosef PoseFromMatrix(const simd_float4x4& matrix) noexcept {
    // Orthonormalize the rotation before extracting the quaternion: a tracked
    // pose may carry a little scale/skew from float error.
    simd_float3 x = simd_normalize(matrix.columns[0].xyz);
    simd_float3 y = matrix.columns[1].xyz;
    simd_float3 z = simd_normalize(simd_cross(x, y));
    y = simd_normalize(simd_cross(z, x));
    const simd_float3x3 rotation = simd_matrix(x, y, z);
    const simd_quatf q = simd_quaternion(rotation);
    XrPosef pose{};
    pose.orientation = {q.vector.x, q.vector.y, q.vector.z, q.vector.w};
    pose.position = {matrix.columns[3].x, matrix.columns[3].y, matrix.columns[3].z};
    return pose;
}

simd_float4x4 MatrixFromPose(const XrPosef& pose) noexcept {
    const simd_quatf q = simd_quaternion(pose.orientation.x, pose.orientation.y, pose.orientation.z, pose.orientation.w);
    simd_float4x4 matrix = simd_matrix4x4(simd_normalize(q));
    matrix.columns[3] = simd_make_float4(pose.position.x, pose.position.y, pose.position.z, 1.0f);
    return matrix;
}

simd_float4x4 Inverse(const simd_float4x4& matrix) noexcept { return simd_inverse(matrix); }

// ---------------------------------------------------------------------------
// Logging

namespace {
std::mutex g_errorMutex;
std::string g_lastError;
} // namespace

void Log(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSLog(@"[mkw-visionos] %s", buffer);
}

void SetLastError(const std::string& message) {
    std::lock_guard lock(g_errorMutex);
    g_lastError = message;
    Log("%s", message.c_str());
}

} // namespace mkw::vr::visionos

const char* xr_visionos_last_error(void) {
    static thread_local std::string copy;
    std::lock_guard lock(mkw::vr::visionos::g_errorMutex);
    copy = mkw::vr::visionos::g_lastError;
    return copy.c_str();
}

void xr_visionos_set_anti_aliasing(int mode) {
    mkw::vr::visionos::Compositor::Get().SetAntiAliasing(mode);
}

void xr_visionos_set_safety_boundary(bool enabled) {
    mkw::vr::visionos::Compositor::Get().SetSafetyBoundary(enabled);
}

namespace mkw::vr::visionos {

// ---------------------------------------------------------------------------
// Shaders. Compiled at start-up from source: Metal's shading language is
// compiled by the system, so no metallib has to travel with the build.

namespace {

constexpr const char* kShaderSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;        // layer corner (-0.5..0.5, z 0) -> clip
    float4 uvRect;       // u0 v0 u1 v1 of the source rectangle
    float constantDepth; // NDC depth written when >= 0 (projection layers), else the transformed one
    uint slice;          // LAYERED: the drawable slice this view renders to
    uint viewport;       // LAYERED: the encoder viewport of this view
};

struct FragmentParams {
    float2 texel; // 1 / source size
    uint fxaa;    // smooth edges (projection layers, when anti-aliasing is FXAA)
    uint opaque;  // the layer has no source-alpha flag: its alpha is not meaningful
    float visibility; // the safety boundary's fade: 1 shows the frame, 0 the room
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
#if LAYERED
    uint slice [[render_target_array_index]];
    uint viewport [[viewport_array_index]];
#endif
};

// One instance per view: `views` holds every view's uniforms, and a draw's base
// instance picks the view (always 0 for the per-view passes).
vertex VertexOut layer_vertex(uint vid [[vertex_id]], uint view [[instance_id]],
                              constant Uniforms* views [[buffer(0)]]) {
    constant Uniforms& u = views[view];
    const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
    const float2 c = corners[vid];
    VertexOut out;
    out.position = u.mvp * float4(c.x, c.y, 0.0, 1.0);
    if (u.constantDepth >= 0.0) {
        out.position.z = u.constantDepth * out.position.w;
    }
    // Texture rows run top to bottom; the layer's top edge (c.y = +0.5) samples v0.
    out.uv = float2(mix(u.uvRect.x, u.uvRect.z, c.x + 0.5), mix(u.uvRect.w, u.uvRect.y, c.y + 0.5));
#if LAYERED
    out.slice = u.slice;
    out.viewport = u.viewport;
#endif
    return out;
}

// Perceptual luma of the linear colour an sRGB texture returns.
static float Luma(float3 colour) { return sqrt(dot(colour, float3(0.299, 0.587, 0.114))); }

// FXAA 3.11, console variant (as in the SHAR port): four diagonal taps find an
// edge, two or four along it smooth it. Cheap enough for two eyes at 90 Hz.
static float3 Fxaa(texture2d<float> source, sampler s, float2 uv, float2 texel) {
    const float3 rgbM = source.sample(s, uv).rgb;
    const float lumaM = Luma(rgbM);
    const float lumaNw = Luma(source.sample(s, uv + float2(-0.5, -0.5) * texel).rgb);
    const float lumaSw = Luma(source.sample(s, uv + float2(-0.5, 0.5) * texel).rgb);
    const float lumaNe = Luma(source.sample(s, uv + float2(0.5, -0.5) * texel).rgb) + 1.0 / 384.0;
    const float lumaSe = Luma(source.sample(s, uv + float2(0.5, 0.5) * texel).rgb);
    const float lumaMax = max(max(lumaNw, lumaSw), max(lumaNe, lumaSe));
    const float lumaMin = min(min(lumaNw, lumaSw), min(lumaNe, lumaSe));
    if (max(lumaMax, lumaM) - min(lumaMin, lumaM) < max(0.05, lumaMax * 0.125)) {
        return rgbM;
    }
    const float swMinusNe = lumaSw - lumaNe, seMinusNw = lumaSe - lumaNw;
    const float2 dir1 = normalize(float2(swMinusNe + seMinusNw, swMinusNe - seMinusNw));
    const float3 rgbA = source.sample(s, uv - dir1 * texel * 0.5).rgb + source.sample(s, uv + dir1 * texel * 0.5).rgb;
    const float2 dir2 = clamp(dir1 / (min(abs(dir1.x), abs(dir1.y)) * 8.0), -2.0, 2.0);
    const float3 rgbB = (source.sample(s, uv - dir2 * texel * 2.0).rgb + source.sample(s, uv + dir2 * texel * 2.0).rgb) * 0.25 +
                        rgbA * 0.25;
    const float lumaB = Luma(rgbB);
    return (lumaB < lumaMin || lumaB > lumaMax) ? rgbA * 0.5 : rgbB;
}

fragment float4 layer_fragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]],
                               sampler s [[sampler(0)]], constant FragmentParams& p [[buffer(0)]]) {
    float4 colour = image.sample(s, in.uv);
    if (p.fxaa != 0) {
        colour.rgb = Fxaa(image, s, in.uv, p.texel);
    }
    // OpenXR: without XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT a layer
    // is opaque whatever its alpha holds. Games leave alpha undefined (Dusklight's
    // is mostly 0), which a mixed or progressive space would show as see-through.
    if (p.opaque != 0) {
        colour.a = 1.0;
    }
    // Premultiplied, so scaling the whole colour fades it into what's behind.
    return colour * p.visibility;
}
)MSL";

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4 uvRect;
    float constantDepth;
    uint32_t slice;
    uint32_t viewport;
    uint32_t padding;
};
static_assert(sizeof(Uniforms) == 96, "Uniforms must match the shader's layout (and array stride)");

struct FragmentParams {
    simd_float2 texel;
    uint32_t fxaa;
    uint32_t opaque;
    float visibility;
    float padding;
};

// The safety boundary (xr_visionos_set_safety_boundary): horizontal distance
// from the space's origin where the frame starts fading into the room, and
// where it's gone. visionOS's own full-space boundary is about 1.5 m.
constexpr float kBoundaryFadeStartMeters = 1.2f;
constexpr float kBoundaryFadeEndMeters = 1.6f;

// Distance a projection layer's pixels are said to sit at, for the compositor's
// positional reprojection. OpenXR runtimes without a depth layer assume a fixed
// distance too; a diorama or a cockpit both live a few metres out.
constexpr float kProjectionLayerDepthMeters = 3.0f;

simd_float4x4 Scale(float x, float y, float z) noexcept {
    return simd_matrix(simd_make_float4(x, 0, 0, 0), simd_make_float4(0, y, 0, 0), simd_make_float4(0, 0, z, 0),
                       simd_make_float4(0, 0, 0, 1));
}

// The eye's frustum as OpenXR expresses it, read off the compositor's own
// projection so the two can never disagree about a sign or an order.
XrFovf FovFromProjection(const simd_float4x4& p) noexcept {
    // Column-major: p.columns[c][r]. For an off-axis perspective (right, up, back):
    //   p00 = 2/(r-l), p20 = (r+l)/(r-l), p11 = 2/(t-b), p21 = (t+b)/(t-b), tangents at unit depth.
    const float p00 = p.columns[0][0];
    const float p20 = p.columns[2][0];
    const float p11 = p.columns[1][1];
    const float p21 = p.columns[2][1];
    XrFovf fov{-0.785f, 0.785f, 0.785f, -0.785f};
    if (std::fabs(p00) > 1.0e-6f && std::fabs(p11) > 1.0e-6f) {
        const float width = 2.0f / p00;
        const float sum_x = p20 * width;
        const float height = 2.0f / p11;
        const float sum_y = p21 * height;
        const float left = (sum_x - width) * 0.5f;
        const float right = (sum_x + width) * 0.5f;
        const float bottom = (sum_y - height) * 0.5f;
        const float top = (sum_y + height) * 0.5f;
        fov.angleLeft = std::atan(left);
        fov.angleRight = std::atan(right);
        fov.angleUp = std::atan(top);
        fov.angleDown = std::atan(bottom);
    }
    return fov;
}

cp_drawable_t FirstDrawable(cp_frame_t frame) {
    if (@available(visionOS 26.0, *)) {
        cp_drawable_array_t drawables = cp_frame_query_drawables(frame);
        if (drawables == nullptr || cp_drawable_array_get_count(drawables) == 0) {
            return nullptr;
        }
        return cp_drawable_array_get_drawable(drawables, 0);
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
}

} // namespace

// ---------------------------------------------------------------------------

Compositor& Compositor::Get() {
    static Compositor compositor;
    return compositor;
}

Compositor::Compositor() = default;

void Compositor::SetLayerRenderer(cp_layer_renderer_t renderer) {
    std::lock_guard lock(m_mutex);
    m_renderer = renderer;
    m_viewsSeen = false;
}

cp_layer_renderer_t Compositor::LayerRenderer() const noexcept {
    std::lock_guard lock(m_mutex);
    return m_renderer;
}

LayerState Compositor::State() const noexcept {
    cp_layer_renderer_t renderer;
    {
        std::lock_guard lock(m_mutex);
        renderer = m_renderer;
    }
    if (renderer == nullptr) {
        return LayerState::Invalidated;
    }
    switch (cp_layer_renderer_get_state(renderer)) {
    case cp_layer_renderer_state_running:
        return LayerState::Running;
    case cp_layer_renderer_state_paused:
        return LayerState::Paused;
    default:
        return LayerState::Invalidated;
    }
}

bool Compositor::EnsureMetal() {
    if (m_device != nil && m_queue != nil) {
        return true;
    }
    m_device = MTLCreateSystemDefaultDevice();
    if (m_device == nil) {
        SetLastError("no Metal device");
        return false;
    }
    m_queue = [m_device newCommandQueue];
    m_queue.label = @"WiiCompiled compositor";
    MTLSamplerDescriptor* sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    m_sampler = [m_device newSamplerStateWithDescriptor:sampler];
    MTLDepthStencilDescriptor* depth = [MTLDepthStencilDescriptor new];
    depth.depthCompareFunction = MTLCompareFunctionAlways;
    depth.depthWriteEnabled = YES;
    m_depthState = [m_device newDepthStencilStateWithDescriptor:depth];
    return m_queue != nil;
}

bool Compositor::EnsurePipelines(MTLPixelFormat color, MTLPixelFormat depth) {
    if (m_opaquePipeline != nil && m_pipelineColor == color && m_pipelineDepth == depth) {
        return true;
    }
    // Two builds of the shader: per-view passes, and LAYERED for a layered drawable,
    // where one encoder covers every slice (what the progressive portal needs).
    const auto build = [&](bool layered, __strong id<MTLRenderPipelineState>& opaque,
                           __strong id<MTLRenderPipelineState>& blend) {
        NSError* error = nil;
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.preprocessorMacros = @{@"LAYERED" : layered ? @1 : @0};
        id<MTLLibrary> library = [m_device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSource]
                                                        options:options
                                                          error:&error];
        if (library == nil) {
            SetLastError(std::string("compositor shader compilation failed: ") +
                         (error != nil ? error.localizedDescription.UTF8String : "unknown"));
            return false;
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"layer_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"layer_fragment"];
        descriptor.colorAttachments[0].pixelFormat = color;
        descriptor.depthAttachmentPixelFormat = depth;
        if (layered) {
            // Required to route primitives to a slice from the vertex shader.
            descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        }
        descriptor.label = layered ? @"WiiCompiled layer (opaque, layered)" : @"WiiCompiled layer (opaque)";
        opaque = [m_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (opaque == nil) {
            SetLastError(std::string("compositor pipeline failed: ") +
                         (error != nil ? error.localizedDescription.UTF8String : "unknown"));
            return false;
        }
        // Premultiplied source-alpha blending, the OpenXR layer flag's semantics.
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.label = layered ? @"WiiCompiled layer (blended, layered)" : @"WiiCompiled layer (blended)";
        blend = [m_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (blend == nil) {
            SetLastError(std::string("compositor blend pipeline failed: ") +
                         (error != nil ? error.localizedDescription.UTF8String : "unknown"));
            return false;
        }
        return true;
    };
    m_opaquePipeline = nil;
    if (!build(false, m_opaquePipeline, m_blendPipeline)) {
        m_opaquePipeline = nil;
        return false;
    }
    // Layered rendering needs Apple5 GPUs and up (every Vision Pro); without it a
    // layered drawable falls back to a pass per slice.
    m_layeredOpaquePipeline = nil;
    m_layeredBlendPipeline = nil;
    if ([m_device supportsFamily:MTLGPUFamilyApple5] &&
        !build(true, m_layeredOpaquePipeline, m_layeredBlendPipeline)) {
        m_layeredOpaquePipeline = nil;
        m_layeredBlendPipeline = nil;
    }
    m_pipelineColor = color;
    m_pipelineDepth = depth;
    return true;
}

// ---------------------------------------------------------------------------
// ARKit

bool Compositor::StartTracking() {
    if (m_trackingStarted.load()) {
        return true;
    }
    std::lock_guard lock(m_mutex);
    if (m_trackingStarted.load()) {
        return true;
    }
    if (m_renderer == nullptr) {
        SetLastError("no layer renderer: the immersive space is not open");
        return false;
    }
    m_arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create();
    if (ar_world_tracking_provider_is_supported()) {
        ar_world_tracking_configuration_t config = ar_world_tracking_configuration_create();
        m_worldTracking = ar_world_tracking_provider_create(config);
        ar_data_providers_add_data_provider(providers, m_worldTracking);
    } else {
        SetLastError("world tracking is not supported here");
    }
    if (ar_hand_tracking_provider_is_supported()) {
        ar_hand_tracking_configuration_t config = ar_hand_tracking_configuration_create();
        m_handTracking = ar_hand_tracking_provider_create(config);
        ar_data_providers_add_data_provider(providers, m_handTracking);
        m_leftHand = ar_hand_anchor_create();
        m_rightHand = ar_hand_anchor_create();
        m_leftHandAt = ar_hand_anchor_create();
        m_rightHandAt = ar_hand_anchor_create();
    }
    m_deviceAnchor = ar_device_anchor_create();
    // Hand tracking asks the wearer once; the answer only decides whether the
    // hands reach the game. Running the session before the answer is fine: the
    // provider stays paused until it is allowed.
    std::atomic_bool* authorized = &m_handTrackingAuthorized;
    ar_session_request_authorization(m_arSession, ar_authorization_type_hand_tracking,
                                     ^(ar_authorization_results_t results, ar_error_t error) {
                                         if (error != nullptr || results == nullptr) {
                                             return;
                                         }
                                         ar_authorization_results_enumerate_results(
                                             results, ^bool(ar_authorization_result_t result) {
                                                 if (ar_authorization_result_get_authorization_type(result) ==
                                                         ar_authorization_type_hand_tracking &&
                                                     ar_authorization_result_get_status(result) ==
                                                         ar_authorization_status_allowed) {
                                                     authorized->store(true);
                                                 }
                                                 return true;
                                             });
                                     });
    ar_session_run(m_arSession, providers);
    m_trackingStarted.store(true);
    Log("ARKit session running (world tracking %s, hand tracking %s)", m_worldTracking ? "on" : "off",
        m_handTracking ? "requested" : "unsupported");
    return true;
}

void Compositor::StopTracking() {
    std::lock_guard lock(m_mutex);
    if (m_arSession != nullptr) {
        ar_session_stop(m_arSession);
    }
    m_arSession = nullptr;
    m_worldTracking = nullptr;
    m_handTracking = nullptr;
    m_deviceAnchor = nullptr;
    m_leftHand = nullptr;
    m_rightHand = nullptr;
    m_leftHandAt = nullptr;
    m_rightHandAt = nullptr;
    m_trackingStarted.store(false);
}

bool Compositor::DevicePose(int64_t timeNanos, simd_float4x4& worldFromDevice) noexcept {
    std::lock_guard lock(m_mutex);
    if (m_worldTracking == nullptr || m_deviceAnchor == nullptr ||
        ar_data_provider_get_state(m_worldTracking) != ar_data_provider_state_running) {
        return false;
    }
    const ar_device_anchor_query_status_t status = ar_world_tracking_provider_query_device_anchor_at_timestamp(
        m_worldTracking, NanosToSeconds(timeNanos), m_deviceAnchor);
    if (status != ar_device_anchor_query_status_success || !ar_trackable_anchor_is_tracked(m_deviceAnchor)) {
        return false;
    }
    worldFromDevice = ar_anchor_get_origin_from_anchor_transform(m_deviceAnchor);
    return true;
}

namespace {
HandJointSample JointSample(ar_hand_skeleton_t skeleton, const simd_float4x4& worldFromAnchor,
                            ar_hand_skeleton_joint_name_t name) noexcept {
    HandJointSample sample{};
    if (skeleton == nullptr) {
        return sample;
    }
    ar_skeleton_joint_t joint = ar_hand_skeleton_get_joint_named(skeleton, name);
    if (joint == nullptr) {
        return sample;
    }
    const simd_float4x4 anchorFromJoint = ar_skeleton_joint_get_anchor_from_joint_transform(joint);
    const simd_float4x4 worldFromJoint = simd_mul(worldFromAnchor, anchorFromJoint);
    sample.position = worldFromJoint.columns[3].xyz;
    sample.orientation = simd_normalize(simd_quaternion(worldFromJoint));
    sample.tracked = ar_skeleton_joint_is_tracked(joint);
    return sample;
}

// ARKit's joint for each XR_HAND_JOINT_*_EXT slot but the palm, which ARKit
// does not have. ARKit's "knuckle" is the metacarpophalangeal joint (OpenXR's
// proximal), its "intermediate base" and "intermediate tip" the two
// interphalangeal ones (OpenXR's intermediate and distal); the thumb's chain
// starts at its knuckle, which stands for OpenXR's thumb metacarpal.
struct JointName {
    XrHandJointEXT slot;
    ar_hand_skeleton_joint_name_t name;
};
constexpr std::array<JointName, kHandJointCount - 1> kJointNames{{
    {XR_HAND_JOINT_WRIST_EXT, ar_hand_skeleton_joint_name_wrist},
    {XR_HAND_JOINT_THUMB_METACARPAL_EXT, ar_hand_skeleton_joint_name_thumb_knuckle},
    {XR_HAND_JOINT_THUMB_PROXIMAL_EXT, ar_hand_skeleton_joint_name_thumb_intermediate_base},
    {XR_HAND_JOINT_THUMB_DISTAL_EXT, ar_hand_skeleton_joint_name_thumb_intermediate_tip},
    {XR_HAND_JOINT_THUMB_TIP_EXT, ar_hand_skeleton_joint_name_thumb_tip},
    {XR_HAND_JOINT_INDEX_METACARPAL_EXT, ar_hand_skeleton_joint_name_index_finger_metacarpal},
    {XR_HAND_JOINT_INDEX_PROXIMAL_EXT, ar_hand_skeleton_joint_name_index_finger_knuckle},
    {XR_HAND_JOINT_INDEX_INTERMEDIATE_EXT, ar_hand_skeleton_joint_name_index_finger_intermediate_base},
    {XR_HAND_JOINT_INDEX_DISTAL_EXT, ar_hand_skeleton_joint_name_index_finger_intermediate_tip},
    {XR_HAND_JOINT_INDEX_TIP_EXT, ar_hand_skeleton_joint_name_index_finger_tip},
    {XR_HAND_JOINT_MIDDLE_METACARPAL_EXT, ar_hand_skeleton_joint_name_middle_finger_metacarpal},
    {XR_HAND_JOINT_MIDDLE_PROXIMAL_EXT, ar_hand_skeleton_joint_name_middle_finger_knuckle},
    {XR_HAND_JOINT_MIDDLE_INTERMEDIATE_EXT, ar_hand_skeleton_joint_name_middle_finger_intermediate_base},
    {XR_HAND_JOINT_MIDDLE_DISTAL_EXT, ar_hand_skeleton_joint_name_middle_finger_intermediate_tip},
    {XR_HAND_JOINT_MIDDLE_TIP_EXT, ar_hand_skeleton_joint_name_middle_finger_tip},
    {XR_HAND_JOINT_RING_METACARPAL_EXT, ar_hand_skeleton_joint_name_ring_finger_metacarpal},
    {XR_HAND_JOINT_RING_PROXIMAL_EXT, ar_hand_skeleton_joint_name_ring_finger_knuckle},
    {XR_HAND_JOINT_RING_INTERMEDIATE_EXT, ar_hand_skeleton_joint_name_ring_finger_intermediate_base},
    {XR_HAND_JOINT_RING_DISTAL_EXT, ar_hand_skeleton_joint_name_ring_finger_intermediate_tip},
    {XR_HAND_JOINT_RING_TIP_EXT, ar_hand_skeleton_joint_name_ring_finger_tip},
    {XR_HAND_JOINT_LITTLE_METACARPAL_EXT, ar_hand_skeleton_joint_name_little_finger_metacarpal},
    {XR_HAND_JOINT_LITTLE_PROXIMAL_EXT, ar_hand_skeleton_joint_name_little_finger_knuckle},
    {XR_HAND_JOINT_LITTLE_INTERMEDIATE_EXT, ar_hand_skeleton_joint_name_little_finger_intermediate_base},
    {XR_HAND_JOINT_LITTLE_DISTAL_EXT, ar_hand_skeleton_joint_name_little_finger_intermediate_tip},
    {XR_HAND_JOINT_LITTLE_TIP_EXT, ar_hand_skeleton_joint_name_little_finger_tip},
}};

void ReadHand(ar_hand_anchor_t anchor, HandSample& sample) noexcept {
    sample = {};
    if (anchor == nullptr || !ar_trackable_anchor_is_tracked(anchor)) {
        return;
    }
    sample.tracked = true;
    const CFTimeInterval stamp = ar_anchor_get_timestamp(anchor);
    sample.timeNanos = stamp > 0.0 ? SecondsToNanos(stamp) : NowNanos();
    sample.worldFromAnchor = ar_anchor_get_origin_from_anchor_transform(anchor);
    ar_hand_skeleton_t skeleton = ar_hand_anchor_get_hand_skeleton(anchor);
    for (const JointName& entry : kJointNames) {
        sample.joints[static_cast<size_t>(entry.slot)] = JointSample(skeleton, sample.worldFromAnchor, entry.name);
    }
    // The palm: the middle of the hand, between the wrist and the middle
    // finger's knuckle (where HandFrame puts the grip too), with the wrist's
    // orientation. Only its position matters: the grasp and the flick read
    // positions, and visionOS draws no hand of its own.
    const HandJointSample& wrist = sample.wrist();
    const HandJointSample& knuckle = sample.middleKnuckle();
    HandJointSample& palm = sample.joints[XR_HAND_JOINT_PALM_EXT];
    palm.tracked = wrist.tracked && knuckle.tracked;
    palm.position = (wrist.position + knuckle.position) * 0.5f;
    palm.orientation = wrist.orientation;
}
} // namespace

void Compositor::Hands(std::array<HandSample, 2>& hands) noexcept {
    std::lock_guard lock(m_mutex);
    hands = {};
    if (m_handTracking == nullptr || m_leftHand == nullptr || m_rightHand == nullptr ||
        ar_data_provider_get_state(m_handTracking) != ar_data_provider_state_running) {
        return;
    }
    // The latest anchors are consumed by this call; a frame without a new one
    // keeps the previous sample, which the caller holds.
    if (!ar_hand_tracking_provider_get_latest_anchors(m_handTracking, m_leftHand, m_rightHand)) {
        return;
    }
    ReadHand(m_leftHand, hands[0]);
    ReadHand(m_rightHand, hands[1]);
}

bool Compositor::HandsAt(int64_t timeNanos, std::array<HandSample, 2>& hands) noexcept {
    std::lock_guard lock(m_mutex);
    hands = {};
    if (m_handTracking == nullptr || m_leftHandAt == nullptr || m_rightHandAt == nullptr ||
        ar_data_provider_get_state(m_handTracking) != ar_data_provider_state_running) {
        return false;
    }
    if (ar_hand_tracking_provider_query_anchors_at_timestamp(m_handTracking, NanosToSeconds(timeNanos), m_leftHandAt,
                                                             m_rightHandAt) != ar_hand_anchor_query_status_success) {
        return false;
    }
    ReadHand(m_leftHandAt, hands[0]);
    ReadHand(m_rightHandAt, hands[1]);
    // The anchors carry the time they were measured at; the sample stands for
    // the time it was asked for.
    for (HandSample& hand : hands) {
        if (hand.tracked) {
            hand.timeNanos = timeNanos;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Frames

void Compositor::ReadViewGeometry(cp_drawable_t drawable) {
    const size_t count = std::min<size_t>(cp_drawable_get_view_count(drawable), kViewCount);
    for (size_t i = 0; i < count; ++i) {
        cp_view_t view = cp_drawable_get_view(drawable, i);
        ViewGeometry& geometry = m_views[i];
        geometry.deviceFromView = cp_view_get_transform(view);
        const simd_float4x4 projection =
            cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, i);
        geometry.fov = FovFromProjection(projection);
        cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
        const MTLViewport viewport = cp_view_texture_map_get_viewport(map);
        geometry.width = static_cast<uint32_t>(std::lround(viewport.width));
        geometry.height = static_cast<uint32_t>(std::lround(viewport.height));
        if (geometry.width == 0 || geometry.height == 0) {
            id<MTLTexture> texture = cp_drawable_get_color_texture(drawable, cp_view_texture_map_get_texture_index(map));
            geometry.width = static_cast<uint32_t>(texture.width);
            geometry.height = static_cast<uint32_t>(texture.height);
        }
        geometry.valid = true;
    }
    if (count == 1) {
        m_views[1] = m_views[0];
    }
    m_viewsSeen = true;
}

std::array<ViewGeometry, kViewCount> Compositor::ViewGeometries() {
    {
        std::lock_guard lock(m_mutex);
        if (m_viewsSeen) {
            return m_views;
        }
    }
    // Nothing has been drawn yet: take one frame, read its drawable, and present
    // it empty so the compositor's frame accounting stays whole.
    int64_t display = 0;
    int64_t period = 0;
    if (WaitFrame(display, period) && BeginFrame()) {
        EndFrame({}, true);
    }
    std::lock_guard lock(m_mutex);
    return m_views;
}

bool Compositor::WaitFrame(int64_t& predictedDisplayNanos, int64_t& predictedPeriodNanos) {
    cp_layer_renderer_t renderer;
    bool leftover = false;
    {
        std::lock_guard lock(m_mutex);
        renderer = m_renderer;
        leftover = m_frame != nullptr;
        predictedPeriodNanos = m_periodNanos;
    }
    if (leftover) {
        // A frame left open (the caller's protocol broke): present it empty first.
        Log("WaitFrame with a frame still open; presenting it empty");
        EndFrame({}, true);
    }
    if (renderer == nullptr || cp_layer_renderer_get_state(renderer) != cp_layer_renderer_state_running) {
        return false;
    }
    // Blocks until the compositor wants the next frame: this is the display pacing.
    cp_frame_t frame = cp_layer_renderer_query_next_frame(renderer);
    if (frame == nullptr) {
        return false;
    }
    cp_frame_timing_t timing = cp_frame_predict_timing(frame);
    if (timing == nullptr) {
        // No timing means the layer went away underneath us; the frame is dropped.
        return false;
    }
    cp_frame_start_update(frame);
    const int64_t presentation = CpTimeToNanos(cp_frame_timing_get_presentation_time(timing));
    std::lock_guard lock(m_mutex);
    if (m_lastPresentationNanos != 0 && presentation > m_lastPresentationNanos) {
        const int64_t delta = presentation - m_lastPresentationNanos;
        // One frame's worth of movement between two predicted deadlines, kept to the
        // headset's plausible refresh range (100 Hz to 45 Hz).
        if (delta >= 9'000'000 && delta <= 23'000'000) {
            m_periodNanos = delta;
        }
    }
    m_lastPresentationNanos = presentation;
    m_frame = frame;
    m_timing = timing;
    predictedDisplayNanos = presentation;
    predictedPeriodNanos = m_periodNanos;
    return true;
}

bool Compositor::BeginFrame() {
    cp_frame_t frame;
    cp_frame_timing_t timing;
    {
        std::lock_guard lock(m_mutex);
        frame = m_frame;
        timing = m_timing;
    }
    if (frame == nullptr) {
        return false;
    }
    cp_frame_end_update(frame);
    // The compositor's own advice for when to sample the pose and start submitting.
    cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
    cp_frame_start_submission(frame);
    cp_drawable_t drawable = FirstDrawable(frame);
    std::lock_guard lock(m_mutex);
    m_drawable = drawable;
    if (drawable == nullptr) {
        // The layer paused between the two calls. The frame is ended without content.
        cp_frame_end_submission(frame);
        m_frame = nullptr;
        m_timing = nullptr;
        return false;
    }
    // The drawable's timing supersedes the prediction made at query time.
    m_timing = cp_drawable_get_frame_timing(drawable);
    m_lastPresentationNanos = CpTimeToNanos(cp_frame_timing_get_presentation_time(m_timing));
    ReadViewGeometry(drawable);
    return true;
}

namespace {

// The system's render context, which draws what the compositor adds to an app's
// frame: on visionOS 26 the edge of the progressive-immersion portal. It needs
// the whole drawable in one encoder (a layered drawable, or the Simulator's one
// view) and the device anchor already set on the drawable.
cp_drawable_render_context_t AddRenderContext(cp_drawable_t drawable, id<MTLCommandBuffer> commandBuffer) {
    if (@available(visionOS 26.0, *)) {
        return cp_drawable_add_render_context(drawable, commandBuffer);
    }
    return nullptr;
}

void EndEncoding(cp_drawable_render_context_t context, id<MTLRenderCommandEncoder> encoder) {
    if (context != nullptr) {
        if (@available(visionOS 26.0, *)) {
            // Takes the encoder over and ends it.
            cp_drawable_render_context_end_encoding(context, encoder);
            return;
        }
    }
    [encoder endEncoding];
}

// Where `layer` lands in one view: `projection` and `viewFromWorld` are the
// view's, `worldFromDevice` the pose the frame is drawn for.
Uniforms LayerUniforms(const ComposedLayer& layer, const ComposedLayer::Image& image,
                       const simd_float4x4& projection, const simd_float4x4& viewFromWorld,
                       const simd_float4x4& worldFromDevice) {
    Uniforms uniforms{};
    const float u0 = static_cast<float>(image.rect.offset.x) / static_cast<float>(image.texture.width);
    const float v0 = static_cast<float>(image.rect.offset.y) / static_cast<float>(image.texture.height);
    const float u1 = static_cast<float>(image.rect.offset.x + image.rect.extent.width) /
                     static_cast<float>(image.texture.width);
    const float v1 = static_cast<float>(image.rect.offset.y + image.rect.extent.height) /
                     static_cast<float>(image.texture.height);
    uniforms.uvRect = simd_make_float4(u0, v0, u1, v1);
    if (layer.kind == ComposedLayer::Kind::Projection) {
        // The eye was rendered from image.worldFromLayer with image.fov. The image
        // is placed in the world where that frustum cuts a plane
        // kProjectionLayerDepthMeters away, and drawn from this frame's own pose:
        // a frame the runtime shows again while the game lags the display, or one
        // whose predicted pose the head has since left, stays where it was
        // rendered instead of following the head (the judder of a head-locked
        // quad). The depth written is the plane's, for the compositor's own
        // late reprojection.
        const float d = kProjectionLayerDepthMeters;
        const float left = d * std::tan(image.fov.angleLeft);
        const float right = d * std::tan(image.fov.angleRight);
        const float down = d * std::tan(image.fov.angleDown);
        const float up = d * std::tan(image.fov.angleUp);
        simd_float4x4 layerFromCorner = Scale(right - left, up - down, 1.0f);
        layerFromCorner.columns[3] = simd_make_float4((right + left) * 0.5f, (up + down) * 0.5f, -d, 1.0f);
        uniforms.mvp = simd_mul(projection, simd_mul(viewFromWorld, simd_mul(image.worldFromLayer, layerFromCorner)));
    } else {
        simd_float4x4 worldFromQuad = image.worldFromLayer;
        if (layer.headLocked) {
            worldFromQuad = simd_mul(worldFromDevice, image.worldFromLayer);
        }
        const simd_float4x4 quadScale = Scale(layer.quadWidth, layer.quadHeight, 1.0f);
        uniforms.mvp = simd_mul(projection, simd_mul(viewFromWorld, simd_mul(worldFromQuad, quadScale)));
    }
    uniforms.constantDepth = -1.0f;
    return uniforms;
}

const ComposedLayer::Image& LayerImage(const ComposedLayer& layer, size_t viewIndex) {
    return layer.kind == ComposedLayer::Kind::Projection ? layer.images[std::min<size_t>(viewIndex, kViewCount - 1)]
                                                         : layer.images[0];
}

// TPVR_GPU_TIMING=1: logs the GPU time of the compositor's frames (eye images
// to drawable, SMAA included), averaged over every 240, to compare anti-aliasing
// modes and render scales on the headset.
void AddGpuTiming(id<MTLCommandBuffer> commandBuffer, int antiAliasing) {
    static const bool enabled = std::getenv("TPVR_GPU_TIMING") != nullptr;
    if (!enabled) {
        return;
    }
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        static std::mutex mutex;
        static double totalMs = 0.0;
        static double maxMs = 0.0;
        static int frames = 0;
        const double ms = (buffer.GPUEndTime - buffer.GPUStartTime) * 1000.0;
        std::lock_guard lock(mutex);
        totalMs += ms;
        maxMs = std::max(maxMs, ms);
        if (++frames == 240) {
            Log("compositor GPU %.3f ms average, %.3f ms worst over 240 frames (anti-aliasing %d)",
                totalMs / frames, maxMs, antiAliasing);
            totalMs = maxMs = 0.0;
            frames = 0;
        }
    }];
}

FragmentParams LayerFragmentParams(const ComposedLayer& layer, const ComposedLayer::Image& image, int antiAliasing,
                                   float visibility) {
    FragmentParams params{};
    params.texel = simd_make_float2(1.0f / static_cast<float>(image.texture.width),
                                    1.0f / static_cast<float>(image.texture.height));
    // The game's eyes only: a quad is a menu or a screen, already sharp text. And
    // only opaque ones: FXAA smooths colour but not alpha, so on a see-through
    // layer (menus over the room) it would leave a glowing fringe outside edges.
    params.fxaa = antiAliasing == 1 && layer.kind == ComposedLayer::Kind::Projection && !layer.alphaBlend ? 1u : 0u;
    params.opaque = layer.alphaBlend ? 0u : 1u;
    params.visibility = visibility;
    return params;
}

} // namespace

void Compositor::PresentEmpty(cp_frame_t frame, cp_drawable_t drawable, bool alphaBlend, bool posed) {
    if (!EnsureMetal()) {
        cp_frame_end_submission(frame);
        return;
    }
    id<MTLCommandBuffer> commandBuffer = [m_queue commandBuffer];
    const size_t textures = cp_drawable_get_texture_count(drawable);
    const bool oneEncoder =
        textures == 1 && (cp_drawable_get_view_count(drawable) == 1 ||
                          cp_drawable_get_color_texture(drawable, 0).textureType == MTLTextureType2DArray);
    for (size_t i = 0; i < textures; ++i) {
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLTexture> color = cp_drawable_get_color_texture(drawable, i);
        id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, i);
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, alphaBlend ? 0 : m_visibility);
        if (depth != nil) {
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = 0.0; // reverse-Z: nothing, at infinity
        }
        if (color.textureType == MTLTextureType2DArray) {
            pass.renderTargetArrayLength = color.arrayLength;
        }
        if (cp_drawable_get_rasterization_rate_map_count(drawable) > i) {
            pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(drawable, i);
        }
        cp_drawable_render_context_t context =
            oneEncoder && posed && depth != nil ? AddRenderContext(drawable, commandBuffer) : nullptr;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        EndEncoding(context, encoder);
    }
    cp_drawable_encode_present(drawable, commandBuffer);
    [commandBuffer commit];
    cp_frame_end_submission(frame);
}

void Compositor::EndFrame(const std::vector<ComposedLayer>& layers, bool alphaBlend) {
    cp_frame_t frame;
    cp_drawable_t drawable;
    cp_frame_timing_t timing;
    {
        std::lock_guard lock(m_mutex);
        frame = m_frame;
        drawable = m_drawable;
        timing = m_timing;
        m_frame = nullptr;
        m_drawable = nullptr;
        m_timing = nullptr;
    }
    if (frame == nullptr) {
        return;
    }
    if (drawable == nullptr) {
        // BeginFrame never ran (WaitFrame alone, then EndFrame): open and close the
        // submission so the frame is consumed.
        cp_frame_end_update(frame);
        cp_frame_start_submission(frame);
        drawable = FirstDrawable(frame);
        if (drawable == nullptr) {
            cp_frame_end_submission(frame);
            return;
        }
        timing = cp_drawable_get_frame_timing(drawable);
    }
    // The pose the compositor should assume the frame was rendered for. Set even
    // for an empty frame: it is what lets the compositor keep the last image
    // steady in the world while nothing new arrives.
    simd_float4x4 worldFromDevice = matrix_identity_float4x4;
    const int64_t presentation = timing != nullptr ? CpTimeToNanos(cp_frame_timing_get_presentation_time(timing))
                                                   : NowNanos();
    bool posed = DevicePose(presentation, worldFromDevice);
    {
        std::lock_guard lock(m_mutex);
        if (posed && m_deviceAnchor != nullptr) {
            cp_drawable_set_device_anchor(drawable, m_deviceAnchor);
        } else {
            posed = false;
        }
    }
    // The safety boundary: away from the origin, the room shows through.
    if (m_safetyBoundary.load() && posed) {
        const simd_float4 position = worldFromDevice.columns[3];
        const float distance = std::sqrt(position.x * position.x + position.z * position.z);
        m_visibility = 1.0f - std::clamp((distance - kBoundaryFadeStartMeters) /
                                             (kBoundaryFadeEndMeters - kBoundaryFadeStartMeters),
                                         0.0f, 1.0f);
    } else if (!m_safetyBoundary.load()) {
        m_visibility = 1.0f;
    }
    if (layers.empty() || !posed) {
        PresentEmpty(frame, drawable, alphaBlend, posed);
        return;
    }
    if (!EnsureMetal()) {
        cp_frame_end_submission(frame);
        return;
    }
    id<MTLTexture> firstColor = cp_drawable_get_color_texture(drawable, 0);
    id<MTLTexture> firstDepth = cp_drawable_get_depth_texture(drawable, 0);
    if (!EnsurePipelines(firstColor.pixelFormat, firstDepth != nil ? firstDepth.pixelFormat : MTLPixelFormatInvalid)) {
        PresentEmpty(frame, drawable, alphaBlend, posed);
        return;
    }
    id<MTLCommandBuffer> commandBuffer = [m_queue commandBuffer];
    commandBuffer.label = @"WiiCompiled frame";
    // Every wait first: Metal orders them before the encoders that follow.
    for (const ComposedLayer& layer : layers) {
        for (const ComposedLayer::Image& image : layer.images) {
            if (image.writeEvent != nil) {
                [commandBuffer encodeWaitForEvent:image.writeEvent value:image.writeValue];
            }
        }
    }
    // SMAA: the projection layers' images are smoothed into copies first, and
    // those are what gets drawn.
    const std::vector<ComposedLayer>* drawn = &layers;
    std::vector<ComposedLayer> smoothed;
    if (m_antiAliasing.load() == 2) {
        smoothed = layers;
        std::array<id<MTLTexture>, kViewCount> sources{};
        std::array<id<MTLTexture>, kViewCount> outputs{};
        size_t used = 0;
        for (ComposedLayer& layer : smoothed) {
            if (layer.kind != ComposedLayer::Kind::Projection) {
                continue;
            }
            for (ComposedLayer::Image& image : layer.images) {
                if (image.texture == nil) {
                    continue;
                }
                size_t slot = 0;
                while (slot < used && sources[slot] != image.texture) {
                    ++slot;
                }
                if (slot == used) {
                    if (used == kViewCount) {
                        continue; // more images than targets: this one is drawn as it is
                    }
                    sources[used] = image.texture;
                    outputs[used] = m_smaa.Encode(commandBuffer, image.texture, used);
                    ++used;
                }
                image.texture = outputs[slot];
            }
        }
        drawn = &smoothed;
    }
    const bool layered = cp_drawable_get_texture_count(drawable) == 1 &&
                         firstColor.textureType == MTLTextureType2DArray && m_layeredOpaquePipeline != nil;
    if (layered) {
        DrawLayersLayered(drawable, commandBuffer, *drawn, alphaBlend, worldFromDevice);
    } else {
        DrawLayers(drawable, commandBuffer, *drawn, alphaBlend, worldFromDevice);
    }
    // The reads are done once this command buffer has run: signal each image's
    // read event so the writer's next copy into it waits for us.
    for (const ComposedLayer& layer : layers) {
        for (const ComposedLayer::Image& image : layer.images) {
            if (image.readEvent != nil && image.readValue != 0) {
                [commandBuffer encodeSignalEvent:image.readEvent value:image.readValue];
            }
        }
    }
    cp_drawable_encode_present(drawable, commandBuffer);
    AddGpuTiming(commandBuffer, m_antiAliasing.load());
    [commandBuffer commit];
    cp_frame_end_submission(frame);
}

void Compositor::DrawLayers(cp_drawable_t drawable, id<MTLCommandBuffer> commandBuffer,
                            const std::vector<ComposedLayer>& layers, bool alphaBlend,
                            const simd_float4x4& worldFromDevice) {
    const size_t viewCount = std::min<size_t>(cp_drawable_get_view_count(drawable), kViewCount);
    const size_t textureCount = cp_drawable_get_texture_count(drawable);
    std::vector<bool> cleared(textureCount, false);
    const simd_float4x4 deviceFromWorld = simd_inverse(worldFromDevice);
    const int antiAliasing = m_antiAliasing.load();
    // One view in one texture (the Simulator): its one encoder can carry the render context.
    const bool singleView = viewCount == 1 && textureCount == 1;

    for (size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
        cp_view_t view = cp_drawable_get_view(drawable, viewIndex);
        cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
        const size_t textureIndex = cp_view_texture_map_get_texture_index(map);
        const size_t slice = cp_view_texture_map_get_slice_index(map);
        const MTLViewport viewport = cp_view_texture_map_get_viewport(map);
        id<MTLTexture> color = cp_drawable_get_color_texture(drawable, textureIndex);
        id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, textureIndex);
        const simd_float4x4 projection =
            cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, viewIndex);
        const simd_float4x4 deviceFromView = cp_view_get_transform(view);
        const simd_float4x4 viewFromWorld = simd_mul(simd_inverse(deviceFromView), deviceFromWorld);

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].slice = slice;
        // Foveation: the texture's own rasterization rate map, under which the
        // viewport is in screen space and the eye images sharper where you look.
        if (cp_drawable_get_rasterization_rate_map_count(drawable) > textureIndex) {
            pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(drawable, textureIndex);
        }
        if (depth != nil) {
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.slice = slice;
        }
        // A shared texture holds both views side by side; the first pass clears it whole.
        const bool first = textureIndex < cleared.size() && !cleared[textureIndex] && color.textureType != MTLTextureType2DArray;
        const bool firstSlice = color.textureType == MTLTextureType2DArray;
        if (first || firstSlice) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, alphaBlend ? 0 : m_visibility);
            if (depth != nil) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = 0.0;
            }
            if (textureIndex < cleared.size()) {
                cleared[textureIndex] = true;
            }
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            if (depth != nil) {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        cp_drawable_render_context_t context =
            singleView && depth != nil ? AddRenderContext(drawable, commandBuffer) : nullptr;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        encoder.label = viewIndex == 0 ? @"left eye" : @"right eye";
        [encoder setViewport:viewport];
        [encoder setScissorRect:MTLScissorRect{static_cast<NSUInteger>(viewport.originX),
                                               static_cast<NSUInteger>(viewport.originY),
                                               static_cast<NSUInteger>(viewport.width),
                                               static_cast<NSUInteger>(viewport.height)}];
        [encoder setDepthStencilState:m_depthState];
        [encoder setFragmentSamplerState:m_sampler atIndex:0];
        [encoder setCullMode:MTLCullModeNone];

        for (const ComposedLayer& layer : layers) {
            const ComposedLayer::Image& image = LayerImage(layer, viewIndex);
            if (image.texture == nil) {
                continue;
            }
            const Uniforms uniforms = LayerUniforms(layer, image, projection, viewFromWorld, worldFromDevice);
            const FragmentParams params = LayerFragmentParams(layer, image, antiAliasing, m_visibility);
            [encoder setRenderPipelineState:layer.alphaBlend ? m_blendPipeline : m_opaquePipeline];
            [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
            [encoder setFragmentTexture:image.texture atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        EndEncoding(context, encoder);
    }
}

void Compositor::DrawLayersLayered(cp_drawable_t drawable, id<MTLCommandBuffer> commandBuffer,
                                   const std::vector<ComposedLayer>& layers, bool alphaBlend,
                                   const simd_float4x4& worldFromDevice) {
    // A layered drawable: one texture, a slice per view, drawn by one encoder so
    // the system's render context (the progressive portal) can finish it.
    const size_t viewCount = std::min<size_t>(cp_drawable_get_view_count(drawable), kViewCount);
    const simd_float4x4 deviceFromWorld = simd_inverse(worldFromDevice);
    const int antiAliasing = m_antiAliasing.load();
    id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
    id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);

    std::array<simd_float4x4, kViewCount> projections{};
    std::array<simd_float4x4, kViewCount> viewsFromWorld{};
    std::array<uint32_t, kViewCount> slices{};
    std::array<MTLViewport, kViewCount> viewports{};
    for (size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
        cp_view_t view = cp_drawable_get_view(drawable, viewIndex);
        cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
        slices[viewIndex] = static_cast<uint32_t>(cp_view_texture_map_get_slice_index(map));
        viewports[viewIndex] = cp_view_texture_map_get_viewport(map);
        projections[viewIndex] =
            cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, viewIndex);
        viewsFromWorld[viewIndex] = simd_mul(simd_inverse(cp_view_get_transform(view)), deviceFromWorld);
    }

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, alphaBlend ? 0 : m_visibility);
    if (depth != nil) {
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 0.0;
    }
    pass.renderTargetArrayLength = color.arrayLength;
    if (cp_drawable_get_rasterization_rate_map_count(drawable) > 0) {
        pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(drawable, 0);
    }
    cp_drawable_render_context_t context = depth != nil ? AddRenderContext(drawable, commandBuffer) : nullptr;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    encoder.label = @"both eyes";
    [encoder setViewports:viewports.data() count:viewCount];
    [encoder setDepthStencilState:m_depthState];
    [encoder setFragmentSamplerState:m_sampler atIndex:0];
    [encoder setCullMode:MTLCullModeNone];

    for (const ComposedLayer& layer : layers) {
        std::array<Uniforms, kViewCount> uniforms{};
        for (size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            const ComposedLayer::Image& image = LayerImage(layer, viewIndex);
            if (image.texture == nil) {
                continue;
            }
            uniforms[viewIndex] =
                LayerUniforms(layer, image, projections[viewIndex], viewsFromWorld[viewIndex], worldFromDevice);
            uniforms[viewIndex].slice = slices[viewIndex];
            uniforms[viewIndex].viewport = static_cast<uint32_t>(viewIndex);
        }
        [encoder setRenderPipelineState:layer.alphaBlend ? m_layeredBlendPipeline : m_layeredOpaquePipeline];
        [encoder setVertexBytes:uniforms.data() length:sizeof(Uniforms) * viewCount atIndex:0];
        // A draw per view, its base instance picking the view's uniforms: each eye of
        // a projection layer may be its own texture.
        for (size_t viewIndex = 0; viewIndex < viewCount; ++viewIndex) {
            const ComposedLayer::Image& image = LayerImage(layer, viewIndex);
            if (image.texture == nil) {
                continue;
            }
            const FragmentParams params = LayerFragmentParams(layer, image, antiAliasing, m_visibility);
            [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
            [encoder setFragmentTexture:image.texture atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                        vertexStart:0
                        vertexCount:4
                      instanceCount:1
                       baseInstance:viewIndex];
        }
    }
    EndEncoding(context, encoder);
}

} // namespace mkw::vr::visionos
