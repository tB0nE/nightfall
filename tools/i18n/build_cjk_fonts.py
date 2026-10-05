#!/usr/bin/env python3
"""Rebuild the bundled CJK font subsets from the locale dictionaries.

Godot's default font has no Chinese, Japanese, or Korean characters, so each
CJK locale ships a Noto Sans CJK subset holding only the characters its
dictionary (plus the language picker) uses. Run this after editing
a CJK dictionary (locale/ja, ko, zh_CN, zh_TW); test/test_localization.gd
fails if a dictionary uses a character its font lacks.

Requires fontTools (pip install fonttools) and Noto Sans CJK Regular
(Fedora: google-noto-sans-cjk-fonts).
"""
import json
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTCollection

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc")
OUT_DIR = ROOT / "src/assets/fonts"
# Face index inside the collection, chosen per language so shared Han
# characters use that language's glyph forms.
FACES = {"ja": 0, "ko": 1, "zh_CN": 2, "zh_TW": 3}
# Language names are shown in their own script in every language's picker,
# and the picker's arrow is missing from Godot's default font too.
PICKER_NAMES = "日本語한국어简体中文繁體中文\u25BC"


def main() -> int:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else SOURCE
    collection = TTCollection(str(source))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for code, face in FACES.items():
        messages = json.loads((ROOT / f"locale/{code}.json").read_text(encoding="utf-8"))
        text = "".join(v for k, v in messages.items() if not k.startswith("_")) + PICKER_NAMES
        chars = sorted({c for c in text if ord(c) > 0x7F})
        font = collection.fonts[face]
        options = subset.Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.notdef_outline = True
        subsetter = subset.Subsetter(options)
        subsetter.populate(unicodes=[ord(c) for c in chars])
        subsetter.subset(font)
        out = OUT_DIR / f"noto-sans-cjk-{code}-subset.otf"
        font.save(str(out))
        print(f"{out.relative_to(ROOT)}: {len(chars)} characters, {out.stat().st_size // 1024} KiB")
        collection = TTCollection(str(source))  # subsetting mutates the face
    return 0


if __name__ == "__main__":
    sys.exit(main())
