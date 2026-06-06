# Aquameta — Project Context for Claude Code

## Core Philosophy

The root thesis: the web stack's mess comes from **"files plus syntax"** — structure is latent and heterogeneous across files. Aquameta's answer is to make everything a database row. When all layers share one information model, general tools (version control, search, events, permissions) apply uniformly to all of them.

The consequence is that **the database, the filesystem, the web IDE, and the REST API are equivalent interfaces into the same rows** — not different systems. You can edit a widget by:

- Running `UPDATE widget.widget SET html = '...' WHERE name = 'foo'` in psql
- Opening the file in the PGFS FUSE mount and saving it
- Clicking and typing in the browser-based IDE
- `PATCH /endpoint/0.3/widget/widget/<uuid>` via the REST API

All four paths hit the same row. None is more "real" than the others. The database is the canonical representation; the interfaces are views.

The `meta` extension makes this fully recursive: schema itself is data. `CREATE TABLE` becomes `INSERT INTO meta.table`. The system is self-describing and self-modifying through any of its interfaces.

## Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │         PostgreSQL (canonical)       │
                    │  meta · bundle · endpoint · widget   │
                    │  event · semantics · filesystem      │
                    └──────┬──────┬──────────┬────────────┘
                           │      │          │
              ┌────────────┘      │          └────────────┐
              ▼                   ▼                        ▼
       Go daemon              PGFS mount              psql / SQL
    (HTTP + WebSocket)     (FUSE filesystem)       (direct DB access)
              │
    ┌─────────┼──────────┐
    │         │          │
    ▼         ▼          ▼
REST API   Resources  WebSocket
(endpoint)  (widget,  (event/NOTIFY)
             static)
    │
    ▼
 Browser
 (web IDE)
```

PostgreSQL extensions:
- `meta`       — writable system catalog; DDL as DML; schema is data
- `bundle`     — row-level version control (git for DB rows)
- `endpoint`   — HTTP routing, REST API, static resources, templates
- `widget`     — web component rows (HTML + CSS + JS columns)
- `event`      — trigger-based change events via NOTIFY
- `semantics`  — schema decorators, column-to-widget bindings
- `filesystem` — SQL access to the host filesystem (inverse of PGFS)
- `email`      — SMTP + templates
- `documentation` — schema-level docs

## Key Files

| File | Role |
|---|---|
| `main.go` | Entry point — starts embedded postgres or connects, mounts HTTP routes |
| `endpoint.go` | REST API handler; proxies HTTP → SQL `endpoint.*` functions |
| `resource.go` | Static resource / template handler; resolves URL → DB row |
| `websocket.go` | Socket.IO server; bridges browser events ↔ PostgreSQL NOTIFY |
| `config.go` | TOML config struct (`conf/bootloader.toml`) |
| `pgfs.go` | FUSE filesystem mount (Linux/FreeBSD only) |
| `conf/bootloader.toml` | Runtime config — DB connection, HTTP port, PGFS mount |

## Extension Layout

Each extension lives under `extensions/<name>/` with numbered SQL files:

```
extensions/
  bundle/        000-data_model.sql, 001-functions.sql, 002-utils.sql, 003-remotes-fdw.sql
  endpoint/      000-data-model.sql, 000-roles.sql, 001-server.sql, 002-helpers.sql
  event/         000-event.sql
  filesystem/    000-filesystem.sql
  ide/           000-ide.sql
  meta/          (external submodule / empty — lives at github.com/aquameta/meta)
  meta_triggers/ (empty placeholder)
  pg_bundle/     (placeholder)
  semantics/     000-semantics.sql
  widget/        000-widget.sql
  email/         000-smtp.sql, 001-templates.sql
  documentation/ 000-datamodel.sql
```

## Bundle System (version control for DB rows)

Central concept. A bundle tracks rowsets across commits:

- `bundle.blob` — content-addressed store (SHA-256 hash → text value)
- `bundle.bundle` — a named bundle (like a git repo)
- `bundle.commit` — a snapshot, points to a `rowset`
- `bundle.rowset` / `rowset_row` / `rowset_row_field` — the actual row data per commit
- `bundle.stage_row_added/deleted`, `stage_field_changed` — staged changes
- Key views: `head_commit_row_with_exists`, `tracked_row`, `untracked_row`, `offstage_*`

## Endpoint Extension (HTTP routing)

- `endpoint.resource` / `resource_binary` — static text/binary resources at a path
- `endpoint.template_route` — URL pattern → template rendering
- `endpoint.mimetype` / `mimetype_extension` — content type registry
- `endpoint.column_mimetype` — column → mimetype binding for field serving
- REST API: GET/POST/PATCH/DELETE on `/<schema>/<table>/<id>` rows

## Bundles (data packages)

`bundles/*.json` — exported bundle packages in the current format (v0.5).  
`bundles/v0.4/` — legacy directory format from v0.4.

Core bundles: `bootloader`, `endpoint`, `ide`, `mimetypes`, `semantics`, `widget`.  
App bundles: `games.snake`, `ui.fsm`, `ui.layout`, `ui.tags`.

## Go Dependencies

- `github.com/jackc/pgx/v4` — PostgreSQL driver (pgxpool for connection pooling)
- `github.com/lib/pq` — used for LISTEN/NOTIFY
- `github.com/googollee/go-socket.io` — WebSocket/Socket.IO
- `github.com/aquametalabs/embedded-postgres` — can run a bundled PostgreSQL process
- `bazil.org/fuse` — FUSE filesystem (Linux/FreeBSD only)
- `github.com/BurntSushi/toml` — config parsing
- `github.com/webview/webview` — desktop webview (optional)

## Development Conventions

- SQL extensions are loaded in numeric order; `.offline` suffix = disabled
- The Go daemon version is 0.5.0 (see `main.go` banner)
- Config lives in `conf/bootloader.toml` (copy from `conf/boot.toml.dist`)
- Certificates for TLS go in `certificates/`
- `scripts/create_extensions.sql` installs all extensions
- `bundles/export-all.sh` exports all tracked bundles to JSON

## Session Protocol

See [AGENTS.md](AGENTS.md) for the full cross-agent session protocol — DB connection, identity, orientation queries, companion bundle writes, and bundle row lifecycle checklist. The steps below are Claude Code-specific.

### Session Start

Use the `session-start` skill rather than running orientation queries manually. Verify the environment:

```bash
systemctl status aquameta   # service running?
ls pgfs/ai/                  # FUSE mounted?
```

### Session End

Update context rows, then commit with Claude's author identity:

```sql
UPDATE companion.context SET value = '...' WHERE key = 'current_focus';
UPDATE companion.context SET value = '...' WHERE key = 'last_session';

SELECT bundle.stage_tracked_rows('companion.claude_code.aquameta');
SELECT bundle.commit('companion.claude_code.aquameta', 'end-of-session update', 'claude_code', 'claude@aquameta.org');
```

### PGFS Access

The companion tables are also accessible at:
```
pgfs/companion/context/<uuid>/key
pgfs/companion/context/<uuid>/value
pgfs/companion/note/<uuid>/topic
pgfs/companion/note/<uuid>/title
pgfs/companion/note/<uuid>/body
pgfs/companion/decision/<uuid>/title
pgfs/companion/decision/<uuid>/decision
pgfs/companion/decision/<uuid>/rationale
```

## Agent Navigation

The `navigation` schema provides live search and inventory across all DB-resident code — widgets, resources, functions — which file indexers cannot see:

```sql
SELECT * FROM navigation.inventory();                          -- all surfaces, all bundles
SELECT * FROM navigation.inventory(ARRAY['org.aquameta.games.snake']);  -- scoped
SELECT * FROM navigation.search('endpoint');                   -- search all code columns
SELECT * FROM navigation.search('snake', ARRAY['org.aquameta.games.snake']);
```

Source: `extensions/navigation/000-navigation.sql` · Bundle: `io.bundle.aquameta.navigation`

## Session Files

- **MEMO.md** — legacy session file, now superseded by companion bundle; retained as fallback
- **TODO.md** — discrete task tracking (may also be superseded by ai.experiment)
