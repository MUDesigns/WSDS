"""Builds payload/Patches: exact line patches from the original game scripts to the mod's versions.

Usage: python make_patches.py <originals dir> <patched dir> <output dir>

Each patch is JSON:
  {"path": "Core/Game/GameMode.as", "vanilla": "<sha256>", "patched": "<sha256>",
   "hunks": [{"at": <0-based line in the original>, "remove": [original lines], "add": [new lines]}]}

Lines keep their exact line endings (files are handled as Latin-1, i.e. byte for byte), so applying the
hunks to the original reproduces the patched file exactly; Install.ps1 checks both hashes. Only lines the
mod replaces or deletes are included from the original - no surrounding context.
"""
import difflib
import hashlib
import json
import os
import re
import sys

LINE = re.compile(r"[^\n]*\n|[^\n]+")


def lines(text):
    return LINE.findall(text)


def main():
    originals, patched, out = sys.argv[1:4]
    count = 0
    for root, _dirs, files in os.walk(originals):
        for name in files:
            src = os.path.join(root, name)
            rel = os.path.relpath(src, originals).replace("\\", "/")
            dst = os.path.join(patched, rel)
            a_bytes = open(src, "rb").read()
            b_bytes = open(dst, "rb").read()
            a = lines(a_bytes.decode("latin-1"))
            b = lines(b_bytes.decode("latin-1"))
            hunks = []
            for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
                if tag != "equal":
                    hunks.append({"at": i1, "remove": a[i1:i2], "add": b[j1:j2]})
            # Self-check: the hunks rebuild the patched file exactly.
            rebuilt, pos = [], 0
            for h in hunks:
                rebuilt += a[pos:h["at"]]
                assert a[h["at"]:h["at"] + len(h["remove"])] == h["remove"]
                rebuilt += h["add"]
                pos = h["at"] + len(h["remove"])
            rebuilt += a[pos:]
            assert "".join(rebuilt).encode("latin-1") == b_bytes, rel
            patch = {
                "path": rel,
                "vanilla": hashlib.sha256(a_bytes).hexdigest().upper(),
                "patched": hashlib.sha256(b_bytes).hexdigest().upper(),
                "hunks": hunks,
            }
            target = os.path.join(out, rel + ".json")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="ascii") as f:
                json.dump(patch, f, indent=1)
            count += 1
            removed = sum(len(h["remove"]) for h in hunks)
            added = sum(len(h["add"]) for h in hunks)
            print(f"  {rel}: {len(hunks)} hunk(s), +{added} -{removed} lines")
    print(f"{count} patches written")


if __name__ == "__main__":
    main()
