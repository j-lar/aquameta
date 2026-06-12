# Migration: Deploy Custom Layer to a Fresh Aquameta Install

This covers deploying the ai/companion/navigation/advisor layer onto a fresh
clone of the `cda47c6-custom-layer-install` branch. All steps assume you are
working from the repo root (`~/aquameta`).

```bash
git clone https://github.com/j-lar/aquameta.git ~/aquameta
cd ~/aquameta
git checkout cda47c6-custom-layer-install
```

Current proof target: get the work from this Aquameta instance onto a fresh DB
while using erichanson/pg_bundle at commit `cda47c6` behavior, without editing
pg_bundle itself. The compatibility issue is local to this install history: our
meta identifiers are PostgreSQL composite types, while pg_bundle `cda47c6` calls
a small JSON-like compatibility surface.

---

## What you need

The `cda47c6-custom-layer-install` branch is mostly self-contained. Everything
required for the custom layer is in git:

| Path | What it is |
|------|-----------|
| `extensions/meta/` | meta extension currently carried by this fork |
| `extensions/meta_triggers/` | meta_triggers extension currently carried by this fork |
| `extensions/pg_bundle/` | pg_bundle source at the pre-patch `9023f10` base |
| `extensions/ai/`, `extensions/companion/`, `extensions/navigation/`, `extensions/advisor/` | Custom schema extensions |
| `bundles/*.json` | Bundle JSON files (core + custom layer) |
| `scripts/install_custom_layer_bundles.sh` | Custom layer bundle import and checkout |
| `scripts/pg_bundle-cda47c6-checkout-compat.sql` | Post-load checkout compatibility shim (used by the install script) |

**Still required outside the repo:**

- `/tmp/pg_bundle-cda47c6-meta-compat.sql` — pre-load compatibility shim; must be present before pg_bundle is installed (copy to the target server manually)
- `/tmp/aquameta-cda47c6-proof-install.sh` — core Aquameta installer; runs the meta compat shim in the correct order before pg_bundle loads (copy to the target server manually)
- `conf/bootloader.toml` — copy from `conf/boot.toml.dist` and fill in DB credentials
- PostgreSQL must be installed and accessible (or use embedded mode)

The `/tmp` scripts cover the core Aquameta install only. The custom layer install
(`scripts/install_custom_layer_bundles.sh`) is already in the repo and handles
its own compat shim from `scripts/pg_bundle-cda47c6-checkout-compat.sql`.

---

## Short-Term Proof Install

Do this on a fresh target database before starting Aquameta for the first time.
Do not run `./aquameta` first: the daemon auto-installer loads pg_bundle
immediately after meta/meta_triggers, and the compatibility shim must be inserted
between those steps.

### Step 1 — Build and install extensions

This copies the `.control` and SQL files into PostgreSQL's extension directory
so that `CREATE EXTENSION` can find them. It does not touch the database.

```bash
cd ~/aquameta
sudo scripts/make_install_extensions.sh
```

If `make` fails on a missing build dependency (e.g. `pgxs` not found), install
`postgresql-server-dev-17` (or the matching dev package for your PG version) and retry.

### Step 2 — Build the Go daemon

```bash
cd ~/aquameta
go build -o aquameta .
```

This produces the `aquameta` binary that `systemctl start aquameta` expects at
`~/aquameta/aquameta`. Requires Go 1.21+; check with `go version`.

### Step 3 — Prepare a clean database



```bash
systemctl stop aquameta

sudo -u postgres psql -c "DROP DATABASE IF EXISTS aquameta;"
sudo -u postgres psql -c "CREATE DATABASE aquameta OWNER aquameta;"
```

If Aquameta was already started and failed during install, treat the database as
partially installed and recreate it before continuing.

### Step 4 — Run the proof installer

Copy these two scripts to the target first:

```text
/tmp/pg_bundle-cda47c6-meta-compat.sql
/tmp/aquameta-cda47c6-proof-install.sh
```

Then run only the proof installer. It runs the compat SQL internally:

```bash
cd ~/aquameta
DB_URL=postgresql://aquameta:aquameta@localhost:5432/aquameta \
  /tmp/aquameta-cda47c6-proof-install.sh
```

The proof installer does this order:

1. `CREATE EXTENSION meta`
2. `CREATE EXTENSION meta_triggers`
3. Load `/tmp/pg_bundle-cda47c6-meta-compat.sql`
4. Load pg_bundle SQL directly
5. Create the remaining core Aquameta extensions
6. Import and checkout the core bundles in the same order as `main.go`:
   `org.aquameta.core.mimetypes`, `org.aquameta.core.endpoint`, `org.aquameta.core.widget`,
   `org.aquameta.core.ide`, `org.aquameta.core.semantics`, `org.aquameta.games.snake`,
   `org.aquameta.ui.fsm`, `org.aquameta.ui.layout`, `org.aquameta.ui.tags`,
   `org.aquameta.core.bootloader`

A successful run exits `0` and has no `ERROR` output. The compat script itself is
quiet except for normal `CREATE FUNCTION` / `CREATE OPERATOR` output when run
through `psql`.

### Step 5 — Start Aquameta

After the proof installer succeeds, start the daemon. It should see the core
install as complete and skip auto-install.

```bash
systemctl start aquameta
systemctl status aquameta --no-pager
```

Once the HTTP server starts, the core install is complete. Continue with the
custom layer below.

---

## Custom Layer Install

### Step 6 — Load custom extensions

Load in dependency order (ai -> companion -> navigation -> advisor):

```bash
DB_URL=postgresql://aquameta:aquameta@localhost:5432/aquameta

psql $DB_URL -f extensions/ai/000-ai.sql
psql $DB_URL -f extensions/ai/001-ideas.sql
psql $DB_URL -f extensions/companion/000-companion.sql
psql $DB_URL -f extensions/companion/001-plan.sql
psql $DB_URL -f extensions/companion/002-review.sql
psql $DB_URL -f extensions/companion/003-assessment.sql
psql $DB_URL -f extensions/navigation/000-navigation.sql
psql $DB_URL -f extensions/advisor/000-advisor.sql
```

Then create the ai_agent roles and wire up run tracking:

```bash
psql $DB_URL -f scripts/create_ai_run_binding.sql
```

> GRANT statements in that file will fail if the agent roles don't exist yet —
> those roles are created by the `ai.agent` insert trigger during bundle checkout
> in Step 8. That's expected; the tables and functions are still created.
> Re-run `psql $DB_URL -f scripts/create_ai_run_binding.sql` after Step 8.

**Idempotency:** the extension scripts must not INSERT rows that are also tracked
in bundles (agent registrations, capability rows, etc.). If they do, checkout
will hit duplicate-key errors. Use `bundle.checkout('...', true)` (upsert mode) as
a workaround, or remove the seed inserts from the extension SQL.

Extension SQL creates schemas, tables, functions, triggers, and views only. Web
surfaces such as `/ai/experiments`, `/plans`, and game pages are endpoint and
widget rows; those come from bundle import/checkout in the next steps.

The scripted path for Steps 7-8 is:

```bash
cd ~/aquameta
DB_URL=postgresql://aquameta:aquameta@localhost:5432/aquameta \
  scripts/install_custom_layer_bundles.sh

# Include optional game bundles too:
DB_URL=postgresql://aquameta:aquameta@localhost:5432/aquameta \
  scripts/install_custom_layer_bundles.sh --games
```

The script is committed to this branch. It imports the custom bundle JSON files,
loads `scripts/pg_bundle-cda47c6-checkout-compat.sql`, applies the historical
compatibility stubs required by the current exported bundle data, and uses
`bundle.checkout(..., true)`.

### Step 7 — Import custom bundle JSON files

`pg_read_file()` runs as the PostgreSQL server process, which cannot read files
under home directories. Copy the bundle JSON files to `/tmp/` first so the server
can read them, then import. Set `DB_URL` so psql connects as the aquameta role
rather than trying the OS user via the Unix socket.

```bash
export DB_URL=postgresql://aquameta:aquameta@localhost:5432/aquameta

for f in io.bundle.ai.core \
          io.bundle.aquameta.plan \
          io.bundle.aquameta.navigation \
          io.bundle.aquameta.advisor \
          companion.claude_code.aquameta \
          companion.mistral_vibe.aquameta; do
  cp ~/aquameta/bundles/$f.json /tmp/$f.json
  chmod 644 /tmp/$f.json
  psql $DB_URL -c "SELECT bundle.import_repository(pg_read_file('/tmp/$f.json'));"
done
```

### Step 8 — Checkout bundles

The ai.core, aquameta.plan, and companion bundles form a circular FK cycle.
Check them out in a single deferred-constraint transaction. Start from a clean `aquameta=#` prompt; if psql shows `aquameta-#`, type `\r` first because psql is still buffering an unfinished statement:

```bash
psql $DB_URL
```

At the `aquameta=#` prompt (if psql shows `aquameta-#`, type `\r` first — psql is still buffering an unfinished statement):

```sql
-- If a previous attempt manually created ai_agent_* roles, remove only roles
-- that do not have matching ai.agent rows. Normal checkout recreates roles
-- through the ai.agent trigger.
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT pr.rolname
        FROM pg_roles pr
        WHERE pr.rolname LIKE 'ai_agent_%'
          AND NOT EXISTS (
              SELECT 1
              FROM ai.agent a
              WHERE pr.rolname = 'ai_agent_' || a.name
          )
    LOOP
        EXECUTE format('DROP OWNED BY %I', rec.rolname);
        EXECUTE format('DROP ROLE %I', rec.rolname);
    END LOOP;
END $$;

-- Custom layer bundles with no circular deps.
SELECT bundle.checkout('io.bundle.aquameta.navigation', true);
SELECT bundle.checkout('io.bundle.aquameta.advisor', true);

-- Circular FK group: ai.core must come first so ai.agent / ai.experiment rows
-- exist before companion bundles reference them.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;

-- ai/000-ai.sql seeds capability rows with fresh UUIDs; ai.core carries
-- the canonical bundled rows. Remove only the known bundled capability seeds.
DELETE FROM ai.capability
WHERE name IN (
    'read_advisor', 'read_ai', 'read_bundle', 'read_companion',
    'read_documentation', 'read_endpoint', 'read_meta', 'read_semantics',
    'read_widget', 'write_ai', 'write_bundle', 'write_companion',
    'write_endpoint', 'write_semantics', 'write_widget'
);

SELECT bundle.checkout('io.bundle.ai.core', true);

-- Historical compatibility rows referenced by the current exported bundles.
INSERT INTO ai.session (id, agent_id, title, context, ended_at)
SELECT
    '00000000-0000-0000-0000-000000000187'::uuid,
    a.id,
    'fresh install compatibility stub',
    '{"source":"migration","reason":"plan_review.run_id references historical runs not bundled"}'::jsonb,
    now()
FROM ai.agent a
ORDER BY a.name
LIMIT 1
ON CONFLICT (id) DO NOTHING;

INSERT INTO ai.run (id, session_id, intent, status, started_at, completed_at)
VALUES
    ('5a4e67ee-8cfc-445c-9e6c-a944f5a4bf30', '00000000-0000-0000-0000-000000000187', 'historical run referenced by plan_review', 'completed', now(), now()),
    ('9c00075b-0cf7-46ce-9dbc-15de03fe34a0', '00000000-0000-0000-0000-000000000187', 'historical run referenced by plan_review', 'completed', now(), now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO ai.experiment (id, name, description, status, findings)
VALUES (
    'd8d4d299-de64-452a-863e-09f45db053cb',
    'historical experiment referenced by plan_step',
    'Compatibility stub for a plan_step.experiment_id reference whose original experiment row is not bundled.',
    'deferred',
    'Stub inserted during fresh-install compatibility checkout.'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO ai.agent (id, name, description, model)
VALUES
    ('1444b702-34b7-4056-9656-71c71d4a6fc3', 'compat_requester_1444b702', 'Compatibility stub for historical assessment.requester_id reference.', 'unknown'),
    ('c923c672-06e1-4c71-8c19-fbd9ddf95446', 'compat_requester_c923c672', 'Compatibility stub for historical assessment.requester_id reference.', 'unknown'),
    ('e0422b05-8ef7-4d13-8fe0-23848276f551', 'compat_requester_e0422b05', 'Compatibility stub for historical assessment.requester_id reference.', 'unknown')
ON CONFLICT (id) DO NOTHING;

-- ai.core currently carries a few stale companion.plan_step rows. The plan
-- bundle is canonical for companion.plan/plan_step/plan_review, so remove only
-- the plan_step rows that came from ai.core before checking out the plan bundle.
DELETE FROM companion.plan_step ps
USING bundle._get_commit_rows((
    SELECT head_commit_id FROM bundle.repository WHERE name = 'io.bundle.ai.core'
)) r
WHERE (r.row_id).schema_name = 'companion'
  AND (r.row_id).relation_name = 'plan_step'
  AND ps.id = ((r.row_id).pk_values)[1]::uuid;

SELECT bundle.checkout('io.bundle.aquameta.plan', true);
SELECT bundle.checkout('companion.claude_code.aquameta', true);
SELECT bundle.checkout('companion.mistral_vibe.aquameta', true);
COMMIT;
```

> **Do NOT** use `SET session_replication_role = replica` — it bypasses all FK
> enforcement globally for the session.

If `SET CONSTRAINTS ALL DEFERRED` still fails, the most likely causes are:
(a) a non-deferrable FK firing out of checkout order, or
(b) duplicate-key errors from extension SQL having seeded rows the bundle also carries
(see idempotency note in Step 6).


Optional game bundles are not all part of the core proof install. Import and
checkout them explicitly if those pages should exist:

```bash
cd /path/to/aquameta
for b in \
  org.aquameta.games.blackjack \
  org.aquameta.games.craps \
  org.aquameta.games.magic8ball \
  org.aquameta.games.office_quest \
  org.aquameta.games.roulette; do
  cp "bundles/$b.json" "/tmp/$b.json"
  chmod 0644 "/tmp/$b.json"
  psql $DB_URL -v ON_ERROR_STOP=1 -c "SELECT bundle.import_repository(pg_read_file('/tmp/$b.json'));"
  psql $DB_URL -v ON_ERROR_STOP=1 -c "SELECT bundle.checkout('$b', true);"
done
```

Quick route/widget verification:

```sql
SELECT path FROM endpoint.resource
WHERE path IN ('/ai/experiments', '/ai/runs', '/companion', '/ideas', '/plans', '/ai/plans', '/blackjack', '/craps', '/magic8ball', '/office-quest', '/roulette')
ORDER BY path;

SELECT name FROM widget.widget
WHERE name IN ('ai_experiment', 'ai_run_summary', 'ai_idea', 'companion_session_brief', 'companion_plan_viewer', 'craps', 'magic8ball', 'rl_game', 'bj_game', 'office_quest')
ORDER BY name;
```

### Step 9 — Verify roles and grant permissions

Do not manually `CREATE ROLE ai_agent_*` before checkout. `ai.agent` rows create
those PostgreSQL roles through the `ai.agent_insert` trigger. If a manual role was
created before checkout and the matching `ai.agent` row is absent, drop that
stray role and rerun checkout so the bundle can create the agent row and role
together.

After Step 8, verify the expected roles exist:

```sql
SELECT rolname
FROM pg_roles
WHERE rolname LIKE 'ai_agent_%'
ORDER BY rolname;
```

Re-run `scripts/create_ai_run_binding.sql` to apply the GRANT statements that
were skipped in Step 6.

### Step 10 — Restart Aquameta

```bash
systemctl restart aquameta
systemctl status aquameta --no-pager
```

The HTTP server should now serve the full stack including the custom layer.

---

## Compatibility Shim Contents

The short-term shim provides only the compatibility API expected by pg_bundle
`cda47c6`:

```sql
meta.make_schema_id(text)
meta.make_relation_id(text, text)
meta.make_row_id(text, text, text, text)
meta.make_row_id(text, text, text[], text[])
meta.make_field_id(jsonb, text)
meta.make_field_id(meta.row_id, text)
meta.row_id_to_relation_id(jsonb)
meta.validate_row_id_pk(meta.row_id)
```

It also installs JSON-like `->` and `->>` operators for the relevant meta
identifier composite types, plus exact `jsonb || meta.row_id` and
`jsonb || meta.field_id` operators used by pg_bundle staging arrays. Those operators must be visible while pg_bundle loads
with `search_path=bundle`, so the proof script installs exact-signature operators
in `pg_catalog` and delegates to `to_jsonb(value) -> key` / `to_jsonb(value) ->>
key`.

After pg_bundle itself is loaded, the proof installer also loads
`/tmp/pg_bundle-cda47c6-checkout-compat.sql`. This post-load shim replaces
`bundle._get_commit_rows(...)` and `bundle._get_commit_fields(...)` so checkout
can read bundle exports whose `jsonb_rows` array and `jsonb_fields` object keys
store `meta.row_id` values as PostgreSQL composite text strings, JSON objects, or JSON-object strings. It also replaces `bundle._checkout_row(...)` so plain scalar blob values such as UUIDs are converted to JSON strings before `jsonb_populate_record(...)` instead of being parsed as JSON literals; for legacy `null` blobs targeting `NOT NULL` columns with defaults, it omits the field so PostgreSQL applies the table default; and it skips stale bundle fields whose target columns no longer exist.

This is deliberately a proof mechanism. If it becomes permanent, move it into a
small Aquameta-owned compatibility extension or installer step rather than
patching pg_bundle.

---

## Known Issues Log

| Issue | Root cause | Status |
|-------|-----------|--------|
| pg_bundle `cda47c6` calls `meta.make_relation_id(...)` / `meta.make_row_id(...)` | This install's meta API does not expose all legacy constructor aliases | Short-term proof uses `/tmp/pg_bundle-cda47c6-meta-compat.sql` before pg_bundle load |
| pg_bundle `cda47c6` uses `row_id->>'schema_name'` on composite meta IDs | pg_bundle expects JSON-like ID access; current meta IDs are composites | Short-term proof installs exact `->` / `->>` operators for meta ID composites |
| pg_bundle checkout fails with `invalid input syntax for type json`, token `(` | Bundle exports store row IDs as composite text keys or JSON-object rows; `_get_commit_fields` tries to parse those keys as JSON | Short-term proof loads `/tmp/pg_bundle-cda47c6-checkout-compat.sql` after pg_bundle load |
| pg_bundle checkout fails parsing field `id` value as JSON | Bundle blob values can be plain scalar text such as UUIDs, while `_checkout_row` expects JSON-encoded values | Checkout compatibility shim replaces `_checkout_row` with a scalar fallback |
| pg_bundle checkout fails with `widget.widget.pre_js` null/not-null violation | Legacy bundle rows can carry `null` blobs for columns that later gained `NOT NULL DEFAULT` | Checkout compatibility shim skips `null` values for `NOT NULL` columns with defaults |
| pg_bundle checkout fails on missing column such as `companion.decision.supersedes_id` | Bundle history can include fields for columns no longer present in the current extension schema | Checkout compatibility shim skips fields whose target columns do not exist |
| `io.bundle.aquameta.plan` checkout fails on `plan_step_plan_id_position_key` | `io.bundle.ai.core` currently carries stale `companion.plan_step` rows; `io.bundle.aquameta.plan` carries the canonical plan rows | Delete only ai.core-owned `companion.plan_step` rows between ai.core checkout and plan checkout |
| `io.bundle.aquameta.plan` checkout fails on `plan_step_experiment_id_fkey` | Plan steps reference a historical experiment row not present in the bundled `ai.experiment` rows | Insert a minimal compatibility stub for experiment `d8d4d299-de64-452a-863e-09f45db053cb` before plan checkout |
| `companion.claude_code.aquameta` checkout fails on `assessment_requester_id_fkey` | Assessment rows reference historical requester agents not carried by `io.bundle.ai.core` | Insert minimal compatibility `ai.agent` stubs for requester IDs `1444b702...`, `c923c672...`, and `e0422b05...` before companion checkout |
| Direct pg_bundle edits in `29f276d` | Previous attempt fixed pg_bundle instead of proving compatibility externally | Avoid for proof; use `29f276d^` (`9023f109...`) on target |
| Issues 2-8 (import_repository / `_checkout_row` failures) | Target had older pg_bundle than source | Resolved by using the target pg_bundle commit consistently |
| Issues 9-10 (CREATE VIEW/FUNCTION not OR REPLACE) | meta_triggers generated plain CREATE DDL; bundle carried same schema objects | **Resolved:** `io.bundle.ai.core` no longer tracks `meta.function`/`meta.view` rows (commit `c2ed1f6`) |
| Issue 11 (`companion.assessment` missing) | Schema object added in DB, never written to extension SQL | Fixed: `extensions/companion/003-assessment.sql` |
| Issue 12 (circular FK on checkout) | Bundle decomposition spans ai.core + plan + companion | Fixed: DEFERRABLE FKs + `SET CONSTRAINTS ALL DEFERRED` in Step 8 |
| Issue 13 (`companion.decision.supersedes_id`) | Column dropped; orphaned in bundle data | Checkout compatibility shim skips fields whose target columns no longer exist |
| Issue 14 (`checkout_commit_id` not set) | False diagnosis; symptom of earlier failures | Non-issue: `checkout.sql` sets it correctly |
