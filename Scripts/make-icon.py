#!/usr/bin/env python3
"""Builds the macOS app icon set from docs/icon/ConnectLLM.jpeg.

Crops the glass tile with a margin of its dark backdrop, masks it to the macOS icon
squircle (824 px plate on a 1024 canvas, corner radius about 22.4%), adds the template's
soft shadow, and writes every size into Resources/Assets.xcassets/AppIcon.appiconset.
Needs Pillow (`pip install pillow`).
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
source = root / "docs/icon/ConnectLLM.jpeg"
iconset = root / "Resources/Assets.xcassets/AppIcon.appiconset"


def master() -> Image.Image:
    src = Image.open(source).convert("RGB")
    # The tile spans about 118..906 of the 1024 source; keep some backdrop around it.
    crop = src.crop((56, 56, 968, 968)).resize((824, 824), Image.LANCZOS)
    scale = 4
    mask = Image.new("L", (824 * scale, 824 * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, 824 * scale - 1, 824 * scale - 1), radius=185 * scale, fill=255)
    mask = mask.resize((824, 824), Image.LANCZOS)
    plate = Image.new("RGBA", (824, 824))
    plate.paste(crop, (0, 0))
    plate.putalpha(mask)
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (1024, 1024), 0)
    shadow_mask.paste(mask, (100, 112))
    shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(14)).point(lambda a: int(a * 0.35)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(plate, (100, 100))
    return canvas


def main() -> None:
    icon = master()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            icon.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}",
                           "filename": name})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (iconset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"wrote {len(images)} icons to {iconset.relative_to(root)}")


if __name__ == "__main__":
    main()
