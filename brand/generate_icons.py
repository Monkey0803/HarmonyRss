"""Generate the 源见 RSS store, layered, and launch icons.

Run from the repository root with: python3 brand/generate_icons.py
The SVG is an editable export; the PNGs use the same geometry at 4x render scale.
"""

from pathlib import Path
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "brand"
APP_MEDIA = ROOT / "AppScope/resources/base/media"
ENTRY_MEDIA = ROOT / "entry/src/main/resources/base/media"
SCALE = 4
SIZE = 1024
PALETTES = {
    "classic": ((13, 77, 198), (58, 157, 249)),
    "aurora": ((0, 106, 142), (120, 107, 232)),
    "sunset": ((185, 53, 105), (246, 139, 80)),
    "mono": ((32, 36, 44), (69, 75, 88)),
}
WHITE = (255, 255, 255, 255)


def svg() -> str:
    return '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">源见 RSS：书页与订阅波纹</title>
  <defs>
    <linearGradient id="blue" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0D4DC6"/>
      <stop offset="1" stop-color="#3A9DF9"/>
    </linearGradient>
  </defs>
  <path fill="url(#blue)" d="M0 0h1024v1024H0z"/>
  <g fill="none" stroke="#fff" stroke-width="38">
    <path d="M370 297a110 110 0 0 1 110 110"/>
    <path d="M370 207a200 200 0 0 1 200 200"/>
  </g>
  <circle cx="370" cy="407" r="29" fill="#fff"/>
  <path fill="#fff" d="M234 550Q366 515 497 575v184q-132-62-263-25z"/>
  <path fill="#fff" d="M527 575q131-60 263-25v184q-131-37-263 25z"/>
</svg>
'''


def gradient(start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE))
    pixels = canvas.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / (2 * (SIZE - 1))
            pixels[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(start, end)) + (255,)
    return canvas.resize((SIZE * SCALE, SIZE * SCALE), Image.Resampling.BILINEAR)


def bezier(p0, p1, p2, steps=48):
    return [(
        (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0],
        (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1],
    ) for t in (i / steps for i in range(steps + 1))]


def scaled(points):
    return [(round(x * SCALE), round(y * SCALE)) for x, y in points]


def foreground() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    for radius in (110, 200):
        box = scaled([(370 - radius, 407 - radius), (370 + radius, 407 + radius)])
        draw.arc(box, 270, 360, fill=WHITE, width=38 * SCALE)
    draw.ellipse(tuple(v * SCALE for v in (341, 378, 399, 436)), fill=WHITE)

    left = [(234, 550)] + bezier((234, 550), (366, 515), (497, 575))[1:]
    left += [(497, 759)] + bezier((497, 759), (365, 697), (234, 734))[1:]
    right = [(527, 575)] + bezier((527, 575), (658, 515), (790, 550))[1:]
    right += [(790, 734)] + bezier((790, 734), (659, 697), (527, 759))[1:]
    draw.polygon(scaled(left), fill=WHITE)
    draw.polygon(scaled(right), fill=WHITE)
    return canvas


def save(image: Image.Image, path: Path, size: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)


def main():
    BRAND.mkdir(exist_ok=True)
    (BRAND / "source-icon.svg").write_text(svg(), encoding="utf-8")
    fg = foreground()
    bg = gradient(*PALETTES["classic"])
    full = Image.alpha_composite(bg, fg)
    save(full.convert("RGB"), BRAND / "source-rss-store-1024.png", 1024)
    save(full.convert("RGB"), BRAND / "source-rss-store-216.png", 216)
    for media in (APP_MEDIA, ENTRY_MEDIA):
        save(bg.convert("RGB"), media / "background.png", 1024)
        save(fg, media / "foreground.png", 1024)
    for name in ("aurora", "sunset", "mono"):
        alt_bg = gradient(*PALETTES[name])
        save(alt_bg.convert("RGB"), APP_MEDIA / f"background_{name}.png", 1024)
        save(Image.alpha_composite(alt_bg, fg).convert("RGB"),
             BRAND / f"source-rss-{name}-1024.png", 1024)
        (APP_MEDIA / f"layered_image_{name}.json").write_text(
            '{\n  "layered-image": {\n'
            f'    "background": "$media:background_{name}",\n'
            '    "foreground": "$media:foreground"\n  }\n}\n',
            encoding="utf-8")
    launch = full.resize((256, 256), Image.Resampling.LANCZOS)
    mask = Image.new("L", (256, 256), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 255, 255), radius=58, fill=255)
    launch.putalpha(mask)
    launch.save(ENTRY_MEDIA / "startIcon.png", optimize=True)


if __name__ == "__main__":
    main()
