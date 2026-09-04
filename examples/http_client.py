#!/usr/bin/env python3
"""Small dependency-free client for the local Breeze streaming API."""

from __future__ import annotations

import argparse
import mimetypes
import secrets
import struct
import time
import urllib.request
from pathlib import Path


def field(boundary: str, name: str, value: str) -> bytes:
    return (
        f"--{boundary}\r\n"
        f"Content-Disposition: form-data; name=\"{name}\"\r\n\r\n"
        f"{value}\r\n"
    ).encode()


def file_field(boundary: str, name: str, path: Path) -> bytes:
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return (
        f"--{boundary}\r\n"
        f"Content-Disposition: form-data; name=\"{name}\"; filename=\"{path.name}\"\r\n"
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode() + path.read_bytes() + b"\r\n"


def pcm_to_wav(pcm: bytes, sample_rate: int, channels: int = 1) -> bytes:
    data_size = len(pcm)
    header = b"RIFF" + struct.pack("<I", 36 + data_size) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, sample_rate,
                                     sample_rate * channels * 2, channels * 2, 16)
    return header + b"data" + struct.pack("<I", data_size) + pcm


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:9000")
    parser.add_argument("--text", required=True)
    parser.add_argument("--instruction", default="Speak clearly and naturally.")
    parser.add_argument("--cfg-scale", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--ref-audio", type=Path)
    parser.add_argument("--ref-text")
    parser.add_argument("--output", type=Path, default=Path("breeze-output.wav"))
    args = parser.parse_args()

    if (args.ref_audio is None) != (not bool(args.ref_text)):
        parser.error("--ref-audio and --ref-text must be provided together")
    if args.ref_audio is not None and not args.ref_audio.is_file():
        parser.error(f"reference audio not found: {args.ref_audio}")

    boundary = "----breeze-" + secrets.token_hex(12)
    body = b"".join([
        field(boundary, "text", args.text),
        field(boundary, "instruction", args.instruction),
        field(boundary, "cfg_scale", str(args.cfg_scale)),
        field(boundary, "seed", str(args.seed)),
        file_field(boundary, "ref_audio", args.ref_audio) if args.ref_audio else b"",
        field(boundary, "ref_text", args.ref_text) if args.ref_text else b"",
        f"--{boundary}--\r\n".encode("ascii"),
    ])
    request = urllib.request.Request(
        args.url.rstrip("/") + "/v1/audio/speech",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=600) as response:
        first_byte = None
        chunks: list[bytes] = []
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            if first_byte is None:
                first_byte = time.monotonic()
            chunks.append(chunk)
        pcm = b"".join(chunks)
        sample_rate = int(response.headers.get("X-Sample-Rate", "24000"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(pcm_to_wav(pcm, sample_rate))
    elapsed = time.monotonic() - started
    ttfa = (first_byte - started) if first_byte else None
    print(f"WROTE={args.output} bytes={args.output.stat().st_size} "
          f"sample_rate={sample_rate} elapsed={elapsed:.2f}s "
          f"ttfa={(f'{ttfa:.2f}s' if ttfa is not None else 'n/a')}")


if __name__ == "__main__":
    main()
