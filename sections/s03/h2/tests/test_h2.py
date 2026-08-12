from __future__ import annotations

import os

import pytest

from h2.mock_store import ValidationError, cleanup, read_ticket, reset, safe_update
from h2.scenario import run_baseline, run_improved, run_read_only


@pytest.fixture(autouse=True)
def state_dir(tmp_path):
    os.environ["H2_STATE_DIR"] = str(tmp_path)
    reset()
    yield tmp_path
    cleanup()


def test_baseline_reproduces_unvalidated_side_effect():
    result = run_baseline()
    assert result["ticket"]["status"] == "closed-ish"


def test_read_only_tool_does_not_request_approval_or_write():
    result = run_read_only()
    assert result["agent"] == {"stop_reason": "end_turn", "interrupt_count": 0}
    assert result["ticket"]["status"] == "open"
    assert result["ticket"]["version"] == 1


def test_approval_pauses_then_applies_one_validated_write():
    result = run_improved("approve")
    assert result["before_decision"] == {"stop_reason": "interrupt", "interrupt_count": 1}
    assert result["ticket"]["status"] == "investigating"
    assert result["ticket"]["version"] == 2


@pytest.mark.parametrize("decision", ["deny", "timeout"])
def test_deny_and_timeout_have_no_side_effect(decision):
    result = run_improved(decision)
    assert result["ticket"]["status"] == "open"
    assert result["ticket"]["version"] == 1


def test_schema_and_optimistic_lock_reject_before_write():
    before = read_ticket("TKT-1001")
    with pytest.raises(ValidationError):
        safe_update("TKT-1001", "deleted", "Synthetic reason is long enough", 1, "REQ-ABC12345")
    with pytest.raises(ValidationError):
        safe_update("TKT-1001", "resolved", "Synthetic reason is long enough", 99, "REQ-ABC12345")
    assert read_ticket("TKT-1001") == before


def test_request_id_makes_retry_idempotent():
    first = safe_update("TKT-1001", "resolved", "Synthetic alert was verified", 1, "REQ-ABC12345")
    second = safe_update("TKT-1001", "resolved", "Synthetic alert was verified", 1, "REQ-ABC12345")
    assert first["idempotent_replay"] is False
    assert second["idempotent_replay"] is True
    assert second["version"] == 2


def test_cleanup_leaves_no_generated_state(state_dir):
    result = cleanup()
    assert result["remaining"] == []
    assert list(state_dir.iterdir()) == []
