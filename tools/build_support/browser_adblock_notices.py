#!/usr/bin/env python3
"""Emit deterministic notices from Cargo metadata; write source edits via apply_patch."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[2]
metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
included = {node["id"] for node in metadata["resolve"]["nodes"]}
texts = {}
print("Nightfall browser blocker — pinned Rust dependency notices")
print("Cargo.lock SHA256: " + hashlib.sha256((root / "extensions/browser-adblock/Cargo.lock").read_bytes()).hexdigest())
print("Sources: https://crates.io/crates/<package>/<version> (unmodified upstream crates).")
for package in sorted(metadata["packages"], key=lambda p: p["name"]):
    if package["id"] not in included or package["source"] is None:
        continue
    print("\n" + package["name"] + " " + package["version"])
    print("Declared licence: " + str(package["license"]))
    print(("Authors: " + "; ".join(package["authors"])).rstrip())
    print("Source: https://crates.io/crates/" + package["name"] + "/" + package["version"])
    folder = pathlib.Path(package["manifest_path"]).parent
    candidates = list(folder.iterdir())
    for directory in (folder / "licenses", folder / "licences"):
        if directory.is_dir():
            candidates.extend(directory.iterdir())
    if package.get("license_file"):
        candidates.append(folder / package["license_file"])
    found = False
    for path in sorted(set(candidates)):
        if not path.is_file() or not path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")):
            continue
        content = path.read_text(errors="replace").strip()
        digest = hashlib.sha256(content.encode()).hexdigest()
        texts.setdefault(digest, content)
        print("  " + path.name + " — licence text " + digest)
        found = True
    if not found:
        print("  No separate licence text in crate archive; refer to declared licence and source above.")
for digest, text in sorted(texts.items()):
    print("\n" + "=" * 72 + "\nLicence text " + digest + "\n" + "=" * 72 + "\n" + text)
