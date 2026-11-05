#!/usr/bin/env python3
"""Turns raw simulator screenshots into App Store marketing images.

Usage:
  store_shots.py <raw_dir> <out_dir> <serif.ttf> <sans.ttf> [en|tr]

raw_dir holds the captures named after DemoMode screens (result.png, avatar.png, …).
Each image is 1320x2868 (6.9"): a headline set in a serif display face, a short line
under it, the screen in a phone frame rising from the bottom, and one or two "chips"
that call out what the screen shows. Backgrounds alternate between the brand's blush
and plum, as fashion apps' listings do, so the row reads as a set.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1320, 2868
PLUM = (90, 31, 100)
BERRY = (178, 59, 122)
ROSE = (230, 133, 158)
GOLD = (201, 163, 107)
BLUSH_TOP = (253, 246, 248)
BLUSH_BOTTOM = (246, 221, 231)
PLUM_TOP = (64, 20, 72)
PLUM_BOTTOM = (150, 44, 104)

# (screen, kicker, headline, line, chips, dark background), per language.
SLOTS = {
    "en": [
        ("result", "SIZE ADVICE", "Know your size|before you buy",
         "Every garment checked against your body,|region by region.", ["✓  Waist: ideal", "Size M · high confidence"], False),
        ("body", "3D BODY SCAN", "Your body,|scanned in 3D",
         "One turn in front of your phone builds|your 3D twin. No tape, no studio.", ["30-second scan", "Processed on-device"], True),
        ("avatar", "3D TRY-ON", "Try it on your|3D twin",
         "Jeans and a tee on your own body, in the|size you pick, draped like real fabric.", ["Tight · Ideal · Loose"], False),
        ("profile", "12 MEASUREMENTS", "Every measurement,|no tape",
         "Chest, waist, hips, inseam and more,|each with how sure it is.", ["Accurate to ~2 cm"], True),
        ("scan", "ANY STORE", "Any link, any|size chart",
         "Paste a product link, scan a barcode|or snap a size chart.", ["Works with 100+ stores"], False),
        ("memory", "SAFARI", "Your size, right|where you shop",
         "WearIQ reads clothing pages as you browse|and keeps them ready for you.", ["Saved from Safari"], True),
        ("style", "PERSONAL STYLIST", "Colours and cuts|that suit you",
         "From your skin tone and your shape,|and the way you like to dress.", ["Your palette"], False),
        ("passport", "SIZE PASSPORT", "Every brand,|one passport",
         "Your size in each brand you buy,|ready to share.", ["Brand by brand"], True),
        ("home", "FEWER RETURNS", "Shop with|confidence",
         "Know how it fits before it ships.|Keep what you order.", ["Fewer returns"], False),
    ],
    "tr": [
        ("result", "BEDEN ÖNERİSİ", "Almadan önce|bedenini bil",
         "Her kıyafet vücuduna göre,|bölge bölge kontrol edilir.", ["✓  Bel: ideal", "M beden · yüksek güven"], False),
        ("body", "3D VÜCUT TARAMA", "Tek turda|3D vücut taraması",
         "Telefonun önünde bir tur dön, 3D ikizin|hazır. Mezura yok, stüdyo yok.", ["30 saniyede tarama", "Cihazında işlenir"], True),
        ("avatar", "3D DENEME", "Kıyafeti 3D|ikizinde dene",
         "Jean ve tişört kendi vücudunda, seçtiğin|bedende, gerçek kumaş gibi dökülür.", ["Dar · İdeal · Bol"], False),
        ("profile", "12 ÖLÇÜ", "Tüm ölçülerin,|mezurasız",
         "Göğüs, bel, kalça, iç bacak ve fazlası,|her biri güven aralığıyla.", ["~2 cm hassasiyet"], True),
        ("scan", "HER MAĞAZA", "Her bağlantı,|her beden tablosu",
         "Ürün bağlantısını yapıştır, barkodu okut|ya da beden tablosunun fotoğrafını çek.", ["100+ mağazayla çalışır"], False),
        ("memory", "SAFARI", "Bedenin, alışveriş|yaptığın yerde",
         "WearIQ gezdiğin giyim sayfalarını okur|ve senin için hazır tutar.", ["Safari'den kaydedildi"], True),
        ("style", "KİŞİSEL STİLİST", "Sana yakışan|renk ve kesimler",
         "Ten rengine, vücut tipine|ve giyinme tarzına göre.", ["Renk paletin"], False),
        ("passport", "BEDEN PASAPORTU", "Her marka,|tek pasaport",
         "Aldığın her markadaki bedenin,|paylaşmaya hazır.", ["Marka marka"], True),
        ("home", "DAHA AZ İADE", "Gönül rahatlığıyla|alışveriş yap",
         "Kargolanmadan önce nasıl oturacağını bil.|Sipariş ettiğini elinde tut.", ["Daha az iade"], False),
    ],
}


def gradient(top, bottom):
    column = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        column.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return column.resize((W, H))


def glow(img, centre, radius, colour, alpha):
    # Transparent in the glow's own colour, so the blur's edge doesn't turn grey.
    layer = Image.new("RGBA", (W, H), colour + (0,))
    d = ImageDraw.Draw(layer)
    x, y = centre
    d.ellipse((x - radius, y - radius, x + radius, y + radius), fill=colour + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(radius // 2))
    img.alpha_composite(layer)


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def phone(screen, width):
    """The screenshot in a slim black frame with the screen's own rounded corners."""
    bezel = int(width * 0.028)
    inner_w = width - 2 * bezel
    shot = screen.convert("RGBA").resize((inner_w, int(screen.height * inner_w / screen.width)), Image.LANCZOS)
    radius = int(inner_w * 0.13)
    frame = Image.new("RGBA", (width, shot.height + 2 * bezel), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, frame.width - 1, frame.height - 1), radius + bezel, fill=(18, 14, 20, 255))
    frame.alpha_composite(rounded(shot, radius), (bezel, bezel))
    return frame


def shadow(size, radius, alpha):
    s = Image.new("RGBA", (size[0] + 200, size[1] + 200), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle((100, 100, 100 + size[0], 100 + size[1]), radius, fill=(40, 10, 40, alpha))
    return s.filter(ImageFilter.GaussianBlur(45))


def chip(text, font, dark):
    pad_x, pad_y = 44, 26
    box = font.getbbox(text)
    w, h = box[2] - box[0] + 2 * pad_x, box[3] - box[1] + 2 * pad_y
    img = Image.new("RGBA", (w + 60, h + 60), (0, 0, 0, 0))
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((30, 38, 30 + w, 38 + h), h // 2, fill=(40, 10, 40, 70))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))
    d = ImageDraw.Draw(img)
    fill = (255, 255, 255, 255) if not dark else (255, 255, 255, 240)
    d.rounded_rectangle((30, 30, 30 + w, 30 + h), h // 2, fill=fill)
    d.text((30 + pad_x - box[0], 30 + pad_y - box[1]), text, font=font, fill=BERRY if not dark else PLUM)
    return img


def compose(raw, slot, fonts):
    name, kicker, headline, line, chips, dark = slot
    img = gradient(PLUM_TOP, PLUM_BOTTOM) if dark else gradient(BLUSH_TOP, BLUSH_BOTTOM)
    img = img.convert("RGBA")
    glow(img, (W - 140, 520), 420, ROSE if dark else (255, 255, 255), 90 if dark else 160)
    glow(img, (120, H - 600), 520, BERRY if dark else ROSE, 70 if dark else 60)
    d = ImageDraw.Draw(img)
    serif, sans, sans_bold = fonts
    ink = (255, 255, 255) if dark else PLUM
    soft = (246, 214, 228) if dark else (120, 72, 110)
    y = 170
    spaced = " ".join(kicker)  # tracked-out caps
    d.text((W // 2, y), spaced, font=sans_bold, fill=GOLD if dark else BERRY, anchor="mt")
    y += 92
    for text_line in headline.split("|"):
        d.text((W // 2, y), text_line, font=serif, fill=ink, anchor="mt")
        y += 146
    y += 22
    for text_line in line.split("|"):
        d.text((W // 2, y), text_line, font=sans, fill=soft, anchor="mt")
        y += 66
    # The phone rises from the bottom edge.
    top = y + 70
    width = 930
    frame = phone(raw, width)
    x = (W - width) // 2
    sh = shadow(frame.size, 120, 110)
    img.alpha_composite(sh, (x - 100, top - 70))
    img.alpha_composite(frame, (x, top))
    # Chips over the phone's edges.
    chip_font = fonts[2].font_variant(size=50)
    try:
        chip_font.set_variation_by_name(b"SemiBold")
    except Exception:
        pass
    # On the phone's edges, clear of what the screen says: one over its top corner,
    # one over the tab bar.
    positions = [(40, top - 40), (W - 40, top + frame.height - 330)]
    for i, text in enumerate(chips[:2]):
        c = chip(text, chip_font, dark)
        cx, cy = positions[i]
        px = cx if i == 0 else cx - c.width
        img.alpha_composite(c, (max(0, px), cy))
    return img.convert("RGB")


def main(raw_dir, out_dir, serif_path, sans_path, lang="en"):
    os.makedirs(out_dir, exist_ok=True)
    serif = ImageFont.truetype(serif_path, 132)
    sans = ImageFont.truetype(sans_path, 50)
    sans_bold = ImageFont.truetype(sans_path, 42)
    for font, weight in ((sans, b"Regular"), (sans_bold, b"Bold")):
        try:
            font.set_variation_by_name(weight)
        except Exception:
            pass
    n = 0
    for slot in SLOTS[lang]:
        path = os.path.join(raw_dir, slot[0] + ".png")
        if not os.path.exists(path):
            print("missing", path)
            continue
        n += 1
        compose(Image.open(path), slot, (serif, sans, sans_bold)).save(
            os.path.join(out_dir, f"{n:02d}_{slot[0]}.png"), optimize=True)
        print("made", slot[0])


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    main(*sys.argv[1:])
