#!/usr/bin/env python3
# Writes the window's scene-mirror materials (MirrorScene.swift): visionos/App/Resources/
# MirrorMaterials.usda (repeating textures) and MirrorMaterialsWrap.usda (the other wrap modes,
# loaded separately so that a mode RealityKit rejects can't take the repeating ones with it:
# one bad value fails a whole .usda).
#
# Every vertex carries the game's TEV result as an affine function of its texture's sample T, in
# the game's gamma space (aurora/mirror.h): colour = T.rgb * mul.rgb + add.rgb, alpha = T.a *
# mul.a + add.a, with mul in the vertex colour and add in uv1 (rg) and uv2 (b, a). The textures
# are sRGB, so T is taken back to gamma (^1/2.2), combined as the game does, and the result made
# linear again (^2.2). Unlit, without RealityKit's tone mapping, like the game's own picture.
# Opaque, cut out below Cutoff (alpha test), or blended with premultiplied weights:
#   colour  = rgb * (ColourBase + ColourAlpha * a)
#   opacity = OpacityBase + OpacityAlpha * a + OpacityLuma * luma(rgb)
#
# Then the game's screen effects (bloom, its colour tints, a fade) at the surface's place in the
# game camera's picture: Glow holds them as a premultiplied layer over that picture (WindowGlow,
# GameWindowView), read where the surface's position (the mirror's view space, the mesh's own)
# falls in the camera's view, whose half-view tangents Constants holds (times the layer's reach
# past the view, as 1 / that, in r and g):
#   colour = min(colour * (1 - glow.a) + glow.rgb, 1)     (a blend: + glow.rgb * opacity)
# Straight on, the window matches the game's finished picture; from the side, each glow stays on
# the surface the camera saw it on.
#
#   visionos/scripts/gen-mirror-materials.py
import pathlib

root = pathlib.Path(__file__).resolve().parents[1] / "App" / "Resources"
WRAPS = {"R": "repeat", "C": "clamp_to_edge", "M": "mirrored_repeat"}
SPLIT4 = "float outputs:outx\n            float outputs:outy\n            float outputs:outz\n            float outputs:outw"
SPLIT2 = "float outputs:outx\n            float outputs:outy"


def node(name, id, inputs, out):
    lines = [f'        def Shader "{name}"', "        {", f'            uniform token info:id = "{id}"']
    lines += [f"            {i}" for i in inputs]
    lines += [f"            {out}", "        }"]
    return "\n".join(lines)


def material(kind, wrapS, wrapT):
    M = f"Mirror{kind}_{wrapS}{wrapT}"
    R = f"/Root/{M}"
    c = lambda n, o="out": f"<{R}/{n}.outputs:{o}>"
    i = lambda n: f"<{R}.inputs:{n}>"
    combine3 = lambda name, a, b, cc: node(name, "ND_combine3_vector3", [
        f"float inputs:in1.connect = {a}", f"float inputs:in2.connect = {b}", f"float inputs:in3.connect = {cc}"],
        "float3 outputs:out")
    nodes = [
        # GX's v runs down from the texture's top row; RealityKit's (even with no_flip_v) up from its
        # bottom one, as the relief's UVs found (1 - v). Uncorrected, tiled ground looked right and
        # Link's clothing atlas came out scrambled, with holes where it sampled transparent texels.
        node("RawUV", "ND_texcoord_vector2", [], "float2 outputs:out"),
        node("RawUVSplit", "ND_separate2_vector2", [f"float2 inputs:in.connect = {c('RawUV')}"], SPLIT2),
        node("FlippedV", "ND_subtract_float", ["float inputs:in1 = 1", f"float inputs:in2.connect = {c('RawUVSplit', 'outy')}"],
             "float outputs:out"),
        node("UV", "ND_combine2_vector2", [f"float inputs:in1.connect = {c('RawUVSplit', 'outx')}",
                                           f"float inputs:in2.connect = {c('FlippedV')}"], "float2 outputs:out"),
        node("Sample", "ND_RealityKitTexture2D_vector4", [
            f"asset inputs:file.connect = {i('Frame')}", f"float2 inputs:texcoord.connect = {c('UV')}",
            "uniform bool inputs:no_flip_v = 1",
            f'string inputs:u_wrap_mode = "{WRAPS[wrapS]}"', f'string inputs:v_wrap_mode = "{WRAPS[wrapT]}"'],
            "float4 outputs:out"),
        node("SampleSplit", "ND_separate4_vector4", [f"float4 inputs:in.connect = {c('Sample')}"], SPLIT4),
        combine3("SampleRGB", c("SampleSplit", "outx"), c("SampleSplit", "outy"), c("SampleSplit", "outz")),
        node("SampleGamma", "ND_power_vector3FA", [
            f"float3 inputs:in1.connect = {c('SampleRGB')}", "float inputs:in2 = 0.45454545"], "float3 outputs:out"),
        node("MulColour", "ND_geomcolor_color4", [], "color4f outputs:out"),
        node("Mul", "ND_convert_color4_vector4", [f"color4f inputs:in.connect = {c('MulColour')}"], "float4 outputs:out"),
        node("MulSplit", "ND_separate4_vector4", [f"float4 inputs:in.connect = {c('Mul')}"], SPLIT4),
        combine3("MulRGB", c("MulSplit", "outx"), c("MulSplit", "outy"), c("MulSplit", "outz")),
        node("AddRG", "ND_texcoord_vector2", ["uniform int inputs:index = 1"], "float2 outputs:out"),
        node("AddBA", "ND_texcoord_vector2", ["uniform int inputs:index = 2"], "float2 outputs:out"),
        node("AddRGSplit", "ND_separate2_vector2", [f"float2 inputs:in.connect = {c('AddRG')}"], SPLIT2),
        node("AddBASplit", "ND_separate2_vector2", [f"float2 inputs:in.connect = {c('AddBA')}"], SPLIT2),
        combine3("AddRGB", c("AddRGSplit", "outx"), c("AddRGSplit", "outy"), c("AddBASplit", "outx")),
        node("Product", "ND_multiply_vector3", [
            f"float3 inputs:in1.connect = {c('SampleGamma')}", f"float3 inputs:in2.connect = {c('MulRGB')}"],
            "float3 outputs:out"),
        node("Sum", "ND_add_vector3", [
            f"float3 inputs:in1.connect = {c('Product')}", f"float3 inputs:in2.connect = {c('AddRGB')}"],
            "float3 outputs:out"),
        node("Clamped", "ND_clamp_vector3FA", [
            f"float3 inputs:in.connect = {c('Sum')}", "float inputs:low = 0", "float inputs:high = 1"],
            "float3 outputs:out"),
        node("Linear", "ND_power_vector3FA", [
            f"float3 inputs:in1.connect = {c('Clamped')}", "float inputs:in2 = 2.2"], "float3 outputs:out"),
        node("AlphaProduct", "ND_multiply_float", [
            f"float inputs:in1.connect = {c('SampleSplit', 'outw')}", f"float inputs:in2.connect = {c('MulSplit', 'outw')}"],
            "float outputs:out"),
        node("AlphaSum", "ND_add_float", [
            f"float inputs:in1.connect = {c('AlphaProduct')}", f"float inputs:in2.connect = {c('AddBASplit', 'outy')}"],
            "float outputs:out"),
        node("Alpha", "ND_clamp_float", [
            f"float inputs:in.connect = {c('AlphaSum')}", "float inputs:low = 0", "float inputs:high = 1"],
            "float outputs:out"),
        # Where the surface is in the game camera's picture: its view-space position over its depth,
        # over the view's half-tangents, from -1..1 to the glow layer's 0..1 (v up from its bottom
        # row, as RealityKit reads it; its top row is the picture's top).
        node("Position", "ND_position_vector3", ['uniform string inputs:space = "object"'], "float3 outputs:out"),
        node("PositionSplit", "ND_separate3_vector3", [f"float3 inputs:in.connect = {c('Position')}"],
             "float outputs:outx\n            float outputs:outy\n            float outputs:outz"),
        node("Depth", "ND_subtract_float", ["float inputs:in1 = 0", f"float inputs:in2.connect = {c('PositionSplit', 'outz')}"],
             "float outputs:out"),
        node("Constants", "ND_RealityKitTexture2D_vector4", [
            f"asset inputs:file.connect = {i('Constants')}", "float2 inputs:texcoord = (0.5, 0.5)"], "float4 outputs:out"),
        node("ConstantsSplit", "ND_separate4_vector4", [f"float4 inputs:in.connect = {c('Constants')}"], SPLIT4),
        node("ScreenX", "ND_divide_float", [
            f"float inputs:in1.connect = {c('PositionSplit', 'outx')}", f"float inputs:in2.connect = {c('Depth')}"],
            "float outputs:out"),
        node("ScreenY", "ND_divide_float", [
            f"float inputs:in1.connect = {c('PositionSplit', 'outy')}", f"float inputs:in2.connect = {c('Depth')}"],
            "float outputs:out"),
        node("ViewX", "ND_multiply_float", [
            f"float inputs:in1.connect = {c('ScreenX')}", f"float inputs:in2.connect = {c('ConstantsSplit', 'outx')}"],
            "float outputs:out"),
        node("ViewY", "ND_multiply_float", [
            f"float inputs:in1.connect = {c('ScreenY')}", f"float inputs:in2.connect = {c('ConstantsSplit', 'outy')}"],
            "float outputs:out"),
        node("GlowUV", "ND_combine2_vector2", [
            f"float inputs:in1.connect = {c('ViewX')}", f"float inputs:in2.connect = {c('ViewY')}"], "float2 outputs:out"),
        node("GlowUVHalf", "ND_multiply_vector2FA", [
            f"float2 inputs:in1.connect = {c('GlowUV')}", "float inputs:in2 = 0.5"], "float2 outputs:out"),
        node("GlowTexcoord", "ND_add_vector2FA", [
            f"float2 inputs:in1.connect = {c('GlowUVHalf')}", "float inputs:in2 = 0.5"], "float2 outputs:out"),
        node("Glow", "ND_RealityKitTexture2D_vector4", [
            f"asset inputs:file.connect = {i('Glow')}", f"float2 inputs:texcoord.connect = {c('GlowTexcoord')}",
            "uniform bool inputs:no_flip_v = 1",
            'string inputs:u_wrap_mode = "clamp_to_edge"', 'string inputs:v_wrap_mode = "clamp_to_edge"'],
            "float4 outputs:out"),
        node("GlowSplit", "ND_separate4_vector4", [f"float4 inputs:in.connect = {c('Glow')}"], SPLIT4),
        combine3("GlowRGB", c("GlowSplit", "outx"), c("GlowSplit", "outy"), c("GlowSplit", "outz")),
        node("GlowKeep", "ND_subtract_float", ["float inputs:in1 = 1", f"float inputs:in2.connect = {c('GlowSplit', 'outw')}"],
             "float outputs:out"),
        node("Kept", "ND_multiply_vector3FA", [
            f"float3 inputs:in1.connect = {c('Linear')}", f"float inputs:in2.connect = {c('GlowKeep')}"], "float3 outputs:out"),
        node("GlowAdded", "ND_add_vector3", [
            f"float3 inputs:in1.connect = {c('Kept')}", f"float3 inputs:in2.connect = {c('GlowRGB')}"], "float3 outputs:out"),
        # (The game's picture stops at white; past it, the window's would glare.)
        node("Glowing", "ND_clamp_vector3FA", [
            f"float3 inputs:in.connect = {c('GlowAdded')}", "float inputs:low = 0", "float inputs:high = 1"],
            "float3 outputs:out"),
    ]
    inputs = ["        asset inputs:Frame", "        asset inputs:Glow", "        asset inputs:Constants"]
    surface = ["bool inputs:applyPostProcessToneMap = 0"]
    if kind == "Opaque":
        nodes.append(node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('Glowing')}"], "color3f outputs:out"))
        surface.append(f"color3f inputs:color.connect = {c('RGB')}")
    elif kind == "Cutout":
        # An alpha test, as GX's: discarded below Cutoff, fully opaque at or above it. Passed straight
        # through, the texture's alpha left what passed see-through (TP's skin and cloth textures
        # carry alpha that isn't transparency): opacity is made 0 or 1 first.
        inputs.append("        float inputs:Cutoff = 0.5")
        nodes += [
            node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('Glowing')}"], "color3f outputs:out"),
            node("AboveCutoff", "ND_subtract_float", [
                f"float inputs:in1.connect = {c('Alpha')}", f"float inputs:in2.connect = {i('Cutoff')}"], "float outputs:out"),
            node("Sharpened", "ND_multiply_float", [
                f"float inputs:in1.connect = {c('AboveCutoff')}", "float inputs:in2 = 100000"], "float outputs:out"),
            node("Centred", "ND_add_float", [
                f"float inputs:in1.connect = {c('Sharpened')}", "float inputs:in2 = 0.5"], "float outputs:out"),
            node("Mask", "ND_clamp_float", [
                f"float inputs:in.connect = {c('Centred')}", "float inputs:low = 0", "float inputs:high = 1"],
                "float outputs:out"),
        ]
        surface += [f"color3f inputs:color.connect = {c('RGB')}", f"float inputs:opacity.connect = {c('Mask')}",
                    "float inputs:opacityThreshold = 0.5"]
    else:
        inputs += ["        float inputs:ColourBase = 0", "        float inputs:ColourAlpha = 1",
                   "        float inputs:OpacityBase = 0", "        float inputs:OpacityAlpha = 1",
                   "        float inputs:OpacityLuma = 0"]
        nodes += [
            node("Luma", "ND_dotproduct_vector3", [
                f"float3 inputs:in1.connect = {c('Linear')}", "float3 inputs:in2 = (0.2126, 0.7152, 0.0722)"],
                "float outputs:out"),
            node("ColourWeightAlpha", "ND_multiply_float", [
                f"float inputs:in1.connect = {c('Alpha')}", f"float inputs:in2.connect = {i('ColourAlpha')}"],
                "float outputs:out"),
            node("ColourWeight", "ND_add_float", [
                f"float inputs:in1.connect = {c('ColourWeightAlpha')}", f"float inputs:in2.connect = {i('ColourBase')}"],
                "float outputs:out"),
            node("Weighted", "ND_multiply_vector3FA", [
                f"float3 inputs:in1.connect = {c('Linear')}", f"float inputs:in2.connect = {c('ColourWeight')}"],
                "float3 outputs:out"),
            # Over what's behind, the glow is in proportion to how much of it this layer hides.
            node("WeightedKept", "ND_multiply_vector3FA", [
                f"float3 inputs:in1.connect = {c('Weighted')}", f"float inputs:in2.connect = {c('GlowKeep')}"],
                "float3 outputs:out"),
            node("GlowCovered", "ND_multiply_vector3FA", [
                f"float3 inputs:in1.connect = {c('GlowRGB')}", f"float inputs:in2.connect = {c('Opacity')}"],
                "float3 outputs:out"),
            node("WeightedGlowing", "ND_add_vector3", [
                f"float3 inputs:in1.connect = {c('WeightedKept')}", f"float3 inputs:in2.connect = {c('GlowCovered')}"],
                "float3 outputs:out"),
            node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('WeightedGlowing')}"], "color3f outputs:out"),
            node("OpacityFromAlpha", "ND_multiply_float", [
                f"float inputs:in1.connect = {c('Alpha')}", f"float inputs:in2.connect = {i('OpacityAlpha')}"],
                "float outputs:out"),
            node("OpacityFromLuma", "ND_multiply_float", [
                f"float inputs:in1.connect = {c('Luma')}", f"float inputs:in2.connect = {i('OpacityLuma')}"],
                "float outputs:out"),
            node("OpacitySum", "ND_add_float", [
                f"float inputs:in1.connect = {c('OpacityFromAlpha')}", f"float inputs:in2.connect = {c('OpacityFromLuma')}"],
                "float outputs:out"),
            node("Opacity", "ND_add_float", [
                f"float inputs:in1.connect = {c('OpacitySum')}", f"float inputs:in2.connect = {i('OpacityBase')}"],
                "float outputs:out"),
        ]
        surface += ["bool inputs:hasPremultipliedAlpha = 1", f"color3f inputs:color.connect = {c('RGB')}",
                    f"float inputs:opacity.connect = {c('Opacity')}"]
    nodes.insert(0, node("Surface", "ND_realitykit_unlit_surfaceshader", surface, "token outputs:out"))
    body = "\n\n".join(nodes)
    ins = "\n".join(inputs)
    return f'''    def Material "{M}"
    {{
{ins}
        token outputs:mtlx:surface.connect = <{R}/Surface.outputs:out>
        token outputs:realitykit:vertex

{body}
    }}
'''


def write(name, wraps, comment):
    text = f'''#usda 1.0
(
    defaultPrim = "Root"
    metersPerUnit = 1
    upAxis = "Y"
)

# {comment}
# Generated by visionos/scripts/gen-mirror-materials.py: edit that, not this.
def Xform "Root"
{{
'''
    text += "\n".join(material(kind, s, t) for (s, t) in wraps for kind in ("Opaque", "Cutout", "Blend"))
    text += "}\n"
    (root / name).write_text(text)


write("MirrorMaterials.usda", [("R", "R")],
      "The window's scene mirror (MirrorScene.swift): its materials for repeating textures.")
write("MirrorMaterialsWrap.usda", [(s, t) for s in "RCM" for t in "RCM" if (s, t) != ("R", "R")],
      "The window's scene mirror (MirrorScene.swift): its materials for clamped and mirrored textures.")
