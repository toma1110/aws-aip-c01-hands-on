"""A file-backed mock ticket store used only inside the hands-on workspace."""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

TICKET_PATTERN = re.compile(r"^TKT-[0-9]{4}$")
ALLOWED_STATUSES = {"investigating", "resolved"}


class ValidationError(ValueError):
    """Raised before a mock write when an input violates the tool contract."""


def _workspace() -> Path:
    configured = os.environ.get("H2_STATE_DIR")
    if not configured:
        raise RuntimeError("H2_STATE_DIR is required")
    root = Path(configured).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def _path(name: str) -> Path:
    root = _workspace()
    candidate = (root / name).resolve()
    if candidate.parent != root:
        raise RuntimeError("state path escaped the hands-on workspace")
    return candidate


def _write_json(path: Path, value: Any) -> None:
    fd, temp_name = tempfile.mkstemp(prefix="h2-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def reset() -> dict[str, Any]:
    initial = {
        "TKT-1001": {
            "ticket_id": "TKT-1001",
            "summary": "Synthetic checkout latency alert",
            "status": "open",
            "version": 1,
        }
    }
    _write_json(_path("tickets.json"), initial)
    _write_json(_path("audit.json"), [])
    return initial


def cleanup() -> dict[str, Any]:
    removed: list[str] = []
    for name in ("tickets.json", "audit.json"):
        path = _path(name)
        if path.exists():
            path.unlink()
            removed.append(name)
    remaining = sorted(p.name for p in _workspace().iterdir())
    return {"removed": removed, "remaining": remaining}


def _load(name: str, default: Any) -> Any:
    path = _path(name)
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def read_ticket(ticket_id: str) -> dict[str, Any]:
    if not TICKET_PATTERN.fullmatch(ticket_id):
        raise ValidationError("ticket_id must match TKT-0000")
    ticket = _load("tickets.json", {}).get(ticket_id)
    if ticket is None:
        raise ValidationError("ticket not found")
    return ticket


def unsafe_update(ticket_id: str, status: str) -> dict[str, Any]:
    """Deliberately weak baseline. It is never suitable for a real system."""
    tickets = _load("tickets.json", {})
    ticket = tickets.get(ticket_id)
    if ticket is None:
        raise ValidationError("ticket not found")
    before = dict(ticket)
    ticket["status"] = status
    ticket["version"] += 1
    _write_json(_path("tickets.json"), tickets)
    _append_audit("baseline-write", before, ticket, {"status": status})
    return ticket


def safe_update(
    ticket_id: str,
    status: str,
    reason: str,
    expected_version: int,
    request_id: str,
) -> dict[str, Any]:
    if not TICKET_PATTERN.fullmatch(ticket_id):
        raise ValidationError("ticket_id must match TKT-0000")
    if status not in ALLOWED_STATUSES:
        raise ValidationError("status must be investigating or resolved")
    if len(reason.strip()) < 12:
        raise ValidationError("reason must contain at least 12 characters")
    if not re.fullmatch(r"REQ-[A-Z0-9]{8}", request_id):
        raise ValidationError("request_id must match REQ-XXXXXXXX")

    tickets = _load("tickets.json", {})
    ticket = tickets.get(ticket_id)
    if ticket is None:
        raise ValidationError("ticket not found")
    audits = _load("audit.json", [])
    previous = next((event for event in audits if event.get("request_id") == request_id), None)
    if previous:
        return {**ticket, "idempotent_replay": True}
    if ticket["version"] != expected_version:
        raise ValidationError("expected_version does not match current version")

    before = dict(ticket)
    ticket["status"] = status
    ticket["version"] += 1
    _write_json(_path("tickets.json"), tickets)
    _append_audit(
        "approved-write",
        before,
        ticket,
        {"reason": reason.strip(), "request_id": request_id},
    )
    return {**ticket, "idempotent_replay": False}


def _append_audit(event_type: str, before: dict[str, Any], after: dict[str, Any], details: dict[str, Any]) -> None:
    audit = _load("audit.json", [])
    audit.append(
        {
            "event_type": event_type,
            "occurred_at": datetime.now(UTC).isoformat(),
            "ticket_id": after["ticket_id"],
            "before_status": before["status"],
            "after_status": after["status"],
            **details,
        }
    )
    _write_json(_path("audit.json"), audit)
