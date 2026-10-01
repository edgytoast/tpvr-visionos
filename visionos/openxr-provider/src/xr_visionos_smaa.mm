// SPDX-License-Identifier: GPL-3.0-or-later
//
// SMAA 1x for the compositor's projection layers (xr_visionos_set_anti_aliasing
// mode 2). SMAA itself is github.com/iryoku/smaa (MIT, smaa/LICENSE.txt); the
// Metal source and the lookup tables in smaa/ come from the SHAR visionOS port.
//
// Three passes over a swapchain image, before the compositor draws it: luma
// edges from a gamma view of the image, blending weights from the edges and the
// two lookup tables, then neighbourhood blending through the image's own (sRGB)
// format into a copy the compositor samples instead. A double-wide stereo
// swapchain is smoothed in one go; the seam between the eyes is at the edge of
// both views, where it can't be seen.

#include "xr_visionos_internal.h"

#include "smaa/AreaTex.h"
#include "smaa/SearchTex.h"
#include "smaa/SMAAShader.h"

#import <Foundation/Foundation.h>

namespace mkw::vr::visionos {

namespace {

MTLPixelFormat GammaFormat(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatBGRA8Unorm_sRGB:
        return MTLPixelFormatBGRA8Unorm;
    case MTLPixelFormatRGBA8Unorm_sRGB:
        return MTLPixelFormatRGBA8Unorm;
    default:
        return format;
    }
}

} // namespace

bool Smaa::Prepare(id<MTLDevice> device) {
    if (m_library != nil) {
        return true;
    }
    if (m_failed) {
        return false;
    }
    NSError* error = nil;
    m_library = [device newLibraryWithSource:@(kSmaaShaderSource) options:[MTLCompileOptions new] error:&error];
    if (m_library == nil) {
        m_failed = true;
        SetLastError(std::string("SMAA shaders failed: ") +
                     (error != nil ? error.localizedDescription.UTF8String : "unknown"));
        return false;
    }
    MTLTextureDescriptor* area = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                                                                    width:AREATEX_WIDTH
                                                                                   height:AREATEX_HEIGHT
                                                                                mipmapped:NO];
    m_areaTex = [device newTextureWithDescriptor:area];
    [m_areaTex replaceRegion:MTLRegionMake2D(0, 0, AREATEX_WIDTH, AREATEX_HEIGHT)
                 mipmapLevel:0
                   withBytes:areaTexBytes
                 bytesPerRow:AREATEX_PITCH];
    MTLTextureDescriptor* search = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                      width:SEARCHTEX_WIDTH
                                                                                     height:SEARCHTEX_HEIGHT
                                                                                  mipmapped:NO];
    m_searchTex = [device newTextureWithDescriptor:search];
    [m_searchTex replaceRegion:MTLRegionMake2D(0, 0, SEARCHTEX_WIDTH, SEARCHTEX_HEIGHT)
                   mipmapLevel:0
                     withBytes:searchTexBytes
                   bytesPerRow:SEARCHTEX_PITCH];
    return true;
}

bool Smaa::PrepareTarget(Target& target, id<MTLDevice> device, id<MTLTexture> source) {
    if (target.width == source.width && target.height == source.height && target.format == source.pixelFormat &&
        target.output != nil) {
        return true;
    }
    target = Target{};
    const NSUInteger width = source.width;
    const NSUInteger height = source.height;
    // The render target's metrics are a function constant: each size is a specialization.
    const simd_float4 metrics = simd_make_float4(1.0f / width, 1.0f / height, width, height);
    MTLFunctionConstantValues* constants = [MTLFunctionConstantValues new];
    [constants setConstantValue:&metrics type:MTLDataTypeFloat4 atIndex:0];
    NSError* error = nil;
    id<MTLFunction> vertex = [m_library newFunctionWithName:@"SMAAVertex" constantValues:constants error:&error];
    if (vertex == nil) {
        SetLastError("SMAA vertex function failed");
        return false;
    }
    const auto pipeline = [&](NSString* fragmentName, MTLPixelFormat format) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = [m_library newFunctionWithName:fragmentName constantValues:constants error:nil];
        descriptor.colorAttachments[0].pixelFormat = format;
        return descriptor.fragmentFunction != nil ? [device newRenderPipelineStateWithDescriptor:descriptor error:nil]
                                                  : nil;
    };
    target.edges = pipeline(@"SMAAEdgesFragment", MTLPixelFormatRG8Unorm);
    target.weights = pipeline(@"SMAAWeightsFragment", MTLPixelFormatRGBA8Unorm);
    target.blend = pipeline(@"SMAABlendFragment", source.pixelFormat);
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor new];
    descriptor.width = width;
    descriptor.height = height;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.pixelFormat = MTLPixelFormatRG8Unorm;
    target.edgesTex = [device newTextureWithDescriptor:descriptor];
    descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    target.blendTex = [device newTextureWithDescriptor:descriptor];
    descriptor.pixelFormat = source.pixelFormat;
    target.output = [device newTextureWithDescriptor:descriptor];
    target.output.label = @"SMAA output";
    if (target.edges == nil || target.weights == nil || target.blend == nil || target.edgesTex == nil ||
        target.blendTex == nil || target.output == nil) {
        SetLastError("SMAA pipelines or targets failed");
        target = Target{};
        return false;
    }
    target.width = width;
    target.height = height;
    target.format = source.pixelFormat;
    return true;
}

id<MTLTexture> Smaa::GammaView(id<MTLTexture> source) {
    const MTLPixelFormat gamma = GammaFormat(source.pixelFormat);
    if (gamma == source.pixelFormat) {
        return source;
    }
    void* key = (__bridge void*)source;
    const auto found = m_gammaViews.find(key);
    if (found != m_gammaViews.end()) {
        return found->second;
    }
    // A view keeps its texture alive, so a key can't be reused while it is cached;
    // swapchains are few and long-lived, and a new set replaces the old.
    if (m_gammaViews.size() >= 16) {
        m_gammaViews.clear();
    }
    id<MTLTexture> view = [source newTextureViewWithPixelFormat:gamma];
    if (view != nil) {
        m_gammaViews.emplace(key, view);
    }
    return view;
}

void Smaa::EncodePass(id<MTLCommandBuffer> commandBuffer, id<MTLRenderPipelineState> pipeline,
                      id<MTLTexture> target, NSArray<id<MTLTexture>>* inputs, NSString* label) {
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    encoder.label = label;
    [encoder setRenderPipelineState:pipeline];
    for (NSUInteger i = 0; i < inputs.count; ++i) {
        [encoder setFragmentTexture:inputs[i] atIndex:i];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

id<MTLTexture> Smaa::Encode(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> source, size_t slot) {
    if (source == nil || slot >= m_targets.size() || !Prepare(source.device)) {
        return source;
    }
    Target& target = m_targets[slot];
    if (!PrepareTarget(target, source.device, source)) {
        return source;
    }
    id<MTLTexture> gamma = GammaView(source);
    if (gamma == nil) {
        return source;
    }
    EncodePass(commandBuffer, target.edges, target.edgesTex, @[ gamma ], @"SMAA edges");
    EncodePass(commandBuffer, target.weights, target.blendTex, @[ target.edgesTex, m_areaTex, m_searchTex ],
               @"SMAA weights");
    EncodePass(commandBuffer, target.blend, target.output, @[ source, target.blendTex ], @"SMAA blend");
    return target.output;
}

} // namespace mkw::vr::visionos
