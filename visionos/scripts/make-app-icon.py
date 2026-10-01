#!/usr/bin/env python3
# Draws the TPVR visionOS app icon (needs Pillow):
#   visionos/scripts/make-app-icon.py visionos/App/Assets.xcassets/AppIcon.solidimagestack preview.png
# Three 1024x1024 layers (Back opaque, Middle
# and Front with alpha), the layout an AppIcon.solidimagestack takes.
import math, random, sys, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = sys.argv[1]
preview = sys.argv[2]

def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))

# Back: a twilight sky, deep indigo above, ember orange at the horizon.
back = Image.new("RGB", (S, S))
stops = [(0.0, (22, 20, 46)), (0.45, (88, 44, 74)), (0.72, (190, 88, 52)), (1.0, (240, 150, 70))]
px = back.load()
for y in range(S):
    t = y / (S - 1)
    for i in range(len(stops) - 1):
        if stops[i][0] <= t <= stops[i + 1][0]:
            u = (t - stops[i][0]) / (stops[i + 1][0] - stops[i][0])
            c = lerp(stops[i][1], stops[i + 1][1], u)
            break
    for x in range(S):
        px[x, y] = c
# Twilight motes: small dark squares drifting up.
motes = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(motes)
rng = random.Random(7)
for _ in range(46):
    x = rng.uniform(80, S - 80)
    y = rng.uniform(60, S * 0.62)
    s = rng.uniform(8, 26)
    a = int(rng.uniform(60, 150))
    ang = rng.uniform(0, math.pi / 2)
    pts = [(x + s * math.cos(ang + k * math.pi / 2), y + s * math.sin(ang + k * math.pi / 2)) for k in range(4)]
    d.polygon(pts, fill=(12, 10, 24, a))
motes = motes.filter(ImageFilter.GaussianBlur(1.2))
back = Image.alpha_composite(back.convert("RGBA"), motes).convert("RGB")

# Middle: a low sun with its glow, and dark hills along the bottom.
middle = Image.new("RGBA", (S, S), (0, 0, 0, 0))
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy, r = S * 0.5, S * 0.60, S * 0.20
for k in range(30, 0, -1):
    rr = r * (1 + k * 0.045)
    gd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(255, 214, 140, int(5 + 2.2 * (30 - k))))
glow = glow.filter(ImageFilter.GaussianBlur(18))
middle = Image.alpha_composite(middle, glow)
md = ImageDraw.Draw(middle)
md.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 236, 196, 255))
hills = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hills)
def ridge(base, amp, freq, phase, color):
    pts = [(0, S)]
    for x in range(0, S + 1, 8):
        y = base - amp * (0.6 * math.sin(x / S * math.pi * freq + phase) + 0.4 * math.sin(x / S * math.pi * freq * 2.3 + phase * 1.7))
        pts.append((x, y))
    pts.append((S, S))
    hd.polygon(pts, fill=color)
ridge(S * 0.76, S * 0.035, 2.0, 0.6, (44, 26, 40, 255))
ridge(S * 0.84, S * 0.03, 3.0, 2.1, (22, 14, 26, 255))
middle = Image.alpha_composite(middle, hills)

# Front: a straight sword, point up, slightly tilted.
front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
big = 2
F = Image.new("RGBA", (S * big, S * big), (0, 0, 0, 0))
fd = ImageDraw.Draw(F)
def P(x, y):
    return (x * big, y * big)
cx = S * 0.5
tip, guard, grip_end = S * 0.13, S * 0.70, S * 0.86
w = S * 0.052
outline = (18, 16, 30, 255)
blade = [P(cx, tip), P(cx + w, tip + w * 2.2), P(cx + w, guard), P(cx - w, guard), P(cx - w, tip + w * 2.2)]
fd.polygon(blade, fill=(214, 222, 236, 255), outline=outline, width=10 * big)
fd.line([P(cx, tip + w * 1.2), P(cx, guard - 6)], fill=(150, 162, 186, 255), width=7 * big)
gw, gh = S * 0.20, S * 0.034
fd.rounded_rectangle([P(cx - gw, guard - gh / 2), P(cx + gw, guard + gh / 2)], radius=gh / 2 * big,
                     fill=(64, 92, 168, 255), outline=outline, width=8 * big)
fd.rounded_rectangle([P(cx - w * 0.7, guard + gh / 2), P(cx + w * 0.7, grip_end)], radius=8 * big,
                     fill=(82, 58, 44, 255), outline=outline, width=8 * big)
for k in range(5):
    yy = guard + gh / 2 + (grip_end - guard - gh / 2) * (k + 0.5) / 5
    fd.line([P(cx - w * 0.7, yy - 6), P(cx + w * 0.7, yy + 6)], fill=(56, 38, 30, 255), width=5 * big)
pr = S * 0.035
fd.ellipse([P(cx - pr, grip_end - pr * 0.3), P(cx + pr, grip_end + pr * 1.7)], fill=(64, 92, 168, 255),
           outline=outline, width=8 * big)
F = F.resize((S, S), Image.LANCZOS).rotate(-12, resample=Image.BICUBIC, center=(S / 2, S / 2))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.putalpha(F.getchannel("A").point(lambda a: int(a * 0.45)))
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
front = Image.alpha_composite(front, shadow)
front = Image.alpha_composite(front, F)

os.makedirs(out, exist_ok=True)
for name, img in (("Back", back), ("Middle", middle), ("Front", front)):
    layer = os.path.join(out, f"{name}.solidimagestacklayer", "Content.imageset")
    os.makedirs(layer, exist_ok=True)
    img.save(os.path.join(layer, f"{name}.png"))

# Preview: the stack, masked to the circle visionOS shows.
comp = Image.alpha_composite(Image.alpha_composite(back.convert("RGBA"), middle), front)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).ellipse([0, 0, S, S], fill=255)
bg = Image.new("RGBA", (S, S), (40, 40, 40, 255))
bg.paste(comp, (0, 0), mask)
bg.resize((512, 512), Image.LANCZOS).save(preview)
