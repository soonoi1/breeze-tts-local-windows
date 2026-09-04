from __future__ import annotations

from breeze_infer import api


def test_request_lease_owner_cannot_release_new_owner() -> None:
    first = api._try_acquire_request()
    assert first is not None
    assert api._try_acquire_request() is None
    api._release_request(first)

    second = api._try_acquire_request()
    assert second is not None
    assert second != first
    api._release_request(first)
    assert api._try_acquire_request() is None
    api._release_request(second)


def test_stale_lease_recovery_is_explicit() -> None:
    lease = api._try_acquire_request()
    assert lease is not None
    assert api._force_release_stale_request() is True
    current = api._try_acquire_request()
    assert current is not None
    api._release_request(current)
