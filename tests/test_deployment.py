from __future__ import annotations

import socket
import subprocess

from deploy.windows.tcpproxy import connect_wsl, resolve_wsl_ipv4


def test_wsl_ipv4_resolver_ignores_non_ipv4(monkeypatch) -> None:
    completed = subprocess.CompletedProcess(
        args=[], returncode=0, stdout="hostname\n172.20.13.198 2001:db8::1\n", stderr=""
    )
    monkeypatch.setattr(subprocess, "run", lambda *args, **kwargs: completed)
    assert resolve_wsl_ipv4("Ubuntu") == "172.20.13.198"


def test_wsl_ipv4_resolver_reports_missing_address(monkeypatch) -> None:
    completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="127.0.0.1\n", stderr="")
    monkeypatch.setattr(subprocess, "run", lambda *args, **kwargs: completed)
    try:
        resolve_wsl_ipv4("Ubuntu")
    except RuntimeError as exc:
        assert "No WSL IPv4 address" in str(exc)
    else:
        raise AssertionError("resolver should reject loopback-only output")


def test_upstream_dial_timeout_does_not_timeout_model_response(monkeypatch) -> None:
    class FakeSocket:
        def __init__(self) -> None:
            self.timeouts: list[float | None] = []

        def settimeout(self, value: float | None) -> None:
            self.timeouts.append(value)

    fake = FakeSocket()
    observed: dict[str, object] = {}

    def fake_connect(address, timeout):
        observed["address"] = address
        observed["timeout"] = timeout
        return fake

    monkeypatch.setattr(socket, "create_connection", fake_connect)
    assert connect_wsl("172.20.13.198", 7860) is fake
    assert observed == {"address": ("172.20.13.198", 7860), "timeout": 10}
    assert fake.timeouts == [None]
