"""Erzeugt die Texturen der Leiste und die Symbole als TGA.

Aufruf: python tools/make_textures.py
Braucht nur Pillow. WoW laedt die Dateien aus dem Ordner Textures.
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

WIDTH, HEIGHT = 512, 32  # Zweierpotenzen, passt grob zu den 200 x 14 der Leiste
RADIUS = 8
BORDER = 2
OUT = Path(__file__).resolve().parent.parent / "Textures"


def rounded_coverage(x, y, inset, radius):
    """Deckung eines Pixels in einem abgerundeten Rechteck, mit weicher Kante."""
    half_w = WIDTH / 2 - inset
    half_h = HEIGHT / 2 - inset
    qx = abs(x + 0.5 - WIDTH / 2) - (half_w - radius)
    qy = abs(y + 0.5 - HEIGHT / 2) - (half_h - radius)
    outside = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** 0.5
    distance = outside + min(max(qx, qy), 0) - radius
    return min(max(0.5 - distance, 0), 1)


def track():
    """Glas: weisser Rand, innen nach unten durchsichtiger."""
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        inner_alpha = 0.30 + (0.13 - 0.30) * t
        for x in range(WIDTH):
            outer = rounded_coverage(x, y, 0, RADIUS)
            inner = rounded_coverage(x, y, BORDER, RADIUS - BORDER)
            alpha = (outer - inner) * 0.62 + inner * inner_alpha
            image.putpixel((x, y), (255, 255, 255, round(alpha * 255)))
    return image


def fill():
    """Fuellung: hell und einfaerbbar, oben eine feine Lichtkante."""
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    top = BORDER
    for y in range(HEIGHT):
        t = max(y - top, 0) / (HEIGHT - 1 - 2 * top)
        value = round((1.0 + (0.78 - 1.0) * min(t, 1)) * 255)
        base_alpha = 0.95 if y < top + 2 else 0.62
        for x in range(WIDTH):
            coverage = rounded_coverage(x, y, BORDER, RADIUS - BORDER)
            image.putpixel((x, y), (value, value, value, round(coverage * base_alpha * 255)))
    return image


def neon_track():
    """Dunkles Glas mit duennem hellem Rand und Lichtkante oben."""
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    for y in range(HEIGHT):
        highlight = 0.24 if BORDER <= y < BORDER + 2 else 0
        for x in range(WIDTH):
            outer = rounded_coverage(x, y, 0, RADIUS)
            inner = rounded_coverage(x, y, BORDER, RADIUS - BORDER)
            edge = max(outer - inner, 0) * 0.32
            glass = inner * 0.55
            light = inner * highlight
            alpha = min(edge + glass + light, 1)
            white = (edge + light) / alpha if alpha else 1
            value = round(white * 255)
            image.putpixel((x, y), (value, value, value, round(alpha * 255)))
    return image


NEON_MARGIN_X = 11  # Abstand des Kerns zu den Enden
NEON_CORE_H = 9  # Hoehe des Kerns


def neon_core_distance(x, y):
    """Abstand eines Pixels zum waagerechten Kern, negativ im Inneren."""
    half_w = WIDTH / 2 - NEON_MARGIN_X
    half_h = NEON_CORE_H / 2
    radius = half_h
    qx = abs(x + 0.5 - WIDTH / 2) - (half_w - radius)
    qy = abs(y + 0.5 - HEIGHT / 2) - (half_h - radius)
    outside = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** 0.5
    return outside + min(max(qx, qy), 0) - radius


def neon_core():
    """Heller Kern, wird fast weiss eingefaerbt."""
    image = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 0))
    for y in range(HEIGHT):
        for x in range(WIDTH):
            coverage = min(max(0.5 - neon_core_distance(x, y), 0), 1)
            image.putpixel((x, y), (255, 255, 255, round(coverage * 255)))
    return image


def neon_glow():
    """Leuchten um den Kern, weiss und einfaerbbar, im Spiel additiv gezeichnet."""
    image = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 0))
    for y in range(HEIGHT):
        for x in range(WIDTH):
            distance = max(neon_core_distance(x, y), 0)
            glow = math.exp(-((distance / 5.5) ** 2))
            inner = rounded_coverage(x, y, BORDER, RADIUS - BORDER)
            image.putpixel((x, y), (255, 255, 255, round(glow * inner * 255)))
    return image


SYMBOL_SIZE = 64
SYMBOL_SCALE = 4
UNIT = SYMBOL_SIZE * SYMBOL_SCALE / 24  # Die Formen sind in einem 24er-Raster gezeichnet


def symbol_finish(layer):
    """Verkleinert die Form und legt einen weichen schwarzen Schatten darunter."""
    shape = layer.resize((SYMBOL_SIZE, SYMBOL_SIZE), Image.LANCZOS)
    alpha = shape.getchannel("A")
    shadow_alpha = alpha.filter(ImageFilter.GaussianBlur(2.5)).point(lambda a: min(a * 2, 255))
    result = Image.new("RGBA", (SYMBOL_SIZE, SYMBOL_SIZE), (0, 0, 0, 0))
    result.putalpha(shadow_alpha)
    result.alpha_composite(shape)
    return result


def symbol_run():
    """Laufende Figur."""
    size = SYMBOL_SIZE * SYMBOL_SCALE
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    draw = ImageDraw.Draw(layer)
    width = round(2.7 * UNIT)

    def point(x, y):
        return x * UNIT, y * UNIT

    def dot(x, y, radius):
        cx, cy = point(x, y)
        r = radius * UNIT
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 255))

    limbs = [
        [(13.6, 8.2), (11, 14)],
        [(13.6, 8.6), (16.8, 11.6), (20.4, 10.6)],
        [(13.4, 8.6), (9.2, 8.8), (6.6, 12)],
        [(11, 14), (15.2, 16.4), (14.4, 21.6)],
        [(11, 14), (8.4, 18.2), (3.8, 18.4)],
    ]
    for limb in limbs:
        draw.line([point(*p) for p in limb], fill=(255, 255, 255, 255), width=width)
        for p in limb:
            dot(p[0], p[1], 1.35)  # runde Enden und Gelenke
    dot(15.5, 4.2, 2.4)
    return symbol_finish(layer)


def symbol_halt():
    """Erhobene Hand."""
    size = SYMBOL_SIZE * SYMBOL_SCALE
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    draw = ImageDraw.Draw(layer)
    rects = [
        (7.2, 10.5, 11.6, 11, 3.6),
        (7.2, 4.2, 2.6, 10, 1.3),
        (10.3, 2.2, 2.6, 11, 1.3),
        (13.4, 2.8, 2.6, 11, 1.3),
        (16.5, 5.0, 2.3, 9, 1.15),
    ]
    for x, y, w, h, r in rects:
        draw.rounded_rectangle(
            (x * UNIT, y * UNIT, (x + w) * UNIT, (y + h) * UNIT),
            radius=r * UNIT,
            fill=(255, 255, 255, 255),
        )

    # Daumen auf eigener Ebene, damit er sich drehen laesst
    thumb = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    ImageDraw.Draw(thumb).rounded_rectangle(
        (3.1 * UNIT, 12 * UNIT, 5.7 * UNIT, 20 * UNIT),
        radius=1.3 * UNIT,
        fill=(255, 255, 255, 255),
    )
    thumb = thumb.rotate(28, resample=Image.BICUBIC, center=(4.4 * UNIT, 16 * UNIT))
    layer.alpha_composite(thumb)
    return symbol_finish(layer)


def symbol_bow():
    """Gespannter Bogen von der Seite mit waagerechtem Pfeil nach rechts."""
    size = SYMBOL_SIZE * SYMBOL_SCALE
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    draw = ImageDraw.Draw(layer)
    white = (255, 255, 255, 255)

    def point(x, y):
        return x * UNIT, y * UNIT

    # Bogenholz als flacher Halbbogen nach rechts
    draw.arc(
        (-2.5 * UNIT, 2.0 * UNIT, 14.5 * UNIT, 22.0 * UNIT),
        start=-90,
        end=90,
        fill=white,
        width=round(2.6 * UNIT),
    )

    # Sehne von den Bogenenden zur Pfeilnocke, nach hinten gezogen
    nock = (2.0, 12.0)
    draw.line([point(6.0, 2.6), point(*nock), point(6.0, 21.4)], fill=white, width=round(1.2 * UNIT))

    # Pfeil mit Spitze
    draw.line([point(*nock), point(19.0, 12.0)], fill=white, width=round(1.7 * UNIT))
    draw.polygon([point(23.0, 12.0), point(17.5, 8.4), point(17.5, 15.6)], fill=white)
    return symbol_finish(layer)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    symbol_bow().save(OUT / "SymbolBow.tga")
    track().save(OUT / "FrostTrack.tga")
    fill().save(OUT / "FrostFill.tga")
    neon_track().save(OUT / "NeonTrack.tga")
    neon_core().save(OUT / "NeonCore.tga")
    neon_glow().save(OUT / "NeonGlow.tga")
    symbol_run().save(OUT / "SymbolRun.tga")
    symbol_halt().save(OUT / "SymbolHalt.tga")
    print("Geschrieben nach", OUT)
