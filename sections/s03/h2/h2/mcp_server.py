"""Minimal stdio MCP server exposing read and local mock write tools."""

from mcp.server.fastmcp import FastMCP

from h2.mock_store import read_ticket, safe_update, unsafe_update

mcp = FastMCP("h2-local-ticket-tools", json_response=True)


@mcp.tool()
def get_ticket(ticket_id: str) -> dict:
    """Read one synthetic ticket. This tool has no side effect."""
    return read_ticket(ticket_id)


@mcp.tool()
def baseline_update_ticket(ticket_id: str, status: str) -> dict:
    """Training-only weak write used to observe the unsafe baseline."""
    return unsafe_update(ticket_id, status)


@mcp.tool()
def update_ticket_status(
    ticket_id: str,
    status: str,
    reason: str,
    expected_version: int,
    request_id: str,
) -> dict:
    """Update a synthetic ticket after strict validation and approval by the client."""
    return safe_update(ticket_id, status, reason, expected_version, request_id)


if __name__ == "__main__":
    mcp.run(transport="stdio")
