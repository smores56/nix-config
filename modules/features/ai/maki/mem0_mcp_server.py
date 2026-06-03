#!/usr/bin/env python3
"""Local Mem0 memory exposed as a stdio MCP server for maki.

Fully local: Ollama for LLM + embeddings, Chroma (embedded) for vectors.
No network calls leave the machine except to the local Ollama endpoint.

Installed to ~/.local/share/maki-mem0/ by the nix activation script.
"""

import os
import json
from pathlib import Path

from mem0 import Memory
from mcp.server.fastmcp import FastMCP

# --- Configuration ---------------------------------------------------------

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
LLM_MODEL = os.environ.get("MEM0_LLM_MODEL", "llama3.2")
EMBED_MODEL = os.environ.get("MEM0_EMBED_MODEL", "nomic-embed-text")

# One logical memory store per project. maki runs per-project, so scope by an
# explicit env var if provided, else the working directory's basename.
PROJECT = os.environ.get("MEM0_PROJECT") or Path.cwd().name or "default"

# Persisted, embedded vector store. One dir per project keeps stores isolated.
CHROMA_DIR = os.environ.get(
    "MEM0_CHROMA_DIR",
    str(Path.home() / ".local/share/maki-mem0/chroma" / PROJECT),
)
Path(CHROMA_DIR).mkdir(parents=True, exist_ok=True)

# NOTE: verify these keys against your installed mem0ai version.
MEM0_CONFIG = {
    "llm": {
        "provider": "ollama",
        "config": {"model": LLM_MODEL, "ollama_base_url": OLLAMA_URL},
    },
    "embedder": {
        "provider": "ollama",
        "config": {"model": EMBED_MODEL, "ollama_base_url": OLLAMA_URL},
    },
    "vector_store": {
        "provider": "chroma",
        "config": {"collection_name": "maki", "path": CHROMA_DIR},
    },
}

memory = Memory.from_config(MEM0_CONFIG)
USER_ID = PROJECT  # scope all operations to this project

# --- MCP server ------------------------------------------------------------

mcp = FastMCP("mem0")


@mcp.tool()
def add_memory(text: str) -> str:
    """Save a durable fact, decision, convention, or gotcha to long-term memory.
    Keep it concise. Use for things worth remembering across sessions."""
    try:
        result = memory.add(text, user_id=USER_ID)
        return json.dumps({"ok": True, "result": result})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


@mcp.tool()
def search_memory(query: str, limit: int = 5) -> str:
    """Semantic search over long-term memory. Call before non-trivial work to
    retrieve relevant prior context (conventions, decisions, gotchas)."""
    try:
        hits = memory.search(query, user_id=USER_ID, limit=limit)
        return json.dumps({"ok": True, "results": hits})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


@mcp.tool()
def list_memories(limit: int = 50) -> str:
    """List stored memories for this project."""
    try:
        all_mem = memory.get_all(user_id=USER_ID, limit=limit)
        return json.dumps({"ok": True, "results": all_mem})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


@mcp.tool()
def delete_memory(memory_id: str) -> str:
    """Delete one memory by its id (obtained from search/list results)."""
    try:
        memory.delete(memory_id=memory_id)
        return json.dumps({"ok": True, "deleted": memory_id})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


if __name__ == "__main__":
    mcp.run()  # FastMCP defaults to stdio transport
