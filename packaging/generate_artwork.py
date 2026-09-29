"""Regenerate the DMG background and macOS icon (requires Pillow)."""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "packaging"
RESOURCES = ROOT / "Sources" / "LightweightReader" / "Resources"
SCALE = 2


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "Arial Bold.ttf" if bold else "Arial.ttf"
    return ImageFont.truetype(f"/System/Library/Fonts/Supplemental/{name}", size * SCALE)


def at(value: int) -> int:
    return value * SCALE


def installer_background() -> None:
    width, height = at(960), at(650)
    canvas = Image.new("RGB", (width, height), "#f7f5f0")
    draw = ImageDraw.Draw(canvas)
    for y in range(height):
        t = y / height
        color = tuple(round(a * (1 - t) + b * t) for a, b in zip((248, 247, 242), (237, 242, 245)))
        draw.line((0, y, width, y), fill=color)

    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse((at(-140), at(25), at(490), at(610)), fill=(240, 205, 181, 95))
    g.ellipse((at(510), at(-165), at(1100), at(500)), fill=(163, 196, 217, 100))
    glow = glow.filter(ImageFilter.GaussianBlur(at(85)))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), glow)
    d = ImageDraw.Draw(canvas)

    d.rounded_rectangle((at(69), at(47), at(289), at(80)), radius=at(16), fill="#e7e8e2")
    d.text((at(88), at(54)), "A CALMER WAY TO READ", font=font(12, True), fill="#365367")
    d.text((at(68), at(101)), "Lightweight Reader", font=font(50, True), fill="#183448")
    d.text((at(72), at(174)), "PDF, Markdown and JSON — all in one quiet place.", font=font(22), fill="#557080")

    # The clear circles frame Finder's app and Applications icons without covering them.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for x in (248, 712):
        sd.rounded_rectangle((at(x - 115), at(247), at(x + 115), at(453)), radius=at(36), fill=(29, 60, 80, 36))
    shadow = shadow.filter(ImageFilter.GaussianBlur(at(19)))
    canvas = Image.alpha_composite(canvas, shadow)
    d = ImageDraw.Draw(canvas)
    for x in (248, 712):
        d.rounded_rectangle((at(x - 115), at(239), at(x + 115), at(445)), radius=at(36), fill="#ffffff", outline="#dce5e8", width=at(1))

    # A soft arrow guides the standard drag-to-Applications gesture.
    d.line((at(405), at(343), at(549), at(343)), fill="#648c9b", width=at(6), joint="curve")
    d.line((at(528), at(325), at(551), at(343), at(528), at(361)), fill="#648c9b", width=at(6), joint="curve")
    d.text((at(416), at(378)), "DRAG TO INSTALL", font=font(14, True), fill="#4e7180")

    d.line((at(70), at(506), at(890), at(506)), fill="#cddadf", width=at(1))
    d.text((at(70), at(526)), "1", font=font(15, True), fill="#f1765b")
    d.text((at(94), at(526)), "Drop the app into Applications", font=font(16, True), fill="#315062")
    d.text((at(70), at(559)), "2", font=font(15, True), fill="#f1765b")
    d.text((at(94), at(559)), "Open it from Applications", font=font(16, True), fill="#315062")
    d.text((at(699), at(547)), "Made for macOS", font=font(15), fill="#6b8590")

    path = ART / "InstallerBackground.png"
    canvas.convert("RGB").resize((960, 650), Image.Resampling.LANCZOS).save(path, optimize=True)
    canvas.convert("RGB").save(ART / "InstallerBackground@2x.png", optimize=True)
    print(path)


def app_icon() -> None:
    size = 1024
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gradient = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(a * (1 - t) + b * t) for a, b in zip((48, 91, 114), (20, 47, 69)))
        gd.line((0, y, size, y), fill=(*color, 255))
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((35, 25, 989, 979), radius=220, fill=255)
    icon.paste(gradient, (0, 0), mask)

    halo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.ellipse((188, 108, 900, 820), fill=(158, 204, 216, 88))
    halo = halo.filter(ImageFilter.GaussianBlur(80))
    halo.putalpha(Image.composite(halo.getchannel("A"), Image.new("L", (size, size), 0), mask))
    icon = Image.alpha_composite(icon, halo)

    page_shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ps = ImageDraw.Draw(page_shadow)
    ps.rounded_rectangle((226, 258, 805, 768), radius=75, fill=(7, 30, 44, 140))
    icon = Image.alpha_composite(icon, page_shadow.filter(ImageFilter.GaussianBlur(31)))
    d = ImageDraw.Draw(icon)

    # Two slightly curved pages make the reading metaphor legible at Dock size.
    left = [(225, 292), (318, 268), (407, 274), (492, 312), (492, 751), (409, 713), (321, 704), (225, 725)]
    right = [(532, 312), (617, 274), (706, 268), (799, 292), (799, 725), (703, 704), (615, 713), (532, 751)]
    d.polygon(left, fill="#fffaf0")
    d.polygon(right, fill="#f0f5f2")
    d.line((512, 316, 512, 753), fill="#9db9bb", width=20)
    for y, widths in [(384, 155), (450, 186), (516, 168), (582, 180)]:
        d.line((270, y, 270 + widths, y + 8), fill="#b3c4c4", width=16)
        d.line((754 - widths, y + 8, 754, y), fill="#b1c8ca", width=16)
    # A coral bookmark is the small focal point of the icon.
    d.polygon([(672, 286), (741, 279), (741, 440), (706, 414), (672, 446)], fill="#ed8062")
    source = ART / "AppIcon-1024.png"
    icon.save(source, optimize=True)
    iconset = ART / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    sizes = {16: [1, 2], 32: [1, 2], 128: [1, 2], 256: [1, 2], 512: [1, 2]}
    for points, scales in sizes.items():
        for scale in scales:
            suffix = "@2x" if scale == 2 else ""
            output = iconset / f"icon_{points}x{points}{suffix}.png"
            icon.resize((points * scale, points * scale), Image.Resampling.LANCZOS).save(output)
    target = RESOURCES / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(target)], check=True)
    print(target)


def installer_preview() -> None:
    preview = Image.open(ART / "InstallerBackground@2x.png").convert("RGBA")
    app = Image.open(ART / "AppIcon-1024.png").convert("RGBA").resize((220, 220), Image.Resampling.LANCZOS)
    applications = Image.open(
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
    ).convert("RGBA").resize((250, 250), Image.Resampling.LANCZOS)
    preview.alpha_composite(app, (496 - 110, 555))
    preview.alpha_composite(applications, (1424 - 125, 548))
    draw = ImageDraw.Draw(preview)
    labels = [("Lightweight Reader", 496), ("Applications", 1424)]
    for label, center in labels:
        text_font = font(17)
        width = draw.textbbox((0, 0), label, font=text_font)[2]
        draw.text((center - width / 2, 815), label, font=text_font, fill="#1d2931")
    destination = ROOT / "dist" / "InstallerPreview.png"
    destination.parent.mkdir(exist_ok=True)
    preview.convert("RGB").save(destination, optimize=True)
    print(destination)


if __name__ == "__main__":
    installer_background()
    app_icon()
    installer_preview()
