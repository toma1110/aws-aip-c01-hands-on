"""Executable baseline and improved Human Approval scenarios."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from mcp import StdioServerParameters, stdio_client
from strands import Agent
from strands.tools.mcp import MCPClient
from strands.vended_interventions.hitl import HumanInTheLoop

from h2.local_model import LocalToolModel
from h2.mock_store import cleanup, read_ticket, reset


def _client() -> MCPClient:
    server = Path(__file__).with_name("mcp_server.py")
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(server)],
        env={"H2_STATE_DIR": os.environ["H2_STATE_DIR"], "PYTHONPATH": str(server.parents[1])},
    )
    return MCPClient(lambda: stdio_client(params))


def _summarize(result: Any) -> dict[str, Any]:
    return {
        "stop_reason": result.stop_reason,
        "interrupt_count": len(result.interrupts or []),
    }


def run_baseline() -> dict[str, Any]:
    reset()
    client = _client()
    client.start()
    try:
        tools = client.list_tools_sync()
        agent = Agent(
            model=LocalToolModel("baseline_update_ticket", {"ticket_id": "TKT-1001", "status": "closed-ish"}),
            tools=tools,
            system_prompt="Execute the training scenario exactly once.",
            callback_handler=None,
        )
        result = agent("Close the alert somehow")
        return {"agent": _summarize(result), "ticket": read_ticket("TKT-1001")}
    finally:
        client.stop(None, None, None)


def run_read_only() -> dict[str, Any]:
    reset()
    client = _client()
    client.start()
    try:
        tools = client.list_tools_sync(tool_filters={"allowed": ["get_ticket", "update_ticket_status"]})
        agent = Agent(
            model=LocalToolModel("get_ticket", {"ticket_id": "TKT-1001"}),
            tools=tools,
            interventions=[HumanInTheLoop(allowed_tools=["get_ticket"])],
            system_prompt="Use only the listed local training tools.",
            callback_handler=None,
        )
        result = agent("Read the synthetic alert")
        return {"agent": _summarize(result), "ticket": read_ticket("TKT-1001")}
    finally:
        client.stop(None, None, None)


def run_improved(decision: str) -> dict[str, Any]:
    reset()
    client = _client()
    client.start()
    try:
        tools = client.list_tools_sync(tool_filters={"allowed": ["get_ticket", "update_ticket_status"]})
        agent = Agent(
            model=LocalToolModel(
                "update_ticket_status",
                {
                    "ticket_id": "TKT-1001",
                    "status": "investigating",
                    "reason": "Synthetic alert confirmed by operator",
                    "expected_version": 1,
                    "request_id": "REQ-ABC12345",
                },
            ),
            tools=tools,
            interventions=[HumanInTheLoop(allowed_tools=["get_ticket"])],
            system_prompt="Use only the listed local training tools.",
            callback_handler=None,
        )
        first = agent("Mark the synthetic alert as investigating")
        output: dict[str, Any] = {"before_decision": _summarize(first)}
        if decision == "timeout":
            output["decision"] = "timeout-no-resume"
        else:
            response = "yes" if decision == "approve" else "no"
            resumed = agent(
                [{"interruptResponse": {"interruptId": first.interrupts[0].id, "response": response}}]
            )
            output["decision"] = decision
            output["after_decision"] = _summarize(resumed)
        output["ticket"] = read_ticket("TKT-1001")
        return output
    finally:
        client.stop(None, None, None)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=["baseline", "read", "approve", "deny", "timeout", "cleanup"])
    parser.add_argument("--state-dir", default=".h2-state")
    args = parser.parse_args()
    os.environ["H2_STATE_DIR"] = str(Path(args.state_dir).resolve())
    if args.scenario == "baseline":
        result = run_baseline()
    elif args.scenario == "read":
        result = run_read_only()
    elif args.scenario == "cleanup":
        result = cleanup()
    else:
        result = run_improved(args.scenario)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
