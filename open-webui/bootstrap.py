"""Idempotently install project-owned Open WebUI customizations.

The Open WebUI container owns the SQLite schema. This helper starts after the
WebUI health check, then merges the project filter into the persistent volume.
No Open WebUI password or API token is needed.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path


DB_PATH = Path(os.environ.get("OPEN_WEBUI_DB_PATH", "/app/backend/data/webui.db"))
FILTER_PATH = Path(
    os.environ.get(
        "OPEN_WEBUI_FILTER_PATH",
        "/opt/local-ai/functions/reasoning_effort_selector.py",
    )
)
FILTER_ID = os.environ.get("OPEN_WEBUI_FILTER_ID", "reasoning_effort_selector")
MODEL_ID = os.environ.get("MODEL_API_ID", "").strip()
MODEL_NAME = os.environ.get("MODEL_DISPLAY_NAME", "Local coding model").strip()
MODEL_VISION = os.environ.get("MODEL_VISION", "false").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}


def json_object(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def append_unique(meta: dict, key: str, value: str) -> None:
    values = meta.get(key)
    if not isinstance(values, list):
        values = []
    meta[key] = list(dict.fromkeys([*values, value]))


def connect_when_ready(timeout_seconds: int = 300) -> sqlite3.Connection:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None

    while time.monotonic() < deadline:
        try:
            connection = sqlite3.connect(DB_PATH, timeout=30)
            connection.execute("PRAGMA busy_timeout = 30000")
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            }
            if {"function", "model", "user"}.issubset(tables):
                return connection
            connection.close()
        except (OSError, sqlite3.Error) as exc:
            last_error = exc
        time.sleep(2)

    raise RuntimeError(
        f"Open WebUI database did not become ready at {DB_PATH}: {last_error}"
    )


def find_owner(connection: sqlite3.Connection) -> str | None:
    row = connection.execute(
        "SELECT id FROM user ORDER BY CASE WHEN role = 'admin' THEN 0 ELSE 1 END, created_at LIMIT 1"
    ).fetchone()
    return row[0] if row else None


def install_filter(
    connection: sqlite3.Connection, owner_id: str | None, content: str, now: int
) -> None:
    # Fail before touching the database if the checked-in function is invalid.
    namespace: dict = {}
    exec(compile(content, str(FILTER_PATH), "exec"), namespace)
    filter_instance = namespace["Filter"]()
    if not filter_instance.toggle or not hasattr(filter_instance, "UserValves"):
        raise RuntimeError("Reasoning filter must be toggleable and define UserValves")

    current = connection.execute(
        'SELECT user_id, created_at FROM "function" WHERE id = ?', (FILTER_ID,)
    ).fetchone()
    effective_owner = (current[0] if current else None) or owner_id
    created_at = current[1] if current and current[1] else now
    meta = {
        "description": (
            "Choose Low, Medium, or XHigh reasoning effort from the chat toolbar."
        ),
        "manifest": {},
        "toggle": True,
    }

    connection.execute(
        """
        INSERT INTO "function"
            (id, user_id, name, type, content, meta, valves, is_active,
             is_global, updated_at, created_at)
        VALUES (?, ?, ?, 'filter', ?, ?, ?, 1, 0, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            user_id = excluded.user_id,
            name = excluded.name,
            type = excluded.type,
            content = excluded.content,
            meta = excluded.meta,
            valves = excluded.valves,
            is_active = 1,
            is_global = 0,
            updated_at = excluded.updated_at
        """,
        (
            FILTER_ID,
            effective_owner,
            "Reasoning Effort",
            content,
            json.dumps(meta),
            json.dumps({"priority": 0}),
            now,
            created_at,
        ),
    )


def install_model_binding(
    connection: sqlite3.Connection, owner_id: str | None, now: int
) -> None:
    if not MODEL_ID:
        raise RuntimeError("MODEL_API_ID must not be empty")

    current = connection.execute(
        "SELECT user_id, name, params, meta, created_at, is_active "
        "FROM model WHERE id = ?",
        (MODEL_ID,),
    ).fetchone()

    if current:
        current_owner, current_name, params_raw, meta_raw, created_at, is_active = current
        params = json_object(params_raw)
        meta = json_object(meta_raw)
        effective_owner = current_owner or owner_id
        effective_name = (
            MODEL_NAME if not current_name or current_name == MODEL_ID else current_name
        )
        effective_created_at = created_at or now
        effective_active = 1 if is_active is None else is_active
    else:
        params = {
            # Qwen3.8 thinking-mode defaults from the upstream model card.
            "temperature": 1.0,
            "top_k": 20,
            "top_p": 0.95,
            "repeat_penalty": 1,
            "min_p": 0,
            "max_tokens": 16384,
            "function_calling": "native",
        }
        meta = {
            "profile_image_url": "/static/favicon.png",
            "capabilities": {
                "file_context": True,
                "vision": True,
                "file_upload": True,
                "code_interpreter": True,
                "terminal": True,
                "citations": True,
                "status_updates": True,
                "memory": True,
                "builtin_tools": True,
            },
            "defaultFeatureIds": ["code_interpreter"],
            "toolIds": ["server:mcp:chrome-devtools", "server:mcp:computer-use"],
        }
        effective_owner = owner_id
        effective_name = MODEL_NAME
        effective_created_at = now
        effective_active = 1

    append_unique(meta, "filterIds", FILTER_ID)
    append_unique(meta, "defaultFilterIds", FILTER_ID)
    capabilities = meta.get("capabilities")
    if not isinstance(capabilities, dict):
        capabilities = {}
    capabilities["vision"] = MODEL_VISION
    meta["capabilities"] = capabilities

    connection.execute(
        """
        INSERT INTO model
            (id, user_id, base_model_id, name, params, meta,
             updated_at, created_at, is_active)
        VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            user_id = excluded.user_id,
            name = excluded.name,
            params = excluded.params,
            meta = excluded.meta,
            updated_at = excluded.updated_at,
            is_active = excluded.is_active
        """,
        (
            MODEL_ID,
            effective_owner,
            effective_name,
            json.dumps(params),
            json.dumps(meta),
            now,
            effective_created_at,
            effective_active,
        ),
    )


def main() -> int:
    content = FILTER_PATH.read_text(encoding="utf-8")
    connection = connect_when_ready()
    now = int(time.time())

    try:
        connection.execute("BEGIN IMMEDIATE")
        owner_id = find_owner(connection)
        install_filter(connection, owner_id, content, now)
        install_model_binding(connection, owner_id, now)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    print(
        f"Installed Open WebUI filter '{FILTER_ID}' and attached it to '{MODEL_ID}'."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Open WebUI bootstrap failed: {error}", file=sys.stderr)
        raise
