# AGENTS.md — Aquameta Agent Guidelines

## What This Project Is

Aquameta's central claim: the web stack is a mess because it uses **"files plus syntax"** — structure is latent and heterogeneous. The fix is to make everything a database row, giving all layers a shared information model.

The critical framing for agents: **the database, the filesystem, the web IDE, and the REST API are all interfaces into the same rows — not separate systems**. A widget edited in the browser IDE, via psql, via the PGFS filesystem mount, or via a REST PATCH is the same operation at the data level. No interface is more authoritative than another; the rows are the truth.

This means:
- The `meta` extension makes schema itself a row — DDL is DML
- The `filesystem` extension makes the host filesystem accessible as SQL rows
- The `widget` extension stores UI components as rows with `html`, `css`, `js` columns
- The `bundle` extension version-controls any row in any table
- Tools that work on rows (bundle, event, semantics) apply uniformly to all layers

When you make a change, ask: **what row changes?** Then ask which interface is most appropriate to make that change through.

## Session Protocol

Session continuity lives in the `companion.claude_code.aquameta` bundle as DB rows — not files.

### Bootstrap

DB: `localhost:5432 / database: aquameta / user: aquameta / password: aquameta`

First, fetch the full startup protocol from the DB:
```sql
SELECT value FROM companion.context WHERE key = 'session_startup';
```
Execute the queries it returns. If the DB is unavailable, fall back to `MEMO.md` if present.

### Identity and Run Binding

Open a session and run **only when Aquameta work is about to begin** (not at harness startup). Pure ideation sessions leave no DB rows.

```sql
-- Switch to your agent role first
SET ROLE ai_agent_<your_agent_name>;

-- Open session (creates ai.session + binds to ai.active_run)
SELECT ai.open_session('optional title');

-- Open run when the first substantive task arrives
SELECT ai.open_run('summary of first instruction');
```

`ai.open_session()` derives your agent name from `current_user` (strips `ai_agent_` prefix). It must match a row in `ai.agent`. `ai.open_run()` requires an open session.

All `bundle.commit()` calls automatically record `ai.run_commit` when a run is bound. Without a bound run, `bundle.commit()` emits a NOTICE but still commits.

### Orientation

```sql
-- Current state, recent decisions and notes
SELECT type, title, body
FROM companion.session_brief
ORDER BY type, updated_at DESC;

-- Pending experiment backlog
SELECT name, description
FROM ai.experiment
WHERE status = 'pending'
ORDER BY created_at;
```

### Writing to the Companion Bundle

```sql
-- New note (topic: finding | architecture | convention | reference | open_question)
INSERT INTO companion.note (topic, title, body) VALUES ('finding', 'Title', 'Body...');

-- New decision
INSERT INTO companion.decision (title, decision, rationale) VALUES ('What', 'Choice', 'Why');

-- New experiment
INSERT INTO ai.experiment (name, description, status) VALUES ('Name', 'Description', 'pending');
```

### Session End

Close run and session, then commit:
```sql
SELECT ai.close_run();     -- marks run 'completed', unbinds it
SELECT ai.close_session(); -- marks session ended, removes binding row

SELECT bundle.stage_tracked_rows('companion.claude_code.aquameta');
SELECT bundle.commit('companion.claude_code.aquameta', 'end-of-session update',
                     'your_agent_name', 'your_agent@example.com');
```

### Bundle Row Lifecycle (Onboarding Checklist)

New agents consistently hit the same errors. Follow this exactly for new rows:

1. **INSERT** the row into the target table
2. **Track** it in the repository:
   ```sql
   SELECT bundle.track_untracked_row(
     'bundle_name',
     ('schema_name', 'table_name', ARRAY['id'], ARRAY['<uuid>'])::meta.row_id
   );
   ```
3. **Stage** all tracked changes:
   ```sql
   SELECT bundle.stage_tracked_rows('bundle_name');
   ```
4. **Commit**:
   ```sql
   SELECT bundle.commit('bundle_name', 'message', 'agent_name', 'agent@example.com');
   ```

Common pitfalls:
- The table is `bundle.repository`, not `bundle.bundle`
- `stage_tracked_row()` (singular) fails on untracked rows — use `track_untracked_row()` first for new rows
- `meta.row_id` composite type: `(schema_name text, relation_name text, pk_column_names text[], pk_values text[])`
- Run `\df bundle.stage_tracked_row` to verify function signatures before calling

---

## Reading the Codebase

**Start here for orientation:**
1. `CLAUDE.md` — Claude Code-specific config; also has full architecture map, key files, extension layout
2. `extensions/<name>/000-*.sql` — data model for each subsystem
3. `extensions/<name>/001-*.sql` — functions/procedures for that subsystem
4. `main.go` — HTTP route wiring and startup sequence

**Understanding a URL request path:**
1. Go `endpoint.go` or `resource.go` receives the HTTP request
2. It calls a SQL function (e.g. `endpoint.request()`) via pgx
3. That function queries `endpoint.resource`, `endpoint.template_route`, etc.
4. The result comes back as JSON and is written to the HTTP response

**Understanding bundle/version-control operations:**
- Bundle functions are in `extensions/bundle/001-functions.sql`
- The data model is in `extensions/bundle/000-data_model.sql`
- `bundle.blob` is the content store; everything else references blob hashes

## Making Changes

### SQL Extensions

- Number new files to slot between existing ones (e.g. `003-` if you're between `002-` and `004-`)
- Never modify `.offline` files — they are intentionally disabled; copy and rename if activating
- Schema changes to `bundle` or `endpoint` are high-impact — those tables hold live app state
- The `meta` extension makes DDL reversible via DML; prefer `INSERT INTO meta.table` over raw `CREATE TABLE` when working inside the DB

### Go Daemon

- The daemon is intentionally thin — avoid adding business logic here
- HTTP handlers should delegate to SQL functions, not duplicate logic
- `pgxpool` is used for connection pooling; use `dbpool.QueryRow()` / `dbpool.Exec()` patterns already present
- FUSE code (`pgfs.go`) is Linux/FreeBSD only — `pgfs_unsupported.go` is the stub for other platforms

### Bundles

- Exported bundle JSON files in `bundles/*.json` are the current serialization format
- To export: `bundles/export-all.sh`
- Legacy `bundles/v0.4/` directory format is kept for reference only — do not modify

## Extension Development Philosophy

**New capabilities belong in bundles, not in `main.go`.**

`main.go` is for core infrastructure that every Aquameta installation needs (meta, bundle, endpoint, widget, etc.). Optional or experimental capabilities — including the `ai` schema — belong in the bundle ecosystem:

1. Write the schema as a standalone SQL file under `extensions/<name>/`
2. Load it into your running Aquameta instance directly (`\i` or psql)
3. Create a bundle, track the rows, commit — that's your distributable package
4. Other installations import via `bundle.import_repository` + `bundle.checkout`

The DDL (table definitions, triggers, functions) lives in the SQL file and is re-run on fresh installs before importing the bundle. The bundle ships row data (seeded records, configuration). This mirrors exactly how every other extension works.

The promotion path: if a bundle-based extension stabilizes and becomes something every installation needs, *then* wire it into `main.go`. Not before.

## What NOT to Do

- Do not add business logic to the Go daemon that belongs in SQL
- Do not create new top-level files without a clear reason — the project structure is intentional
- Do not modify `.offline` SQL files — they are parked, not broken
- Do not assume `meta` or `meta_triggers` extension directories contain code — they may be submodule stubs
- Do not hardcode connection strings; always read from `conf/bootloader.toml` via the `tomlConfig` struct

## Testing

- Extension test suites live in `extensions/<name>/test/`
- `extensions/bundle/test/` and `extensions/endpoint/test/` have the most coverage
- Run tests by loading the test SQL into a dev database — there is no automated test runner wired up at the Go level

## Key Invariants

1. **Content addressing**: `bundle.blob` rows are immutable once inserted (hash = SHA-256 of value). Never UPDATE a blob row.
2. **UUID primary keys**: All tables use `uuid_generate_v4()` as default PKs. Never use integer sequences for new tables.
3. **Endpoint routing priority**: `resource` → `resource_binary` → `template_route`. A 300 is returned if more than one matches.
4. **Roles**: `endpoint` extension defines roles used for row-level security. Check `000-roles.sql` before adding tables that need RLS.

## Common Patterns

```sql
-- Calling a meta operation (create a table via DML)
INSERT INTO meta.table (schema_id, name) VALUES (
    (SELECT id FROM meta.schema WHERE name = 'myschema'),
    'my_new_table'
);

-- Serving a static resource (add a row)
INSERT INTO endpoint.resource (path, mimetype_id, content)
VALUES ('/my/path', (SELECT id FROM endpoint.mimetype WHERE mimetype='text/html'), '<html>...</html>');

-- Staging a bundle change
SELECT bundle.stage_row_add('my-bundle-name', 'myschema', 'mytable', 'row-id-uuid');
SELECT bundle.commit('my-bundle-name', 'commit message');
```
