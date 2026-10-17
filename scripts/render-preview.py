#!/usr/bin/env python3
"""Render preview.png, the marketplace card, from the plugin's real UI.

scripts/preview/shell.qml opens the real widget with a made-up machine and
grabs the CPU and Memory pages at twice their on-screen size. Nothing reads
this computer's processes, addresses or drives. It needs a running Wayland
session, since the panel is a layer-shell surface: it is on screen for a few
seconds. Omarchy sizes its UI for the focused monitor and colours it with the
current theme, so render with the same monitor focused and theme set.

The marketplace card shows only a strip from the middle, about 2.7 times as
wide as it is tall, and websites crop to 16:9. So the pages are shown large
and run off the edges, with the CPU graph and the memory rings in the middle,
where every crop keeps them.

    scripts/render-preview.py [CAPTURE_DIR]           keep the captures there
    scripts/render-preview.py --reuse CAPTURE_DIR     compose from kept ones
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
SHELL = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
WALLPAPER = Path("/usr/share/omarchy/themes/ristretto/backgrounds/1-color-curves.jpg")
W, H = 2560, 1600


def capture(out):
    """Run the harness; returns the trimmed captures by name."""
    with tempfile.TemporaryDirectory(prefix="omastats-preview.") as work:
        work = Path(work)
        (work / "Commons").symlink_to(SHELL / "Commons")
        (work / "Ui").symlink_to(SHELL / "Ui")
        (work / "plugin").symlink_to(ROOT)
        (work / "shell.qml").write_text((ROOT / "scripts/preview/shell.qml").read_text())
        (work / "out").mkdir()
        env = dict(os.environ, OMASTATS_PREVIEW_OUT=str(work / "out"))
        log = subprocess.run(["timeout", "60s", "quickshell", "-p", str(work), "--no-color"],
                             env=env, capture_output=True, text=True)
        text = log.stdout + log.stderr
        # A script error in the plugin is a bug even when an image comes out.
        errors = [line for line in text.splitlines()
                  if re.search(r"TypeError|ReferenceError|SyntaxError|is not a function|is not defined|not attached to a window", line)]
        if errors:
            sys.exit("QML errors while rendering:\n" + "\n".join(errors))
        shots = {}
        for name in ("cpu", "memory"):
            path = work / "out" / f"{name}-full.png"
            if not path.exists():
                sys.exit(f"missing {path.name}\n{text}")
            image = Image.open(path).convert("RGBA")
            # The panel is grabbed with its full-screen layer; trim to the card.
            image = image.crop(image.getchannel("A").getbbox())
            image.save(out / f"{name}.png")
            shots[name] = image
        return shots


def cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - width) // 2, (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def scaled(image, factor):
    return image.resize((round(image.width * factor), round(image.height * factor)), Image.LANCZOS)


def compose(shots):
    # The wallpaper, softened and dimmed so the panels read first.
    back = cover(Image.open(WALLPAPER).convert("RGB"), W, H).filter(ImageFilter.GaussianBlur(28))
    card = ImageEnhance.Brightness(back).enhance(0.45).convert("RGBA")

    def place(image, x, y):
        nonlocal card
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            (x + 16, y + 36, x + image.width + 16, y + image.height + 36), 36, fill=(0, 0, 0, 190))
        card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(36)))
        card.alpha_composite(image, (x, y))

    memory = scaled(shots["memory"], ZOOM)
    cpu = scaled(shots["cpu"], ZOOM)
    place(memory, MEMORY_X, MEMORY_Y)
    place(cpu, CPU_X, CPU_Y)
    return card.convert("RGB")


# About the 2x captures' own size, the Memory page off the left edge and
# the CPU page off the right. Their tabs sit above the card's strip, so it
# shows the CPU graph, cores and load beside the memory rings and breakdown.
ZOOM = 1.05
MEMORY_X, MEMORY_Y = -25, 198
CPU_X, CPU_Y = 1275, 198


if __name__ == "__main__":
    args = sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix="omastats-shots.") as scratch:
        if args[:1] == ["--reuse"]:
            shots = {name: Image.open(Path(args[1]) / f"{name}.png").convert("RGBA") for name in ("cpu", "memory")}
        else:
            out = Path(args[0]) if args else Path(scratch)
            out.mkdir(parents=True, exist_ok=True)
            shots = capture(out)
        compose(shots).save(ROOT / "preview.png", optimize=True)
    print("wrote", ROOT / "preview.png", (W, H))
