#!/usr/bin/env python3
"""Download and validate the Breeze TTS 2 checkpoint."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--repo-id", default="BreezeBlue/Breeze-TTS-2")
    parser.add_argument("--revision", default=None)
    parser.add_argument("--endpoint", default=None)
    args = parser.parse_args()

    if args.endpoint:
        os.environ["HF_ENDPOINT"] = args.endpoint

    from huggingface_hub import snapshot_download

    args.dest.parent.mkdir(parents=True, exist_ok=True)
    resolved = snapshot_download(
        repo_id=args.repo_id,
        revision=args.revision,
        local_dir=str(args.dest),
    )
    required = [args.dest / "config.json", args.dest / "audio_tokenizer" / "config.json"]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise RuntimeError("Checkpoint is incomplete; missing: " + ", ".join(missing))
    print(f"MODEL_READY={resolved}")


if __name__ == "__main__":
    main()
