"""
Claude Mobile — FastAPI backend
Bridges the mobile chat UI with the Claude Agent SDK.
"""

import asyncio
import json
import logging
import os
from pathlib import Path

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("claude-mobile")

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
import uvicorn

from claude_agent_sdk import (
    AssistantMessage,
    CLIConnectionError,
    CLINotFoundError,
    ClaudeAgentOptions,
    ResultMessage,
    SystemMessage,  # used to detect init and mark session active
    TextBlock,
    query,
)

load_dotenv()

app = FastAPI(title="Claude Mobile")
app.mount("/static", StaticFiles(directory="static"), name="static")

# Track which web sessions have had at least one exchange (so we can --continue)
_active_sessions: set[str] = set()

PERMISSION_MODE = os.getenv("PERMISSION_MODE", "acceptEdits")
WORKING_DIR = os.getenv("WORKING_DIR", str(Path.home()))
AUTH_TOKEN = os.getenv("AUTH_TOKEN", "")
PORT = int(os.getenv("PORT", "8765"))

ALLOWED_TOOLS = [
    "Read", "Write", "Edit", "Bash",
    "Glob", "Grep", "WebSearch", "WebFetch",
]


def load_mcp_servers() -> dict:
    """Read MCP server definitions from Claude Code's global settings."""
    for settings_path in [
        Path.home() / ".claude" / "settings.json",
        Path.home() / ".config" / "claude" / "settings.json",
    ]:
        if settings_path.exists():
            try:
                data = json.loads(settings_path.read_text())
                servers = data.get("mcpServers", {})
                if servers:
                    return servers
            except Exception:
                pass
    return {}


def build_options(session_id: str) -> ClaudeAgentOptions:
    # Remove CLAUDECODE so the bundled CLI can spawn inside an active session.
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    mcp_servers = load_mcp_servers()
    is_continuation = session_id in _active_sessions

    if is_continuation:
        logger.info("Continuing session %s with --continue", session_id)

    return ClaudeAgentOptions(
        cwd=WORKING_DIR,
        allowed_tools=ALLOWED_TOOLS,
        permission_mode=PERMISSION_MODE,
        mcp_servers=mcp_servers or {},
        env=env,
        continue_conversation=is_continuation,
    )


async def _run_sdk_query(
    prompt: str,
    options: ClaudeAgentOptions,
    out: asyncio.Queue,
) -> None:
    """Run query() in its own task so anyio cancel scopes never cross task boundaries."""
    def log_stderr(line: str) -> None:
        logger.error("CLI stderr: %s", line)

    options.stderr = log_stderr
    try:
        async for msg in query(prompt=prompt, options=options):
            await out.put(("msg", msg))
    except Exception as exc:
        await out.put(("err", exc))
    finally:
        await out.put(("done", None))


@app.get("/")
async def serve_ui():
    return FileResponse("static/index.html")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    # Optional bearer-token auth via query param: ?token=SECRET
    if AUTH_TOKEN:
        token = websocket.query_params.get("token", "")
        if token != AUTH_TOKEN:
            await websocket.close(code=4001, reason="Unauthorized")
            return

    await websocket.accept()

    async def send(data: dict) -> None:
        try:
            await websocket.send_text(json.dumps(data))
        except Exception as exc:
            logger.warning("send() failed: %s", exc)

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                await send({"type": "error", "message": "Invalid JSON"})
                continue

            # --- reset: clear session context ---
            if data.get("reset"):
                _active_sessions.discard(session_id)
                await send({"type": "reset_ok"})
                continue

            user_message = data.get("message", "").strip()
            if not user_message:
                continue

            await send({"type": "thinking"})

            options = build_options(session_id)

            # Run the SDK query in an isolated task — anyio cancel scopes
            # must not be entered/exited across different asyncio tasks.
            queue: asyncio.Queue = asyncio.Queue()
            q_task = asyncio.create_task(
                _run_sdk_query(user_message, options, queue)
            )
            try:
                while True:
                    kind, value = await queue.get()
                    if kind == "done":
                        break
                    if kind == "err":
                        raise value
                    msg = value
                    if isinstance(msg, SystemMessage) and msg.subtype == "init":
                        _active_sessions.add(session_id)
                        logger.info("Session init: web=%s", session_id)
                    elif isinstance(msg, AssistantMessage):
                        for block in msg.content:
                            if isinstance(block, TextBlock) and block.text:
                                await send({"type": "text", "content": block.text})
                    elif isinstance(msg, ResultMessage):
                        await send({"type": "done", "result": msg.result})

            except CLINotFoundError:
                await send({
                    "type": "error",
                    "message": (
                        "Claude Code CLI not found.\n"
                        "Install it with:  npm install -g @anthropic-ai/claude-code"
                    ),
                })
            except CLIConnectionError as exc:
                await send({"type": "error", "message": f"CLI connection error: {exc}"})
            except Exception as exc:
                await send({"type": "error", "message": str(exc)})
            finally:
                if not q_task.done():
                    q_task.cancel()

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        logger.exception("WebSocket handler crashed: %s", exc)


if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=PORT,
        log_level="info",
        reload=False,
    )
