#!/usr/bin/env python3
"""Make downloaded checkpoints usable on Windows without flash-attn."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


def patch_value(value: object) -> tuple[object, int]:
    changed = 0
    if isinstance(value, dict):
        result: dict[str, object] = {}
        for key, child in value.items():
            if key in {"preferred_attn_implementation", "attn_implementation"} and isinstance(child, str) and "flash" in child.lower():
                result[key] = "eager"
                changed += 1
                continue
            result_child, child_changed = patch_value(child)
            result[key] = result_child
            changed += child_changed
        return result, changed
    if isinstance(value, list):
        result_list: list[object] = []
        for child in value:
            result_child, child_changed = patch_value(child)
            result_list.append(result_child)
            changed += child_changed
        return result_list, changed
    return value, 0


def patch_file(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        original = json.load(handle)
    patched, changed = patch_value(original)
    if changed:
        fd, temporary_name = tempfile.mkstemp(prefix=path.name, dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(patched, handle, indent=2, ensure_ascii=False)
                handle.write("\n")
            os.replace(temporary_name, path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
    return changed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("model_dir", type=Path)
    args = parser.parse_args()
    paths = [args.model_dir / "config.json", args.model_dir / "audio_tokenizer" / "config.json"]
    total = 0
    for path in paths:
        if path.is_file():
            changed = patch_file(path)
            total += changed
            print(f"{path}: {changed} change(s)")
    print(f"EAGER_CONFIG_READY={total}")


if __name__ == "__main__":
    main()
