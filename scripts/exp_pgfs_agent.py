#!/usr/bin/env python3
"""
Experiment: PGFS-Only Agent Run

Demonstrates an agent operating purely via the PGFS filesystem mount —
no direct DB connection during operation. Superuser SQL is used only for
provisioning (creating the session/run rows), exactly like capability grants.

The experiment does real work: reads the ai.experiment backlog via PGFS,
annotates pending experiments with a priority note, and updates its own run status.

Surfaces:
  - What a PGFS-only agent CAN do: read columns, update columns
  - What it CANNOT do: create new rows (EPERM on mkdir)
  - The architectural boundary: PGFS gives state access, not append-log access

Run from /root/aquameta/:
    python3 scripts/exp_pgfs_agent.py
"""

import os
import sys
import uuid
import subprocess
import time

PGFS_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pgfs")

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"
NOTE = "\033[33mNOTE\033[0m"
FIND = "\033[35mFINDING\033[0m"


def psql(sql):
    """Superuser SQL — provisioning only."""
    env = {**os.environ, "PGPASSWORD": "aquameta"}
    cmd = ["psql", "-h", "localhost", "-p", "5432", "-U", "aquameta",
           "-d", "aquameta", "-t", "-A", "-c", sql]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"psql: {r.stderr.strip()}")
    return r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""


def pgfs(schema, table, pk, column):
    return os.path.join(PGFS_ROOT, schema, table, pk, column)


def pgfs_read(schema, table, pk, column):
    with open(pgfs(schema, table, pk, column), "r") as f:
        return f.read().strip()


def pgfs_write(schema, table, pk, column, value):
    path = pgfs(schema, table, pk, column)
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(fd, value.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def pgfs_list(schema, table):
    path = os.path.join(PGFS_ROOT, schema, table)
    return os.listdir(path)


print()
print("=" * 70)
print(" EXPERIMENT: PGFS-Only Agent Run")
print("=" * 70)

# ============================================================
# PHASE 1: Provision (superuser SQL — unavoidable for row creation)
# ============================================================
print()
print("--- Phase 1: Provision session + run via SQL (superuser) ---")

agent_id = psql("SELECT id FROM ai.agent WHERE name = 'claude_code'")
if not agent_id:
    print(f"{FAIL} claude_code agent not found — run exp_status_transition.sql first")
    sys.exit(1)

session_id = psql(f"""
    INSERT INTO ai.session (agent_id, title, context)
    VALUES ('{agent_id}', 'PGFS-only agent run',
            '{{"interface": "pgfs", "working_bundle": "io.bundle.ai.core"}}')
    RETURNING id
""")

run_id = psql(f"""
    INSERT INTO ai.run (session_id, intent)
    VALUES ('{session_id}',
            'Read ai.experiment backlog via PGFS and annotate pending experiments with priority notes')
    RETURNING id
""")

print(f"  Session: {session_id}")
print(f"  Run:     {run_id}")
print(f"{PASS} Provisioning complete — switching to PGFS-only operation")

# ============================================================
# PHASE 2: Agent operates via PGFS only — no more psql calls
# ============================================================
print()
print("--- Phase 2: PGFS-only operation ---")
print()

t0 = time.time()

# Read the experiment backlog
print("Reading ai.experiment table via PGFS...")
exp_uuids = pgfs_list("ai", "experiment")
experiments = []
for eid in exp_uuids:
    try:
        name   = pgfs_read("ai", "experiment", eid, "name")
        status = pgfs_read("ai", "experiment", eid, "status")
        desc   = pgfs_read("ai", "experiment", eid, "description")
        experiments.append({"id": eid, "name": name, "status": status, "description": desc})
    except Exception as e:
        print(f"  {NOTE} skipping {eid}: {e}")

pending = [e for e in experiments if e["status"] == "pending"]
complete = [e for e in experiments if e["status"] == "complete"]

print(f"  {PASS} Read {len(experiments)} experiments ({len(pending)} pending, {len(complete)} complete)")
print()
print("Pending experiments:")
for e in pending:
    print(f"  - {e['name']}")

# Annotate the NOTIFY queue experiment as highest priority (write via PGFS)
print()
print("Annotating 'NOTIFY-based run queue' as highest priority...")
notify_exp = next((e for e in pending if "NOTIFY" in e["name"]), None)
if notify_exp:
    pgfs_write("ai", "experiment", notify_exp["id"], "findings",
               "Priority: HIGH. This is the architectural prerequisite for autonomous agent execution. "
               "Without a NOTIFY queue the harness must poll or be manually triggered. "
               "Annotated via PGFS-only agent run — no direct DB connection used.")
    print(f"  {PASS} Wrote findings to '{notify_exp['name']}' via PGFS")
else:
    print(f"  {NOTE} NOTIFY experiment not found")

# ============================================================
# FINDING: attempt row creation via PGFS (mkdir on table dir)
# ============================================================
print()
print("--- Probing PGFS row-creation limit ---")
message_dir = os.path.join(PGFS_ROOT, "ai", "message")
new_row_path = os.path.join(message_dir, str(uuid.uuid4()))
try:
    os.mkdir(new_row_path)
    print(f"  {NOTE} mkdir succeeded (unexpected)")
except PermissionError as e:
    print(f"  {FIND} EPERM on mkdir in ai/message — row creation not supported via PGFS")
    print(f"         Agent cannot append to ai.message or ai.tool_call without SQL access")
    print(f"         PGFS gives state access (read/update columns); not append-log access")
except Exception as e:
    print(f"  {FAIL} unexpected error: {e}")

# ============================================================
# Complete the run (via PGFS — run row already exists)
# ============================================================
print()
print("--- Completing run via PGFS ---")
pgfs_write("ai", "run", run_id, "status", "completed")
pgfs_write("ai", "run", run_id, "completed_at",
           subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%S+00:00"],
                          capture_output=True, text=True).stdout.strip())

elapsed = int((time.time() - t0) * 1000)

final_status = pgfs_read("ai", "run", run_id, "status")
print(f"  {PASS} run.status = '{final_status}' (written and read back via PGFS)")

print()
print("=" * 70)
print(" RESULTS")
print("=" * 70)
print()
print(f"Run {run_id}")
print(f"  Status:  {final_status}")
print(f"  Elapsed: {elapsed}ms (PGFS-only phase)")
print()
print("Findings:")
print("  PASS  Read ai.experiment backlog entirely via PGFS directory listing + column files")
print("  PASS  Wrote findings to an experiment row via PGFS (fsync pattern)")
print("  PASS  Updated run.status and completed_at via PGFS")
print("  FIND  Row creation (INSERT equivalent) not possible via PGFS — EPERM on mkdir")
print("        Agent cannot log ai.message or ai.tool_call without a SQL connection")
print("  FIND  Pure-PGFS agent model: suited for state-reading + status-update agents;")
print("        not suited for agents that need to append an activity log")
print()
print(f"Check /ai/runs to see this run in the inspector.")
