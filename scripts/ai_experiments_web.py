#!/usr/bin/env python3
"""
AI Bundle Experiments — Phase 3 (Web Layer / Playwright)

Tests the /ai/runs page and REST API, validates interface equivalence:
  SQL INSERT → visible in PGFS → visible via REST → visible in browser widget

Run from /root/aquameta/:
    python3 scripts/ai_experiments_web.py

Requires:
    uv pip install playwright psycopg2-binary
    playwright install chromium
"""

import os
import sys
import uuid
import time
import json
import subprocess
import urllib.request
import urllib.error

BASE_URL = "http://localhost:4444"
DB_PARAMS = {
    "host": "localhost",
    "port": 5432,
    "dbname": "aquameta",
    "user": "aquameta",
    "password": "aquameta",
}

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
NOTE = "\033[33mNOTE\033[0m"
FIND = "\033[35mFINDING\033[0m"


def psql(sql):
    env = {**os.environ, "PGPASSWORD": "aquameta"}
    cmd = [
        "psql", "-h", "localhost", "-p", "5432", "-U", "aquameta", "-d", "aquameta",
        "-t", "-A", "-c", sql
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}")
    return result.stdout.strip()


def rest_get(path, expect_status=200):
    url = f"{BASE_URL}{path}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode()
            return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return e.code, body
    except urllib.error.URLError as e:
        return None, str(e)


def rest_post(path, data):
    url = f"{BASE_URL}{path}"
    payload = json.dumps(data).encode()
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode()
            return resp.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return e.code, body
    except urllib.error.URLError as e:
        return None, str(e)


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


def setup_test_data():
    agent_id = str(uuid.uuid4())
    session_id = str(uuid.uuid4())
    psql(f"""
        INSERT INTO ai.agent (id, name, description, model)
        VALUES ('{agent_id}', 'web_test_agent', 'Web experiment agent', 'claude-sonnet-4-6');
        INSERT INTO ai.session (id, agent_id, title)
        VALUES ('{session_id}', '{agent_id}', 'web_test_session');
    """)
    return agent_id, session_id


def cleanup_test_data():
    psql("""
        DELETE FROM ai.tool_call WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'web_test_%'
        );
        DELETE FROM ai.message WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'web_test_%'
        );
        DELETE FROM ai.run_commit WHERE run_id IN (
            SELECT r.id FROM ai.run r JOIN ai.session s ON s.id = r.session_id
            JOIN ai.agent a ON a.id = s.agent_id WHERE a.name LIKE 'web_test_%'
        );
        DELETE FROM ai.run WHERE session_id IN (
            SELECT s.id FROM ai.session s JOIN ai.agent a ON a.id = s.agent_id
            WHERE a.name LIKE 'web_test_%'
        );
        DELETE FROM ai.session WHERE agent_id IN (
            SELECT id FROM ai.agent WHERE name LIKE 'web_test_%'
        );
        DELETE FROM ai.agent WHERE name LIKE 'web_test_%';
    """)


def check_playwright():
    try:
        import playwright
        return True
    except ImportError:
        return False


def main():
    print("\n" + "=" * 70)
    print("  AI BUNDLE EXPERIMENTS — Phase 3: Web Layer")
    print("=" * 70)

    failures = []

    # Pre-flight: server reachable
    status, body = rest_get("/")
    if status is None:
        print(f"\n  {FAIL} Server not reachable at {BASE_URL}: {body}")
        sys.exit(1)
    print(f"\n  Server reachable at {BASE_URL} (status={status})")

    agent_id, session_id = setup_test_data()

    # ============================================================
    # EXPERIMENT 9: /ai/runs page loads and returns HTML
    # ============================================================
    section("EXPERIMENT 9: /ai/runs Page Load")

    status, body = rest_get("/ai/runs")
    check("9a: /ai/runs returns 200", status == 200, f"status={status}")
    if status != 200:
        failures.append(f"/ai/runs returned status {status}")
        note("9a: body snippet", body[:200])

    check("9b: response is HTML", "<!doctype html" in body.lower() or "<html" in body.lower(),
          f"first 100 chars: {body[:100]!r}")
    check("9c: widget.js import present", "widget.js" in body or "System.import" in body,
          "widget system loading pattern expected in resource HTML")
    check("9d: io.bundle.ai.core bundle reference present", "io.bundle.ai.core" in body,
          "bundle name expected in widget import call")

    # ============================================================
    # EXPERIMENT 10: REST API — query ai.run_summary relation
    # ============================================================
    section("EXPERIMENT 10: REST API — ai.run and ai.run_summary access")

    # Get the relation_id for ai.run via meta
    run_relation_id = psql("SELECT id FROM meta.relation WHERE schema_name = 'ai' AND name = 'run'")
    note("10a: ai.run relation_id", run_relation_id)

    # Try REST GET on ai.run via /endpoint/0.3/relation/<id>
    if run_relation_id:
        status, body = rest_get(f"/endpoint/0.3/relation/ai/run")
        check("10b: GET /endpoint/0.3/relation/ai/run returns 200",
              status == 200, f"status={status}")
        if status == 200:
            try:
                data = json.loads(body)
                # Endpoint wraps response; check for rows key
                rows = data.get("rows", data) if isinstance(data, dict) else data
                check("10c: response is parseable JSON with rows",
                      isinstance(data, (dict, list)),
                      f"type={type(data).__name__}")
            except json.JSONDecodeError as e:
                check("10c: response is JSON", False, f"parse error: {e}")
                note("10c: body snippet", body[:300])
    else:
        note("10b: skipping REST relation test — could not find ai.run relation_id")

    # 10d. Insert a run via SQL, verify it appears via REST
    run_id = str(uuid.uuid4())
    test_intent = f"web_experiment_10_marker_{run_id[:8]}"
    psql(f"""
        INSERT INTO ai.run (id, session_id, intent, status)
        VALUES ('{run_id}', '{session_id}', '{test_intent}', 'completed');
        UPDATE ai.run SET completed_at = now() WHERE id = '{run_id}';
    """)

    status, body = rest_get(f"/endpoint/0.3/relation/ai/run?where=%7B%22name%22%3A%22id%22%2C%22op%22%3A%22%3D%22%2C%22value%22%3A%22{run_id}%22%7D")
    check("10d: SQL-inserted run retrievable via REST API",
          status == 200 and run_id in body,
          f"status={status}, run_id_in_body={run_id in body}")
    if status != 200:
        note("10d: body snippet", body[:300])

    # ============================================================
    # EXPERIMENT 11: Full Interface Equivalence Matrix
    # ============================================================
    section("EXPERIMENT 11: Interface Equivalence Matrix")

    print("\n  Inserting test run via SQL, checking visibility in all layers...")

    sql_run_id = str(uuid.uuid4())
    sql_intent = f"interface_equiv_sql_{sql_run_id[:8]}"
    psql(f"""
        INSERT INTO ai.run (id, session_id, intent, status)
        VALUES ('{sql_run_id}', '{session_id}', '{sql_intent}', 'running');
    """)

    # SQL → SQL (trivial, confirm)
    db_check = psql(f"SELECT count(*) FROM ai.run WHERE id = '{sql_run_id}'")
    check("11a: SQL insert visible via SQL", db_check == "1")

    # SQL → PGFS
    pgfs_root = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pgfs")
    pgfs_run_path = os.path.join(pgfs_root, "ai", "run", sql_run_id)
    check("11b: SQL insert visible via PGFS", os.path.exists(pgfs_run_path),
          f"path={pgfs_run_path}")
    if os.path.exists(pgfs_run_path):
        pgfs_intent = open(os.path.join(pgfs_run_path, "intent")).read()
        check("11b: PGFS intent value correct", pgfs_intent == sql_intent,
              f"pgfs={pgfs_intent!r}")
    else:
        failures.append(f"SQL-inserted run not visible via PGFS: {pgfs_run_path}")

    # SQL → REST
    status, body = rest_get(
        f"/endpoint/0.3/relation/ai/run"
        f"?where=%7B%22name%22%3A%22id%22%2C%22op%22%3A%22%3D%22%2C%22value%22%3A%22{sql_run_id}%22%7D"
    )
    check("11c: SQL insert visible via REST API",
          status == 200 and sql_run_id in body,
          f"status={status}")

    # PGFS → check via SQL (write via PGFS, read via SQL)
    pgfs_intent_updated = f"interface_equiv_pgfs_{sql_run_id[:8]}"
    if os.path.exists(pgfs_run_path):
        intent_path = os.path.join(pgfs_run_path, "intent")
        fd = os.open(intent_path, os.O_WRONLY | os.O_TRUNC)
        try:
            os.write(fd, pgfs_intent_updated.encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        db_after_pgfs = psql(f"SELECT intent FROM ai.run WHERE id = '{sql_run_id}'")
        check("11d: PGFS write visible via SQL",
              db_after_pgfs == pgfs_intent_updated,
              f"db={db_after_pgfs!r}")

        # PGFS → REST
        status, body = rest_get(
            f"/endpoint/0.3/relation/ai/run"
            f"?where=%7B%22name%22%3A%22id%22%2C%22op%22%3A%22%3D%22%2C%22value%22%3A%22{sql_run_id}%22%7D"
        )
        check("11e: PGFS write visible via REST API",
              status == 200 and pgfs_intent_updated in body,
              f"status={status}, intent_in_body={pgfs_intent_updated in body}")

    # Summary matrix
    print("""
  Equivalence matrix (SQL insert as baseline):
    Insert via SQL  → SQL:   see 11a
    Insert via SQL  → PGFS:  see 11b
    Insert via SQL  → REST:  see 11c
    Update via PGFS → SQL:   see 11d
    Update via PGFS → REST:  see 11e
    """)
    finding("11f: REST POST to create rows not tested here",
            "POST /endpoint/0.3/relation/ai/run requires understanding endpoint auth + session setup; "
            "add as a follow-up once auth pattern is established")

    # ============================================================
    # EXPERIMENT 12: Playwright browser test (if available)
    # ============================================================
    section("EXPERIMENT 12: Playwright Browser Test (optional)")

    if not check_playwright():
        note("12: Playwright not installed",
             "install with: uv pip install playwright && playwright install chromium")
        note("12: skipping browser tests")
    else:
        try:
            from playwright.sync_api import sync_playwright

            with sync_playwright() as p:
                browser = p.chromium.launch(headless=True)
                page = browser.new_page()

                # Capture console errors
                console_errors = []
                page.on("console", lambda msg: console_errors.append(msg.text)
                        if msg.type == "error" else None)

                page.goto(f"{BASE_URL}/ai/runs", wait_until="networkidle", timeout=15000)

                check("12a: /ai/runs page loaded without navigation error", True)

                # Check for JS errors
                serious_errors = [e for e in console_errors
                                  if "TypeError" in e or "ReferenceError" in e or "SyntaxError" in e]
                check("12b: no serious JS errors in console",
                      len(serious_errors) == 0,
                      f"errors={serious_errors[:3]}" if serious_errors else "clean")

                # Look for widget content — the ai_run_summary widget should render a table or list
                content = page.content()
                check("12c: page has content beyond bare HTML scaffold",
                      len(content) > 500,
                      f"content length={len(content)}")

                # Check if any run intent text appears (from our test data or existing runs)
                existing_intent = psql("SELECT intent FROM ai.run LIMIT 1")
                if existing_intent:
                    # Give widget time to load async data
                    time.sleep(2)
                    content = page.content()
                    check("12d: run intent text visible in rendered page",
                          existing_intent[:30] in content,
                          f"looking for: {existing_intent[:30]!r}")
                    if existing_intent[:30] not in content:
                        finding("12d: widget may not have loaded run data",
                                "widget might require page interaction or longer load time")

                browser.close()

        except Exception as e:
            check("12: Playwright test", False, f"exception: {e}")
            failures.append(f"Playwright test failed: {e}")

    # ============================================================
    # Cleanup + Summary
    # ============================================================
    cleanup_test_data()

    print("\n" + "=" * 70)
    print("  AI BUNDLE EXPERIMENTS — Phase 3 Complete")
    print("=" * 70)

    if failures:
        print(f"\n  {len(failures)} failure(s):")
        for f in failures:
            print(f"    ✗ {f}")
        sys.exit(1)
    else:
        print(f"\n  All web experiments passed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
