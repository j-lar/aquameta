# Migration: Deploy Custom Layer to a Fresh Aquameta Install

This covers deploying the ai/companion/navigation/advisor layer onto a fresh
clone of the dev fork. All steps assume you are working from the repo root.

---

## What you need

A fresh clone of the dev fork is self-contained. Everything required is in git:

| Path | What it is |
|------|-----------|
| `extensions/meta/` | meta extension (absorbed from submodule; includes jsonb identifier overloads) |
| `extensions/meta_triggers/` | meta_triggers extension (absorbed from submodule) |
| `extensions/pg_bundle/` | pg_bundle (still a submodule — see note below) |
| `extensions/ai/`, `companion/`, `navigation/`, `advisor/` | Custom schema extensions |
| `bundles/*.json` | All bundle JSON files (core + custom layer) |

**Not in git — must be created on the target:**

- `conf/bootloader.toml` — copy from `conf/boot.toml.dist` and fill in DB credentials
- PostgreSQL must be installed and accessible (or use embedded mode)

**pg_bundle submodule:** After cloning, initialize it:

```bash
git submodule update --init extensions/pg_bundle
```

`extensions/pg_bundle/commit.sql` has local edits (not yet pushed upstream) that
make bundle commits work with the v0.5 JSON row_id format. After `submodule update --init`
those edits will be present at the pinned commit (`cda47c6`). If you ever run
`git submodule update` again (to pull upstream changes), re-apply the patch:

```bash
psql -f scripts/pg_bundle-commit-patch.sql   # TODO: extract this from commit.sql diff
```

This only affects the commit path. Import and checkout work without it.

---

## Install sequence

### Step 1 — First run (core extensions + core bundles)

```bash
cp conf/boot.toml.dist conf/bootloader.toml
# edit conf/bootloader.toml — set database host/port/role/password
./aquameta
```

`main.go` installs the 8 core PostgreSQL extensions (including meta and meta_triggers
from `extensions/`), loads pg_bundle SQL, then imports and checks out the core bundles:
`org.aquameta.core.*`, `org.aquameta.games.*`, `org.aquameta.ui.*`.

**No manual patches are needed.** The meta extension now ships
`meta.make_field_id(jsonb, text)` and `meta.row_id_to_relation_id(jsonb)` directly.
The `io.bundle.ai.core` bundle no longer carries `meta.function`/`meta.view` rows.
The three scripts in `scripts/*-patch.sql` are obsolete for fresh installs from this fork.

Once the HTTP server starts, the install is complete. Stop it (`Ctrl-C`) before
proceeding to Step 2.

### Step 2 — Load custom extensions

Load in dependency order (ai → companion → navigation → advisor):

```bash
psql -f extensions/ai/000-ai.sql
psql -f extensions/ai/001-ideas.sql
psql -f extensions/companion/000-companion.sql
psql -f extensions/companion/001-plan.sql
psql -f extensions/companion/002-review.sql
psql -f extensions/companion/003-assessment.sql
psql -f extensions/navigation/000-navigation.sql
psql -f extensions/advisor/000-advisor.sql
```

Then create the ai_agent roles and wire up run tracking:

```bash
psql -f scripts/create_ai_run_binding.sql
```

> GRANT statements in that file will fail if the agent roles don't exist yet —
> that's expected. The tables and functions are still created. Re-run the grants
> after Step 4 once the roles exist.

**Idempotency:** the extension scripts must not INSERT rows that are also tracked
in bundles (agent registrations, capability rows, etc.). If they do, Step 4 checkout
will hit duplicate-key errors. Use `bundle.checkout('...', true)` (upsert mode) as
a workaround, or remove the seed inserts from the extension SQL.

### Step 3 — Import custom bundle JSON files

```bash
cd bundles
for f in io.bundle.ai.core.json \
          io.bundle.aquameta.plan.json \
          io.bundle.aquameta.navigation.json \
          io.bundle.aquameta.advisor.json \
          companion.claude_code.aquameta.json \
          companion.mistral_vibe.aquameta.json; do
  psql -c "SELECT bundle.import_repository(pg_read_file('$(pwd)/$f'));"
done
```

### Step 4 — Checkout bundles

The ai.core, aquameta.plan, and companion bundles form a circular FK cycle.
Check them out in a single deferred-constraint transaction:

```sql
-- Custom layer bundles with no circular deps
SELECT bundle.checkout('io.bundle.aquameta.navigation');
SELECT bundle.checkout('io.bundle.aquameta.advisor');

-- Circular FK group: ai.core must come first so ai.agent / ai.experiment rows
-- exist before companion bundles reference them.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
SELECT bundle.checkout('io.bundle.ai.core');
SELECT bundle.checkout('io.bundle.aquameta.plan');
SELECT bundle.checkout('companion.claude_code.aquameta');
SELECT bundle.checkout('companion.mistral_vibe.aquameta');
COMMIT;
```

> **Do NOT** use `SET session_replication_role = replica` — it bypasses all FK
> enforcement globally for the session.

If `SET CONSTRAINTS ALL DEFERRED` still fails, the most likely causes are:
(a) a non-deferrable FK firing out of checkout order, or
(b) duplicate-key errors from extension SQL having seeded rows the bundle also carries
(see idempotency note in Step 2).

### Step 5 — Create roles and grant permissions

```sql
CREATE ROLE ai_agent_claude_code LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_claude_haiku LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_mistral_vibe LOGIN PASSWORD 'aquameta';
CREATE ROLE ai_agent_dev LOGIN PASSWORD 'aquameta';
```

Re-run `scripts/create_ai_run_binding.sql` to apply the GRANT statements that
were skipped in Step 2.

### Step 6 — Restart aquameta

```bash
./aquameta
```

The HTTP server now serves the full stack including the custom layer.

---

## Known issues log

| Issue | Root cause | Status |
|-------|-----------|--------|
| Issues 2-8 (import_repository / _checkout_row failures) | Target had older pg_bundle than source | Resolved: fork pins pg_bundle at a compatible commit |
| Issues 9-10 (CREATE VIEW/FUNCTION not OR REPLACE) | meta_triggers generated plain CREATE DDL; bundle carried same schema objects | **Resolved:** `io.bundle.ai.core` no longer tracks `meta.function`/`meta.view` rows (commit `c2ed1f6`) |
| Issue 11 (companion.assessment missing) | Schema object added in DB, never written to extension SQL | Fixed: `extensions/companion/003-assessment.sql` |
| Issue 12 (circular FK on checkout) | Bundle decomposition spans ai.core + plan + companion | Fixed: DEFERRABLE FKs + SET CONSTRAINTS ALL DEFERRED in Step 4 |
| Issue 13 (companion.decision.supersedes_id) | Column dropped; orphaned in bundle data | Non-issue: `jsonb_populate_record` silently skips missing columns |
| Issue 14 (checkout_commit_id not set) | False diagnosis — symptom of earlier failures | Non-issue: `checkout.sql` sets it correctly |
| Issue 15 (meta.row_id_to_relation_id(jsonb) missing) | pg_bundle calls jsonb overload; meta upstream lacked it | **Resolved:** added to meta extension (commit `b830b63`) |
| meta.make_field_id(jsonb) missing | pg_bundle core.sql calls it; meta upstream lacked it | **Resolved:** added to meta extension (commit `b830b63`) |
| meta/meta_triggers as uninitialized submodules | Changes invisible to git; `submodule update` would overwrite | **Resolved:** both absorbed as tracked directories (commit `b830b63`) |
