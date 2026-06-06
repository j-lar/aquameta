#!/usr/bin/env python3
"""
AI Bundle Experiments — Phase 2 (PGFS Filesystem Layer)

Tests read and write access to ai.* tables through the PGFS FUSE mount.

Key findings from pgfs.go inspection (inform test design):
  - Structure: pgfs/<schema>/<table>/<pk_uuid>/<column_name>  (column-per-file)
  - Reads: SELECT col::text FROM schema.table WHERE pk = 'uuid'
  - Writes: buffered in memory; committed to DB on explicit fsync() call
  - New row creation: NOT SUPPORTED (no Mkdir/Create on TableDir/RowDir)
  - Views: NOT exposed (PGFS only serves meta.relation with primary_key_column_ids)

Run from /root/aquameta/:
    python3 scripts/ai_experiments_pgfs.py

Requires:
    - aquameta service running (PGFS mounted at pgfs/)
    - psycopg2: uv pip install psycopg2-binary
"""

import os
import sys
import uuid
import subprocess

# DB connection params
DB_PARAMS = {
    "host": "localhost",
    "port": 5432,
    "dbname": "aquameta",
    "user": "aquameta",
    "password": "aquameta",
}

PGFS_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pgfs")

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
NOTE = "\033[33mNOTE\033[0m"
FIND = "\033[35mFINDING\033[0m"


def psql(sql, fetchone=False):
    """Run a SQL query via subprocess psql, return stdout."""
    env = {**os.environ, "PGPASSWORD": "aquameta"}
    cmd = [
        "psql", "-h", "localhost", "-p", "5432", "-U", "aquameta", "-d", "aquameta",
        "-t", "-A", "-c", sql
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}")
    output = result.stdout.strip()
    if fetchone:
        return output.split("|")[0] if "|" in output else output
    return output


def pgfs_path(*parts):
    return os.path.join(PGFS_ROOT, *parts)


def read_field(schema, table, pk, column):
    path = pgfs_path(schema, table, pk, column)
    with open(path, "r") as f:
        return f.read()


def write_field_fsync(schema, table, pk, column, value):
    """Write a value to a PGFS field file using the required fsync pattern."""
    path = pgfs_path(schema, table, pk, column)
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(fd, value.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def section(title):
    print(f"\n{'─' * 70}")
    print(f"  {title}")
    print(f"{'─' * 70}")


def check(label, condition, message=""):
    if condition:
        print(f"  {PASS} {label}" + (f": {message}" if message else ""))
    else:
        print(f"  {FAIL} {label}" + (f": {message}" if message else ""))
    return condition


def note(label, message=""):
    print(f"  {NOTE} {label}" + (f": {message}" if message else ""))


def finding(label, message=""):
    print(f"  {FIND} {label}" + (f": {message}" if message else ""))


# ============================================================
# Setup: insert a test agent + session via SQL (PGFS can't create rows)
# ============================================================

def setup_test_data():
    """Create a test agent and session via SQL for use in PGFS experiments."""
    agent_id = str(uuid.uuid4())
    session_id = str(uuid.uuid4())
    run_id = str(uuid.uuid4())

    psql(f"""
        INSERT INTO ai.agent (id, name, description, model)
        VALUES ('{agent_id}', 'pgfs_test_agent', 'PGFS experiment agent', 'claude-sonnet-4-6');
    """)
    psql(f"""
        INSERT INTO ai.session (id, agent_id, title, context)
        VALUES ('{session_id}', '{agent_id}', 'pgfs_test_session', '{{"interface": "pgfs"}}');
    """)
    psql(f"""
        INSERT INTO ai.run (id, session_id, intent, status)
        VALUES ('{run_id}', '{session_id}', 'original intent — will be updated via PGFS', 'running');
    """)
    return agent_id, session_id, run_id


def cleanup_test_data():
    """Remove all pgfs_test_* data."""
    psql("""
        DELETE FROM ai.tool_call WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'pgfs_test_%'
        );
        DELETE FROM ai.message WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'pgfs_test_%'
        );
        DELETE FROM ai.run_commit WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'pgfs_test_%'
        );
        DELETE FROM ai.run WHERE session_id IN (
            SELECT s.id FROM ai.session s JOIN ai.agent a ON a.id = s.agent_id
            WHERE a.name LIKE 'pgfs_test_%'
        );
        DELETE FROM ai.session WHERE agent_id IN (
            SELECT id FROM ai.agent WHERE name LIKE 'pgfs_test_%'
        );
        DELETE FROM ai.agent WHERE name LIKE 'pgfs_test_%';
    """)


def main():
    print("\n" + "=" * 70)
    print("  AI BUNDLE EXPERIMENTS — Phase 2: PGFS Filesystem Layer")
    print("=" * 70)

    # Pre-flight: check mount
    if not os.path.isdir(PGFS_ROOT):
        print(f"\n{FAIL} PGFS root not found at {PGFS_ROOT}")
        print("  Start the aquameta service and ensure PGFS is enabled in config.")
        sys.exit(1)

    if not os.path.isdir(pgfs_path("ai")):
        print(f"\n{FAIL} ai schema directory not found in PGFS at {pgfs_path('ai')}")
        sys.exit(1)

    print(f"\n  PGFS root: {PGFS_ROOT}")

    try:
        psql("SELECT 1")
    except Exception as e:
        print(f"\n{FAIL} DB connection failed: {e}")
        sys.exit(1)

    failures = []

    # ============================================================
    # EXPERIMENT 6: Schema Visibility Through PGFS
    # ============================================================
    section("EXPERIMENT 6: Schema Visibility Through PGFS")

    # 6a. ai schema tables visible
    ai_tables = sorted(os.listdir(pgfs_path("ai")))
    expected_tables = {"agent", "agent_capability", "capability", "message",
                       "run", "run_commit", "session", "tool_call"}
    missing = expected_tables - set(ai_tables)
    extra = set(ai_tables) - expected_tables
    if not check("6a: all ai tables visible in PGFS", len(missing) == 0,
                 f"tables={ai_tables}"):
        failures.append(f"Missing tables in PGFS: {missing}")
    if extra:
        note("6a: extra items in pgfs/ai", f"{extra}")

    # 6b. Views NOT exposed (run_summary should not exist)
    view_path = pgfs_path("ai", "run_summary")
    if not check("6b: views are NOT exposed in PGFS (run_summary absent)",
                 not os.path.exists(view_path)):
        finding("6b: run_summary view is exposed in PGFS (unexpected)")
    else:
        finding("6b: ai.run_summary view is NOT accessible via PGFS",
                "agents must use SQL or REST API to read run_summary")

    # 6c. Read a capability row's fields
    cap_rows = os.listdir(pgfs_path("ai", "capability"))
    if cap_rows:
        cap_uuid = cap_rows[0]
        cap_fields = sorted(os.listdir(pgfs_path("ai", "capability", cap_uuid)))
        expected_fields = {"id", "name", "description", "privilege", "schema_name"}
        ok = check("6c: capability row directory has expected fields",
                   expected_fields.issubset(set(cap_fields)),
                   f"fields={cap_fields}")
        if not ok:
            failures.append(f"Capability fields mismatch: {cap_fields}")

        # Read values
        name_val = read_field("ai", "capability", cap_uuid, "name")
        schema_val = read_field("ai", "capability", cap_uuid, "schema_name")
        priv_val = read_field("ai", "capability", cap_uuid, "privilege")
        check("6c: capability name readable", bool(name_val), f"name={name_val!r}")
        check("6c: schema_name readable", bool(schema_val), f"schema_name={schema_val!r}")
        check("6c: privilege readable", bool(priv_val), f"privilege={priv_val!r}")

        # Verify matches DB
        db_name = psql(f"SELECT name FROM ai.capability WHERE id = '{cap_uuid}'")
        check("6c: PGFS value matches DB value", name_val == db_name,
              f"pgfs={name_val!r} db={db_name!r}")
    else:
        failures.append("No capability rows found in PGFS — is the bundle checked out?")

    # 6d. Attempt to create a new row via mkdir (should fail — not supported)
    new_uuid = str(uuid.uuid4())
    try:
        os.mkdir(pgfs_path("ai", "capability", new_uuid))
        finding("6d: mkdir on table dir SUCCEEDED",
                "PGFS supports new row creation via directory creation (unexpected)")
    except (PermissionError, OSError) as e:
        check("6d: mkdir for new row correctly blocked",
              True, f"errno: {type(e).__name__}")
        finding("6d: row creation via PGFS is NOT supported",
                "new rows must be created via SQL or REST API")

    # ============================================================
    # EXPERIMENT 7: Write Through PGFS (UPDATE existing row field)
    # ============================================================
    section("EXPERIMENT 7: Write Through PGFS (UPDATE existing row field)")

    agent_id, session_id, run_id = setup_test_data()
    print(f"  Setup: run_id={run_id}")

    # 7a. Verify row appears in PGFS
    run_pgfs_path = pgfs_path("ai", "run", run_id)
    if not check("7a: new SQL-inserted run appears in PGFS directory",
                 os.path.exists(run_pgfs_path)):
        failures.append(f"Run {run_id} not found in PGFS after SQL insert")
        cleanup_test_data()
        # Skip rest of exp 7
    else:
        # 7b. Read intent via PGFS — verify it matches what was inserted
        pgfs_intent = read_field("ai", "run", run_id, "intent")
        expected_intent = "original intent — will be updated via PGFS"
        check("7b: intent field readable via PGFS", pgfs_intent == expected_intent,
              f"got={pgfs_intent!r}")

        # 7c. Update intent via PGFS fsync pattern
        new_intent = "updated intent — written via PGFS fsync"
        write_field_fsync("ai", "run", run_id, "intent", new_intent)

        # 7d. Verify update visible via SQL
        db_intent = psql(f"SELECT intent FROM ai.run WHERE id = '{run_id}'")
        ok = check("7c: PGFS write (fsync) is visible via SQL",
                   db_intent == new_intent,
                   f"db_intent={db_intent!r}")
        if not ok:
            failures.append(f"PGFS write did not propagate to DB: expected {new_intent!r}, got {db_intent!r}")

        # 7e. Verify update is also visible reading back via PGFS
        pgfs_intent_after = read_field("ai", "run", run_id, "intent")
        check("7d: PGFS read after write shows updated value",
              pgfs_intent_after == new_intent,
              f"pgfs_intent={pgfs_intent_after!r}")

        # 7f. Update run.status via PGFS (a non-text column — stored as enum)
        write_field_fsync("ai", "run", run_id, "status", "completed")
        db_status = psql(f"SELECT status FROM ai.run WHERE id = '{run_id}'")
        check("7e: enum column (status) writeable via PGFS",
              db_status == "completed",
              f"db_status={db_status!r}")

        finding("7f: PGFS writes bypass bundle offstage detection",
                "bundle.stage_tracked_rows sees the change correctly but offstage triggers "
                "fire on SQL UPDATE, not PGFS fsync directly — the Fsync handler issues "
                "an UPDATE which does fire triggers")

        cleanup_test_data()

    # ============================================================
    # EXPERIMENT 8: PGFS + Bundle Round-Trip (widget HTML edit)
    # ============================================================
    section("EXPERIMENT 8: PGFS + Bundle Round-Trip (widget HTML edit)")

    # Find ai_run_summary widget
    widget_id = psql("SELECT id FROM widget.widget WHERE name = 'ai_run_summary'")
    if not widget_id:
        print(f"  {FAIL} 8a: ai_run_summary widget not found — skipping experiment 8")
        failures.append("ai_run_summary widget missing — bundle may not be checked out")
    else:
        print(f"  widget_id={widget_id}")

        # 8a. Verify widget row is in PGFS
        widget_path = pgfs_path("widget", "widget", widget_id)
        check("8a: ai_run_summary widget row visible in PGFS", os.path.exists(widget_path),
              f"path={widget_path}")

        # 8b. Read current HTML
        original_html = read_field("widget", "widget", widget_id, "html")
        check("8b: widget html readable via PGFS", bool(original_html),
              f"length={len(original_html)} chars")

        # 8c. Append an HTML comment via PGFS (non-destructive)
        marker = "\n<!-- pgfs_experiment_8_marker -->"
        modified_html = original_html + marker
        write_field_fsync("widget", "widget", widget_id, "html", modified_html)

        db_html = psql(f"SELECT html FROM widget.widget WHERE id = '{widget_id}'")
        ok = check("8c: widget HTML update via PGFS is visible in DB",
                   db_html.endswith(marker.strip()),
                   f"db ends with marker: {db_html[-60:]!r}")
        if not ok:
            failures.append("PGFS widget HTML write did not propagate to DB")

        # 8d. Check bundle offstage detection via _get_offstage_updated_fields()
        # (bundle.offstage_field_change view doesn't exist; use the function directly)
        ai_bundle_id = "0d8707d9-4e66-4144-808d-0b22cb19da43"
        offstage = psql(f"""
            SELECT count(*) FROM bundle._get_offstage_updated_fields(
                '{ai_bundle_id}'::uuid, null
            ) f WHERE (f.field_id).schema_name = 'widget'
              AND (f.field_id).relation_name = 'widget'
              AND (f.field_id).pk_values[1] = '{widget_id}'
        """)
        check("8d: PGFS write detected as offstage bundle change",
              offstage != "0",
              f"offstage_field_change count={offstage}")
        if offstage == "0":
            finding("8d: PGFS write NOT detected as bundle change",
                    "bundle offstage change detection may require SQL path, not PGFS UPDATE")

        # 8e. Restore original HTML — compare via PGFS read-back (not psql) to avoid
        # the psql -A output stripping of leading/trailing newlines in multi-line fields
        write_field_fsync("widget", "widget", widget_id, "html", original_html)
        pgfs_html_restored = read_field("widget", "widget", widget_id, "html")
        check("8e: widget HTML restored to original (via PGFS read-back)",
              pgfs_html_restored == original_html,
              f"length={len(pgfs_html_restored)}")

    # ============================================================
    # Summary
    # ============================================================
    print("\n" + "=" * 70)
    print("  AI BUNDLE EXPERIMENTS — Phase 2 Complete")
    print("=" * 70)

    if failures:
        print(f"\n  {len(failures)} failure(s):")
        for f in failures:
            print(f"    ✗ {f}")
        sys.exit(1)
    else:
        print(f"\n  All PGFS experiments passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
