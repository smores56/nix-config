"""Print the SQL that seeds LobeChat's connector tool lists.

LobeChat only fetches a connector's tools on the first agent run, so a seeded
connector sits with an empty tool list until the user chats. This lists each
local MCP server directly and emits idempotent inserts, letting the seed unit
populate tools alongside the connector rows.

Reads `CONNECTOR_SEED_ENDPOINTS`, a JSON list of
`{identifier, url, headers}`. Writes SQL to stdout.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

DELETE_PREFIX = r"^(?:delete|remove|destroy|drop|unlink|uninstall|clear|purge)"
UPDATE_PREFIX = r"^(?:update|edit|modify|patch|set|change|rename|move)"
READ_PREFIX = r"^(?:get|list|read|fetch|search|find|check|describe|show|view|extract|query|count)"

LIST_TIMEOUT_SECONDS = 30


def _infer_crud_type(tool_name: str) -> str:
    """Mirror `src/libs/mcp/utils.ts` so permissions render the same."""
    name = tool_name.lower()
    if re.match(DELETE_PREFIX, name):
        return "delete"
    if re.match(UPDATE_PREFIX, name):
        return "update"
    if re.match(READ_PREFIX, name):
        return "read"
    return "write"


def _literal(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


async def _list_tools(endpoint: dict[str, object]):
    headers = endpoint.get("headers") or {}
    async with streamablehttp_client(str(endpoint["url"]), headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await asyncio.wait_for(session.initialize(), LIST_TIMEOUT_SECONDS)
            result = await asyncio.wait_for(session.list_tools(), LIST_TIMEOUT_SECONDS)
            return result.tools


def _statements(endpoint: dict[str, object], tools) -> list[str]:
    identifier = str(endpoint["identifier"])
    rows: list[str] = []
    for tool in tools:
        schema = json.dumps(tool.inputSchema or {}, ensure_ascii=False)
        output_schema = getattr(tool, "outputSchema", None)
        rendered_output = (
            _literal(json.dumps(output_schema, ensure_ascii=False)) + "::jsonb"
            if output_schema
            else "NULL"
        )
        rows.append(
            "INSERT INTO user_connector_tools"
            " (user_connector_id, user_id, workspace_id, tool_name, description,"
            " input_schema, output_schema, crud_type, permission)"
            " SELECT c.id, c.user_id, c.workspace_id, "
            f"{_literal(tool.name)}, {_literal(tool.description or '')}, "
            f"{_literal(schema)}::jsonb, {rendered_output}, "
            f"{_literal(_infer_crud_type(tool.name))}, 'auto'"
            " FROM user_connectors c"
            f" WHERE c.identifier = {_literal(identifier)} AND c.workspace_id IS NULL AND c.agent_id IS NULL"
            " ON CONFLICT (user_connector_id, tool_name) DO NOTHING;"
        )
    return rows


async def _main() -> int:
    raw = os.environ.get("CONNECTOR_SEED_ENDPOINTS", "")
    endpoints = json.loads(raw) if raw else []
    if not endpoints:
        print("connector-seed: CONNECTOR_SEED_ENDPOINTS is empty", file=sys.stderr)
        return 1
    statements: list[str] = []
    for endpoint in endpoints:
        try:
            tools = await _list_tools(endpoint)
        except Exception as exc:  # noqa: BLE001 - surface the endpoint, fail the unit
            print(
                f"connector-seed: {endpoint.get('identifier')} at {endpoint.get('url')} "
                f"did not list tools: {exc}",
                file=sys.stderr,
            )
            return 1
        statements.extend(_statements(endpoint, tools))
        print(f"connector-seed: {endpoint.get('identifier')} listed {len(tools)} tools", file=sys.stderr)
    print("\n".join(statements))
    return 0


def main() -> int:
    return asyncio.run(_main())


if __name__ == "__main__":
    raise SystemExit(main())
