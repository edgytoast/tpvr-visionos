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
        node("UV", "ND_texcoord_vector2", [], "float2 outputs:out"),
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
    ]
    inputs = ["        asset inputs:Frame"]
    surface = ["bool inputs:applyPostProcessToneMap = 0"]
    if kind == "Opaque":
        nodes.append(node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('Linear')}"], "color3f outputs:out"))
        surface.append(f"color3f inputs:color.connect = {c('RGB')}")
    elif kind == "Cutout":
        inputs.append("        float inputs:Cutoff = 0.5")
        nodes.append(node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('Linear')}"], "color3f outputs:out"))
        surface += [f"color3f inputs:color.connect = {c('RGB')}", f"float inputs:opacity.connect = {c('Alpha')}",
                    f"float inputs:opacityThreshold.connect = {i('Cutoff')}"]
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
            node("RGB", "ND_convert_vector3_color3", [f"float3 inputs:in.connect = {c('Weighted')}"], "color3f outputs:out"),
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
