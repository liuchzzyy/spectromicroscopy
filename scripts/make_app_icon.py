"""Render the macOS app icon (.icns) from a source PNG.

Usage: python scripts/make_app_icon.py GUI/Resources/Mantis_logo_about.png GUI/Resources/Mantis_logo.icns

The source artwork is used as-is: it is scaled to every size the icon needs and centred
on a transparent square so the aspect ratio cannot distort it. Nothing is cropped,
redrawn or recoloured. iconutil requires a full .iconset directory, which is created
next to the output and removed afterwards.
"""
from pathlib import Path
import subprocess
import sys

from PIL import Image

# Canonical iconset slots required by iconutil.
SLOTS = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def build(source, destination):
    source, destination = Path(source), Path(destination)
    if not source.is_file():
        raise SystemExit(f"Missing logo artwork: {source}")
    artwork = Image.open(source).convert("RGBA")
    # Keep every pixel; only pad out to a square so scaling cannot distort the artwork.
    side = max(artwork.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(artwork, ((side - artwork.width) // 2, (side - artwork.height) // 2))

    destination.parent.mkdir(parents=True, exist_ok=True)
    iconset = destination.parent / f"{destination.stem}.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for name, size in SLOTS.items():
        square.resize((size, size), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)
    for written in iconset.iterdir():
        written.unlink()
    iconset.rmdir()
    print(f"Built {destination} from {source} (source {artwork.width}x{artwork.height}, "
          f"{len(SLOTS)} icon sizes, no cropping)")
    return destination


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    build(sys.argv[1], sys.argv[2])
