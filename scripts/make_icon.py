"""WearIQ icon: a dress form with a tape measure round its waist, on a plum-to-rose field."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # drawn large, scaled down for smooth edges

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def background():
    img = Image.new("RGB", (S, S))
    px = img.load()
    top_left, mid, bottom_right = (64, 22, 74), (150, 44, 104), (236, 128, 150)
    small = Image.new("RGB", (256, 256))
    sp = small.load()
    for y in range(256):
        for x in range(256):
            t = (x * 0.45 + y * 0.75) / (255 * 1.2)
            c = lerp(top_left, mid, t / 0.55) if t < 0.55 else lerp(mid, bottom_right, (t - 0.55) / 0.45)
            # A soft light from the upper right.
            d = math.hypot(x - 200, y - 40) / 256
            glow = max(0, 1 - d * 1.6) * 0.22
            sp[x, y] = tuple(min(255, int(ch + (255 - ch) * glow)) for ch in c)
    return small.resize((S, S), Image.BICUBIC)

def bezier(p0, p1, p2, p3, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
    return pts

def form_outline(k):
    """Right half of a dress form (neck, shoulder, bust, waist, hip), mirrored."""
    cx = S / 2
    def P(x, y): return (cx + x * k, y * k)
    right = []
    right += bezier(P(0, 820), P(95, 820), P(150, 830), P(160, 900))           # neck top to neck side
    right += bezier(P(160, 900), P(170, 980), P(420, 1000), P(520, 1080))     # shoulder slope
    right += bezier(P(520, 1080), P(610, 1150), P(600, 1350), P(560, 1520))   # armhole to bust
    right += bezier(P(560, 1520), P(520, 1700), P(400, 1850), P(380, 1980))   # bust to waist
    right += bezier(P(380, 1980), P(370, 2100), P(560, 2300), P(590, 2480))   # waist to hip
    right += bezier(P(590, 2480), P(610, 2620), P(560, 2760), P(500, 2840))   # hip to the base
    left = [(2 * cx - x, y) for (x, y) in reversed(right)]
    return right + [(cx + 0, 2840 * k)] + left

SCALE, CY, LIFT = 1.2, 2150, 40

def T(x, y):
    """Everything drawn a little larger about the middle, to fill the icon."""
    return (S / 2 + (x - S / 2) * SCALE, CY + (y - CY) * SCALE - LIFT)

def icon(size_out, path):
    k = S / 4096
    img = background()
    shadow = Image.new("L", (S, S), 0)
    outline = [T(x, y) for x, y in form_outline(k)]
    ImageDraw.Draw(shadow).polygon([(x + 40, y + 70) for x, y in outline], fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(90))
    img.paste((40, 10, 40), mask=shadow)
    form = Image.new("L", (S, S), 0)
    ImageDraw.Draw(form).polygon(outline, fill=255)
    # The form: ivory, with a faint shading down its right side.
    ivory = Image.new("RGB", (S, S), (255, 248, 244))
    img.paste(ivory, mask=form)
    shade = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shade).polygon([(x, y) for x, y in outline if x > S / 2 + 140] + [T(S / 2 + 140, 2840)], fill=40)
    shade = shade.filter(ImageFilter.GaussianBlur(160))
    img.paste((214, 160, 175), mask=Image.composite(shade, Image.new("L", (S, S), 0), form))
    # The stand: a slim pole and a round foot.
    d = ImageDraw.Draw(img)
    a, b = T(S / 2 - 34, 2840), T(S / 2 + 34, 3380)
    d.rounded_rectangle([a[0], a[1], b[0], b[1]], radius=40, fill=(255, 248, 244))
    a, b = T(S / 2 - 300, 3350), T(S / 2 + 300, 3460)
    d.ellipse([a[0], a[1], b[0], b[1]], fill=(255, 248, 244))
    # The tape measure round the waist: a champagne-gold band with ticks, its loose end
    # falling across the hip.
    gold, gold_dark = (232, 196, 140), (178, 132, 78)
    tape = Image.new("L", (S, S), 0)
    td = ImageDraw.Draw(tape)
    band = [T(x, y) for x, y in bezier((S / 2 - 392, 1930), (S / 2 - 150, 2030), (S / 2 + 150, 2030), (S / 2 + 392, 1930), 80)]
    lower = [T(x, y + 110) for x, y in reversed(bezier((S / 2 - 388, 1930), (S / 2 - 150, 2030), (S / 2 + 150, 2030), (S / 2 + 388, 1930), 80))]
    td.polygon(band + lower, fill=255)
    tail = [T(x, y) for x, y in bezier((S / 2 + 300, 1985), (S / 2 + 520, 2160), (S / 2 + 380, 2480), (S / 2 + 600, 2700), 80)]
    for (x, y) in tail:
        td.ellipse([x - 62, y - 62, x + 62, y + 62], fill=255)
    img.paste(gold, mask=tape)
    # Ticks along the band.
    for i in range(1, 13):
        t = i / 13
        x, y = band[int(t * 80)]
        h = 70 if i % 5 == 0 else 42
        d.line([(x, y + 8), (x, y + h * SCALE)], fill=gold_dark, width=16)
    img = img.resize((size_out, size_out), Image.LANCZOS)
    img.save(path)

for size, path in [(int(a), b) for a, b in zip(sys.argv[1::2], sys.argv[2::2])]:
    icon(size, path)
print("ok")
