from __future__ import annotations

import subprocess

from deploy.windows.tcpproxy import resolve_wsl_ipv4


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
