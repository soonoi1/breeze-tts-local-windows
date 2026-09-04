#!/usr/bin/env python3
"""Resilient Windows TCP bridge from LAN :9000 to the current WSL API :7860.

WSL2 assigns a new NAT address after some reboots. Resolve the address for every
incoming connection instead of keeping a stale hard-coded target.
"""

from __future__ import annotations

import argparse
import ipaddress
import logging
import socket
import subprocess
import threading
from pathlib import Path


def resolve_wsl_ipv4(distro: str) -> str:
    result = subprocess.run(
        ["wsl.exe", "-d", distro, "--", "hostname", "-I"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    for token in result.stdout.split():
        try:
            address = ipaddress.ip_address(token)
        except ValueError:
            continue
        if isinstance(address, ipaddress.IPv4Address) and not address.is_loopback:
            return str(address)
    raise RuntimeError(f"No WSL IPv4 address found for distro {distro!r}: {result.stdout!r}")


def connect_wsl(target_ip: str, wsl_port: int) -> socket.socket:
    """Connect with a dial timeout, then wait indefinitely for model output."""
    upstream = socket.create_connection((target_ip, wsl_port), timeout=10)
    upstream.settimeout(None)
    return upstream


def pipe(source: socket.socket, destination: socket.socket) -> None:
    try:
        while True:
            payload = source.recv(64 * 1024)
            if not payload:
                return
            destination.sendall(payload)
    except (ConnectionError, OSError):
        return
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client: socket.socket, distro: str, wsl_port: int, log: logging.Logger) -> None:
    upstream: socket.socket | None = None
    try:
        target_ip = resolve_wsl_ipv4(distro)
        upstream = connect_wsl(target_ip, wsl_port)
        # The timeout is only for TCP connection establishment. A model reload
        # can legitimately take ~50s before the first response byte.
        client.settimeout(None)
        log.info("bridge %s -> %s:%s", client.getpeername(), target_ip, wsl_port)
        left = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
        right = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
        left.start()
        right.start()
        left.join()
        right.join()
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:  # one bad connection must not kill the proxy
        log.warning("connection failed: %s", exc)
    finally:
        for connection in (client, upstream):
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass


def serve(listen_host: str, listen_port: int, distro: str, wsl_port: int, log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(log_path),
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log = logging.getLogger("breeze-proxy")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((listen_host, listen_port))
        server.listen(128)
        log.info("listening on %s:%s -> WSL %s:%s", listen_host, listen_port, distro, wsl_port)
        while True:
            client, address = server.accept()
            client.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            thread = threading.Thread(
                target=handle,
                args=(client, distro, wsl_port, log),
                daemon=True,
            )
            thread.start()
            log.info("accepted %s", address)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=9000)
    parser.add_argument("--distro", default="Ubuntu")
    parser.add_argument("--wsl-port", type=int, default=7860)
    parser.add_argument("--log-file", type=Path, default=Path("breeze-proxy.log"))
    args = parser.parse_args()
    serve(args.listen_host, args.listen_port, args.distro, args.wsl_port, args.log_file)


if __name__ == "__main__":
    main()
