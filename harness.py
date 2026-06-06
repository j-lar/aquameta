#!/usr/bin/env python3
"""
Aquameta AI run harness — v1 minimal.

Listens on 'ai_run_pending' NOTIFY channel. On wakeup, claims the oldest
pending run via ai.claim_next_run(), calls the Anthropic API with the run's
intent, writes the response as an ai.message row, and marks the run complete.

Startup drain ensures runs queued while the harness was down are not lost.
"""

import re
import select
import sys
import logging
from datetime import datetime, timezone

import psycopg2
import anthropic

DSN = "host=localhost port=5432 dbname=aquameta user=aquameta password=aquameta client_encoding=UTF8"
MODEL = "claude-sonnet-4-6"
MAX_TOKENS = 8096
CHANNEL = "ai_run_pending"
HEARTBEAT_SECS = 60  # fallback poll interval — catches any missed NOTIFYs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


def claim(conn) -> str | None:
    with conn.cursor() as cur:
        cur.execute("SELECT ai.claim_next_run()")
        row = cur.fetchone()
    conn.commit()
    return row[0] if row else None


def resolve_agent_role(conn, run_id: str) -> str:
    """Derive the pg role for the agent that owns this run. Fails hard if unresolvable."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT a.name
            FROM ai.run r
            JOIN ai.session s ON r.session_id = s.id
            JOIN ai.agent a ON s.agent_id = a.id
            WHERE r.id = %s
        """, (run_id,))
        row = cur.fetchone()
    if not row:
        raise RuntimeError(f"run {run_id}: cannot resolve agent — run or session missing")
    agent_name = row[0]
    if not re.fullmatch(r'[a-zA-Z0-9_]+', agent_name):
        raise RuntimeError(f"run {run_id}: agent name {agent_name!r} contains invalid characters")
    return f"ai_agent_{agent_name}"


def process(conn, run_id: str) -> None:
    log.info("processing run %s", run_id)

    pg_role = resolve_agent_role(conn, run_id)
    log.info("run %s → agent role %s", run_id, pg_role)

    with conn.cursor() as cur:
        cur.execute("SELECT intent FROM ai.run WHERE id = %s", (run_id,))
        row = cur.fetchone()
    if not row:
        log.error("run %s not found", run_id)
        return
    intent = row[0]

    client = anthropic.Anthropic()
    try:
        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            messages=[{"role": "user", "content": intent}],
        )
        content = response.content[0].text
        status = "completed"
        error = None
    except Exception as exc:
        log.exception("model call failed for run %s", run_id)
        content = str(exc)
        status = "failed"
        error = content

    with conn.cursor() as cur:
        # SET ROLE so any writes (including future bundle.commit calls) carry
        # verifiable attribution via ai.active_run binding_key = current_user
        cur.execute(f"SET ROLE {pg_role}")
        cur.execute(
            "INSERT INTO ai.message (run_id, role, content) VALUES (%s, 'agent', %s)",
            (run_id, content),
        )
        cur.execute(
            "UPDATE ai.run SET status = %s, completed_at = %s, error = %s WHERE id = %s",
            (status, datetime.now(timezone.utc), error, run_id),
        )
    conn.commit()
    # SET ROLE persists for the session; reset so subsequent claims run as superuser
    with conn.cursor() as cur:
        cur.execute("RESET ROLE")
    conn.commit()
    log.info("run %s → %s", run_id, status)


def drain(conn) -> None:
    """Process all queued runs on startup."""
    count = 0
    while True:
        run_id = claim(conn)
        if run_id is None:
            break
        process(conn, run_id)
        count += 1
    if count:
        log.info("drained %d queued run(s)", count)


def main() -> None:
    # Separate connections: LISTEN requires autocommit; work conn uses explicit txns.
    listen_conn = psycopg2.connect(DSN)
    listen_conn.set_isolation_level(0)  # autocommit
    with listen_conn.cursor() as cur:
        cur.execute(f"LISTEN {CHANNEL}")
    log.info("listening on %s", CHANNEL)

    work_conn = psycopg2.connect(DSN)

    drain(work_conn)

    while True:
        # Block up to HEARTBEAT_SECS; wake on NOTIFY or timeout
        ready = select.select([listen_conn], [], [], HEARTBEAT_SECS)[0]
        if ready:
            listen_conn.poll()
            listen_conn.notifies.clear()  # drain the notification queue; we claim from table

        # Always claim from the table — NOTIFY is a wakeup hint, not the authoritative source
        run_id = claim(work_conn)
        if run_id:
            process(work_conn, run_id)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log.info("shutting down")
        sys.exit(0)
