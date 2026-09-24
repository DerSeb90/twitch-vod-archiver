# Generates the rewind app icon sources (used by flutter_launcher_icons).
# Run from app/:  python tool/make_icons.py && dart run flutter_launcher_icons
from PIL import Image, ImageDraw, ImageFilter

S = 1024
VIOLET, PINK, ORANGE = (139, 92, 246), (236, 72, 153), (249, 115, 22)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))  # diagonal, top-left -> bottom-right
            px[x, y] = lerp(VIOLET, PINK, t / 0.55) if t < 0.55 else lerp(PINK, ORANGE, (t - 0.55) / 0.45)
    return img

def glyph(size, scale):
    """White 'rewind' symbol (two left-pointing rounded triangles), centered."""
    ss = 4  # supersampling for smooth edges
    W = size * ss
    layer = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(layer)
    h = W * scale            # symbol height
    w = h * 0.62             # width of one triangle
    cx, cy = W / 2, W / 2
    total = w * 2 - w * 0.18  # triangles overlap slightly
    left = cx - total / 2
    r = h * 0.09
    for i in range(2):
        x0 = left + i * (w - w * 0.18)
        tri = [(x0, cy), (x0 + w, cy - h / 2), (x0 + w, cy + h / 2)]
        d.polygon(tri, fill=255)
    layer = layer.filter(ImageFilter.GaussianBlur(r / 3)).point(lambda v: 255 if v > 128 else 0)  # rounded corners
    layer = layer.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(layer)
    white = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    white.putalpha(layer)
    return white

bg = gradient(S)
bg.save("assets/icon/background.png")

# adaptive foreground: symbol must stay inside the 66% safe zone
glyph(S, 0.34).save("assets/icon/foreground.png")

# full icon (legacy Android, Windows, web): gradient squircle + symbol
full = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mask = Image.new("L", (S * 4, S * 4), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S * 4 - 1, S * 4 - 1], radius=int(S * 4 * 0.23), fill=255)
mask = mask.resize((S, S), Image.LANCZOS)
full.paste(bg, (0, 0), mask)
g = glyph(S, 0.44)
full.alpha_composite(g)
full.save("assets/icon/icon.png")

# monochrome (Android 13 themed icons): the symbol only
glyph(S, 0.34).save("assets/icon/monochrome.png")
print("ok")
