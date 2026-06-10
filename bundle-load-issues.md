# Bundle Load Issues — Fresh Install (2026-06-10)

Issues encountered loading the SQL layer and bundles onto a fresh Aquameta instance.
Each section describes the failure, root cause, and fix applied.

---

## 1. Missing `extensions/pg_bundle/001-backward-compat-row-id.sql`

**Step 3 instruction** referenced `extensions/pg_bundle/001-backward-compat-row-id.sql`.
That file does not exist in `extensions/pg_bundle/`.

**Fix:** The equivalent file lives at `scripts/bundle-backward-compat-patch.sql`. Used that path instead.

---

## 2. `bundle.repository` NOT NULL constraint on staging columns

**Error:**
```
null value in column "tracked_rows_added" of relation "repository" violates not-null constraint
```

**Root cause:** `bundle.repository` has four staging columns (`tracked_rows_added`, `stage_rows_to_add`,
`stage_rows_to_remove`, `stage_fields_to_change`) defined `NOT NULL DEFAULT '[]'`. Exported bundle JSON
files have `null` for these fields (the repos were clean at export time). The `import_repository` function
inserts these values directly via `jsonb_to_record`, which passes `null` verbatim — the column default
is not applied on explicit `NULL`, and the `ON CONFLICT DO NOTHING` clause doesn't help because the NOT
NULL check fires before conflict resolution.

**Fix:** Rewrote `import_repository` to extract the repository record manually and use `COALESCE(..., '[]'::jsonb)`
for each staging column before inserting.

---

## 3. `repository_stage_fields_to_change_check` CHECK constraint violation

**Error:**
```
new row for relation "repository" violates check constraint "repository_stage_fields_to_change_check"
```

**Root cause:** After fixing issue #2, the initial patch used `'{}'::jsonb` (empty object) as the COALESCE
default. The four staging columns have CHECK constraints requiring `jsonb_typeof(...) = 'array'`. An empty
object `{}` is type `object`, not `array`.

**Fix:** Changed COALESCE default to `'[]'::jsonb` (empty array), matching both the column default and
the CHECK constraint.

---

## 4. `bundle._checkout_row` fails on JSON-encoded scalar values

**Error:**
```
invalid input syntax for type uuid: ""8f09a01d-d245-4c0c-9f62-1464a650d0c7""
```

**Root cause:** v0.5 bundles store field values in blobs as JSON-encoded strings — a UUID is stored as
`"8f09a01d-..."` (with surrounding double-quotes as JSON string delimiters). `_checkout_row` extracts
blob values via `bundle.unhash()` and passes them directly to `quote_literal()`. For old v0.4 bundles
the blob value is a raw string; for v0.5 bundles it's a JSON-encoded string, so the quoted value becomes
`'"uuid"'` which PostgreSQL cannot cast to `uuid`.

The same pattern applies to all scalar types: text, timestamps, booleans.

Old bundles (snake, fsm, layout, tags — checked out in a prior step) store raw values and work with the
original code. New bundles use JSON encoding throughout.

**Fix:** Patched `_checkout_row` to detect values starting with `"` and strip the JSON string encoding
via `raw_val::jsonb #>> '{}'` before building the INSERT.

---

## 5. `bundle._checkout_row` fails on JSON array values (`text[]` columns)

**Error:**
```
malformed array literal: "[]"
DETAIL: "[" must introduce explicitly-specified array dimensions.
```

**Root cause:** v0.5 bundles store array column values as JSON arrays (`[]`, `["a","b"]`). After the fix
in #4, scalar values starting with `"` are unwrapped, but array values starting with `[` pass through
as raw strings. PostgreSQL expects `'{}'` / `'{"a","b"}'` format for `text[]` literals, not JSON
array syntax.

Affected columns: `meta.function.parameters`, `meta.function.type_sig` (both `text[]`).

**Fix:** Added a `[`-prefix branch in `_checkout_row` that emits a SQL subquery expression:
```sql
array(SELECT value FROM jsonb_array_elements_text('...'::jsonb))
```
This converts JSON arrays to PostgreSQL `text[]` without requiring a direct jsonb→text[] cast (which
PostgreSQL does not support natively).

---

## 6. `bundle._checkout_row` fails on JSON object values (composite types)

**Error:**
```
malformed record literal: "{"pk_values": [...], "schema_name": "navigation", ...}"
DETAIL: Missing left parenthesis.
```

**Root cause:** v0.5 bundles store composite type values (e.g. `meta.row_id`) as JSON objects. After
issues #4 and #5 were fixed, JSON objects starting with `{` were still passed as plain quoted strings.
PostgreSQL composite literal format uses `(value1,value2,...)` syntax, so inserting a JSON object
string fails.

Affected column: `navigation.surface.target_row` (`meta.row_id`).

**Fix:** Added a `{`-prefix branch in `_checkout_row` that emits the value with a `::jsonb` cast:
```sql
'{"pk_values": ...}'::jsonb
```
An assignment cast `jsonb → meta.row_id` is registered (`meta.row_id(jsonb)`), so PostgreSQL coerces
this automatically at INSERT time.

---

## 7. `_checkout_row` array-append syntax error with `'null'` sentinel

**Error:**
```
malformed array literal: "null"
DETAIL: Array value must start with "{" or dimension information.
```

**Root cause:** In PL/pgSQL, `text_array || 'null'` is interpreted as array concatenation, where `'null'`
is cast to `text[]`. The string `'null'` is not a valid array literal, so PostgreSQL rejects it.

**Fix:** Changed all array element appends to use `array_append(arr, element)` instead of `arr || element`.

---

## 8. Duplicate key violations on re-checkout (idempotency)

**Error:**
```
duplicate key value violates unique constraint "capability_name_key"
duplicate key value violates unique constraint "note_pkey"
```

**Root cause:** Several bundles (`io.bundle.ai.core`, `companion.claude_code.aquameta`) contained rows
that were partially present from the existing installation (steps 1 and 2). The original `_checkout_row`
issued plain `INSERT` statements that fail on conflict.

**Fix:** Added `ON CONFLICT DO NOTHING` to the INSERT in `_checkout_row`, making checkout idempotent.
Existing rows are skipped silently; new rows are inserted.

---

## 9. `meta.stmt_view_create` uses `CREATE VIEW` instead of `CREATE OR REPLACE VIEW`

**Error:**
```
ERROR: relation "run_summary" already exists
CONTEXT: SQL statement "create view ai.run_summary as ..."
PL/pgSQL function meta.view_insert() ...
```

**Root cause:** `meta.stmt_view_create` generates `CREATE VIEW`. When inserting into the `meta.view`
abstraction layer, the `meta_view_insert_trigger` fires and executes this DDL. Views that were already
created by the SQL extension files (`000-ai.sql` etc.) already exist in the catalog, so the DDL fails.
`ON CONFLICT DO NOTHING` on the meta.view table row does not prevent the trigger from firing — it only
fires when the row insert proceeds, which it does when the row is new (different id), even if the backing
view was already created out-of-band.

**Fix:** Changed `meta.stmt_view_create` to generate `CREATE OR REPLACE VIEW`.

---

## 10. `meta.stmt_function_create` uses `CREATE FUNCTION` instead of `CREATE OR REPLACE FUNCTION`

**Error:**
```
ERROR: function "claim_next_run" already exists with same argument types
CONTEXT: SQL statement "create function ai.claim_next_run() ..."
PL/pgSQL function meta.function_insert() ...
```

**Root cause:** Same pattern as issue #9. `meta.stmt_function_create` generates `CREATE FUNCTION`.
Functions created by SQL extension files already exist when the bundle checkout fires DDL via the
`meta_function_insert_trigger`.

**Fix:** Changed `meta.stmt_function_create` to generate `CREATE OR REPLACE FUNCTION`.

---

## 11. Missing `companion.assessment` table

**Error:**
```
ERROR: relation "companion.assessment" does not exist
```

**Root cause:** `companion.assessment` is not defined in any of the companion extension SQL files
(`000-companion.sql`, `001-plan.sql`, `002-review.sql`). It is defined in
`scripts/container-setup-ai-companion.sql` with an explicit comment noting it is "missing from
extension files." The table must be created separately before checking out any bundle that references it.

**Fix:** Created `companion.assessment` from the DDL in `container-setup-ai-companion.sql`. Also loaded
`scripts/create_ai_run_binding.sql` (session/run tracking infrastructure referenced by that setup script).

Note: GRANT statements in `create_ai_run_binding.sql` for `ai_agent_claude_code` and `ai_agent_dev`
roles failed because those PostgreSQL roles do not exist yet at this stage. This is expected — role
creation is step 4 work. The tables and functions were created successfully.

---

## 12. Cross-bundle circular FK dependency

**Error:**
```
insert or update on table "plan_step" violates foreign key constraint "plan_step_plan_id_fkey"
Key (plan_id)=(...) is not present in table "plan".
```
and:
```
insert or update on table "plan_step" violates foreign key constraint "plan_step_experiment_id_fkey"
Key (experiment_id)=(...) is not present in table "experiment".
```

**Root cause:** `io.bundle.ai.core` and `io.bundle.aquameta.plan` have a circular FK dependency:
- `ai.core` commit contains `companion.plan_step` rows that reference `companion.plan` rows in `aquameta.plan`
- `aquameta.plan` commit contains `companion.plan_step` rows that reference `ai.experiment` rows in `ai.core`

Neither bundle can fully check out before the other. Additionally, `companion.claude_code.aquameta`
references `ai.agent` rows from `ai.core` via `companion.assessment.reviewer_id`.

None of the involved FK constraints were defined as `DEFERRABLE`.

**Fix:** Used `SET session_replication_role = replica` within a transaction to suppress FK trigger
firing during the bulk load, then committed all three bundles atomically:
```sql
BEGIN;
SET session_replication_role = replica;
SELECT bundle.checkout('io.bundle.ai.core');
SELECT bundle.checkout('io.bundle.aquameta.plan');
SELECT bundle.checkout('companion.claude_code.aquameta');
SET session_replication_role = DEFAULT;
COMMIT;
```
The three FK constraints that blocked individual runs were also made `DEFERRABLE INITIALLY IMMEDIATE`
as a partial mitigation (though `session_replication_role` was needed for deeper graph dependencies).

---

## 13. Missing `companion.decision.supersedes_id` column

**Error:**
```
column "supersedes_id" of relation "decision" does not exist
```

**Root cause:** The `companion.decision` table created by `000-companion.sql` does not include a
`supersedes_id` column, but the `companion.claude_code.aquameta` bundle contains decision rows that
reference it. This is a schema evolution gap — the column was added to the decision table on the source
system after the extension SQL was last updated.

**Fix:** `ALTER TABLE companion.decision ADD COLUMN IF NOT EXISTS supersedes_id uuid;`

---

## 14. `bundle.checkout` does not set `checkout_commit_id`

**Symptom:** After successful checkout, `bundle.repository.checkout_commit_id` remained `NULL` for
all newly checked-out bundles. The Aquameta IDE and bundle status queries use this field to determine
whether a bundle is checked out.

**Root cause:** Neither `bundle.checkout()` nor `bundle._checkout()` update the `checkout_commit_id`
column on `bundle.repository` after inserting rows. Pre-existing bundles (checked out on the source
system before export) already had this value set in the exported data. Newly checked-out bundles do not.

**Fix:** After all checkouts completed:
```sql
UPDATE bundle.repository
SET checkout_commit_id = head_commit_id
WHERE checkout_commit_id IS NULL AND head_commit_id IS NOT NULL;
```

---

## Suggested permanent fixes

These are recurring issues that should be addressed in the extension source files:

| Issue | File to fix |
|-------|-------------|
| `import_repository` NULL staging columns | `extensions/pg_bundle/import-export.sql` |
| `_checkout_row` JSON value formats | `extensions/pg_bundle/checkout.sql` |
| `_checkout_row` missing `ON CONFLICT DO NOTHING` | `extensions/pg_bundle/checkout.sql` |
| `stmt_view_create` CREATE vs CREATE OR REPLACE | `extensions/meta/...` |
| `stmt_function_create` CREATE vs CREATE OR REPLACE | `extensions/meta/...` |
| `checkout` not setting `checkout_commit_id` | `extensions/pg_bundle/checkout.sql` |
| `companion.assessment` missing from extension SQL | `extensions/companion/002-review.sql` or new file |
| Cross-bundle FK deps not deferrable | `extensions/companion/000-companion.sql`, `extensions/ai/000-ai.sql` |
