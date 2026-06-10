# Migration: Deploy Custom Layer to a Fresh Aquameta Install

This covers deploying the ai/companion/navigation/advisor layer (extensions + bundles)
onto an Aquameta instance where core extensions are already installed.

---

## Prerequisites

- Target has had `main.go` run at least once (8 core extensions + bundle schema present).
- Source machine bundle JSON files (22 bundles) copied to target.
- Source machine `extensions/` and `scripts/` directories accessible on target.

**Important — pg_bundle version check:**  
`main.go` only loads pg_bundle SQL files when the `bundle` schema doesn't yet exist
(line 222: `if !bundleInstalled`). Any target that already has an Aquameta install
keeps whatever pg_bundle function definitions it was born with. If the target's
`bundle._checkout_row` or `bundle.import_repository` predate the `jsonb_populate_record`
rewrite, issues 2-8 from `bundle-load-issues.md` will recur.

Verify before proceeding:

```sql
-- Should see jsonb_populate_record in the body:
SELECT pg_get_functiondef('bundle._checkout_row'::regproc);
SELECT pg_get_functiondef('bundle.import_repository'::regproc);
```

If the target has old definitions, reload pg_bundle functions by running the SQL
files directly in order. Note: `checkout.sql` starts with `CREATE TABLE` (not
`IF NOT EXISTS`), so run only the function-defining files if the schema exists,
or reload via a targeted psql pipe of just the function files.

---

## Step 1 — Apply post-install patches

These patches must run before loading custom extensions or importing bundles.

```bash
# Fix meta_triggers: stmt_view_create / stmt_function_create use plain CREATE.
# Bundle checkout fires the meta trigger, which fails if the view/function already exists.
psql -f scripts/meta-triggers-or-replace-patch.sql

# Fix pg_bundle: v0.4 row_id format compatibility.
psql -f scripts/bundle-backward-compat-patch.sql
```

**Why before extensions?** The ai/companion extension SQL creates views and functions.
If you load those first, then import bundles, the meta trigger fires `CREATE VIEW foo`
on rows that already exist — failing. `CREATE OR REPLACE` prevents this.

---

## Step 2 — Load custom extensions (schema infrastructure)

Load in this order (dependency sequence: ai → companion → navigation → advisor).

```bash
psql -f extensions/ai/000-ai.sql
psql -f extensions/ai/001-ideas.sql
psql -f extensions/companion/000-companion.sql
psql -f extensions/companion/001-plan.sql
psql -f extensions/companion/002-review.sql
psql -f extensions/companion/003-assessment.sql
psql -f extensions/navigation/000-navigation.sql
```

For the advisor schema (if using it):

```bash
psql -f scripts/create_ai_run_binding.sql   # ai.run_binding + session/run tracking
# GRANT statements for ai_agent_* roles may fail if those roles don't exist yet —
# this is expected at this stage; tables and functions will still be created.
```

**Idempotency note:** If Step 2 scripts insert any rows that are also tracked in the
bundles (e.g., capability registrations, agent rows), plain `bundle.checkout` in Step 4
will hit duplicate-key errors on those rows. Either ensure the extension scripts do not
seed bundle-tracked rows, or pass `upsert := true` to `bundle.checkout` for affected
bundles: `SELECT bundle.checkout('io.bundle.ai.core', true)`.

---

## Step 3 — Import bundle JSON files

Run for each bundle JSON file (adjust for your file list):

```sql
-- Repeat for each bundle:
SELECT bundle.import_repository(pg_read_file('/path/to/bundle.json'));
```

Or via shell loop:

```bash
for f in *.json; do
  psql -c "SELECT bundle.import_repository(pg_read_file('$(pwd)/$f'));"
done
```

---

## Step 4 — Checkout bundles

The ai.core, aquameta.plan, and companion bundles form a circular FK cycle:
- `companion.plan_step` rows in `io.bundle.ai.core` reference `companion.plan` rows
  that live in `io.bundle.aquameta.plan`
- `companion.plan_step` rows in `io.bundle.aquameta.plan` reference `ai.experiment`
  rows that live in `io.bundle.ai.core`
- `companion.assessment` rows reference `ai.agent` rows

The FKs in this cycle are defined as `DEFERRABLE INITIALLY IMMEDIATE` in the
companion extension SQL. Use `SET CONSTRAINTS ALL DEFERRED` inside a single transaction
wrapping all three checkouts so FK checks run at commit time rather than per-statement:

```sql
-- Core bundles first (no cross-bundle dependencies)
SELECT bundle.checkout('org.aquameta.core.bootloader');
SELECT bundle.checkout('org.aquameta.core.endpoint');
SELECT bundle.checkout('org.aquameta.core.ide');
SELECT bundle.checkout('org.aquameta.core.mimetypes');
SELECT bundle.checkout('org.aquameta.core.semantics');
SELECT bundle.checkout('org.aquameta.core.widget');

-- App bundles
SELECT bundle.checkout('org.aquameta.games.snake');
SELECT bundle.checkout('org.aquameta.ui.fsm');
SELECT bundle.checkout('org.aquameta.ui.layout');
SELECT bundle.checkout('org.aquameta.ui.tags');

-- Custom layer bundles (no cross-deps with the circular group)
SELECT bundle.checkout('io.bundle.aquameta.navigation');
SELECT bundle.checkout('io.bundle.aquameta.advisor');

-- Circular FK group — must be one transaction with deferred constraints.
-- ORDER IS LOAD-BEARING: io.bundle.ai.core must be first so that ai.agent,
-- ai.experiment, and ai.session rows exist before companion bundles reference them.
-- plan_step.agent_id and plan_review.* FKs are NOT deferrable; they survive only
-- because ai.core is checked out first. Reordering breaks those FKs.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
SELECT bundle.checkout('io.bundle.ai.core');
SELECT bundle.checkout('io.bundle.aquameta.plan');
SELECT bundle.checkout('companion.claude_code.aquameta');
COMMIT;
```

**Do NOT use `SET session_replication_role = replica`** as a workaround — it bypasses
all FK enforcement globally for the session, including unrelated constraints.

**Note:** This deferral approach has not been reversibly validated on a virgin DB.
The prior migration attempt (see `bundle-load-issues.md` #12) applied `DEFERRABLE`
to the constraints but did not use `SET CONSTRAINTS ALL DEFERRED`, so `session_replication_role`
was still needed. If `SET CONSTRAINTS ALL DEFERRED` still fails, suspect either:
(a) a non-deferrable FK firing out of checkout order, or (b) duplicate-key errors
from extension SQL having seeded rows that the bundle also carries (see idempotency
note in Step 2).

---

## Step 5 — Create roles and grant permissions

```sql
CREATE ROLE ai_agent_claude_code LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_claude_haiku LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_mistral_vibe LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_dev LOGIN PASSWORD 'aquameta';
-- ... other roles as needed
```

Re-run the grant statements from `scripts/create_ai_run_binding.sql` if they failed
in step 2 due to missing roles.

---

## Known issues and their status

| Issue | Root cause | Status |
|-------|-----------|--------|
| Issue 1 (wrong patch file path) | Instructions error | Fixed in this document |
| Issues 2-3 (import_repository NULL staging) | Target had older pg_bundle version | Not a source-file problem; see pg_bundle version check above |
| Issues 4-8 (_checkout_row JSON handling) | Same — older pg_bundle on target | Same |
| Issues 9-10 (CREATE VIEW/FUNCTION not OR REPLACE) | meta_triggers submodule, never tested on re-checkout | Fixed: `scripts/meta-triggers-or-replace-patch.sql` |
| Issue 11 (companion.assessment missing) | Added in DB, never written to extension SQL | Fixed: `extensions/companion/003-assessment.sql` |
| Issue 12 (circular FK) | Bundle decomposition spans two bundles | Fixed: DEFERRABLE FKs + SET CONSTRAINTS ALL DEFERRED (not yet reversibly validated) |
| Issue 13 (companion.decision.supersedes_id) | Column existed, was dropped; orphaned in bundle data | No fix — `jsonb_populate_record` silently skips columns not in target type |
| Issue 14 (checkout_commit_id not set) | False diagnosis — symptom of earlier checkout failures | No fix needed; `checkout.sql:161` already sets it |

---

## pg_bundle submodule drift (outstanding risk)

`extensions/pg_bundle/commit.sql` has uncommitted local edits (visible via
`git -C extensions/pg_bundle diff --stat`). These edits make `bundle._commit` handle
the v0.5 JSON format for `meta.row_id` and `meta.field_id`. If `git submodule update`
is run, these changes will be lost and bundle commits on the source machine will break.

These edits affect only the commit path (committing changes to bundles), NOT the
import/checkout path. They are not needed on the migration target.

**Required action**: Extract the dirty `commit.sql` changes to a
`scripts/pg_bundle-commit-patch.sql` file and load it after pg_bundle SQL files,
OR push the changes to `erichanson/pg_bundle` upstream.
