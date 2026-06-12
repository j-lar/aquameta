#!/usr/bin/env bash
set -euo pipefail

# Install the custom AI/companion/navigation/advisor bundle layer onto a fresh
# Aquameta DB that already has core Aquameta and the custom extension schemas
# loaded. This is intentionally a proof/install script, not a general-purpose
# production migration.

DB_NAME="${DB_NAME:-aquameta}"
REPO_ROOT="${REPO_ROOT:-$(pwd)}"
WITH_GAMES=0
GAMES_ONLY=0
SKIP_COMPAT=0

usage() {
  cat <<'EOF'
Usage: scripts/install_custom_layer_bundles.sh [--games] [--games-only] [--skip-compat]

Environment:
  DB_NAME    Database name when DB_URL is unset. Default: aquameta
  DB_URL     Optional PostgreSQL URL. If unset, uses sudo -u postgres psql -d DB_NAME
  REPO_ROOT  Aquameta repo root. Default: current directory

Options:
  --games        Also import/checkout optional game bundles after the custom layer.
  --games-only   Import/checkout game bundles only; skip the custom layer install.
                 Use this when the custom layer is already installed.
  --skip-compat  Do not load scripts/pg_bundle-cda47c6-checkout-compat.sql.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --games)
      WITH_GAMES=1
      ;;
    --games-only)
      GAMES_ONLY=1
      WITH_GAMES=1
      ;;
    --skip-compat)
      SKIP_COMPAT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -d "$REPO_ROOT/bundles" || ! -d "$REPO_ROOT/scripts" ]]; then
  echo "Run from the Aquameta repo root or set REPO_ROOT=/path/to/aquameta" >&2
  exit 1
fi

psql_cmd() {
  if [[ -n "${DB_URL:-}" ]]; then
    psql -v ON_ERROR_STOP=1 "$@" "$DB_URL"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" "$@"
  fi
}

CUSTOM_BUNDLES=(
  io.bundle.ai.core
  io.bundle.aquameta.plan
  io.bundle.aquameta.navigation
  io.bundle.aquameta.advisor
  companion.claude_code.aquameta
  companion.mistral_vibe.aquameta
)

GAME_BUNDLES=(
  org.aquameta.games.blackjack
  org.aquameta.games.craps
  org.aquameta.games.magic8ball
  org.aquameta.games.office_quest
  org.aquameta.games.roulette
)

CAPABILITY_NAMES=(
  read_advisor
  read_ai
  read_bundle
  read_companion
  read_documentation
  read_endpoint
  read_meta
  read_semantics
  read_widget
  write_ai
  write_bundle
  write_companion
  write_endpoint
  write_semantics
  write_widget
)

check_bundle_files() {
  local bundle
  for bundle in "$@"; do
    if [[ ! -f "$REPO_ROOT/bundles/$bundle.json" ]]; then
      echo "Missing bundle file: $REPO_ROOT/bundles/$bundle.json" >&2
      exit 1
    fi
  done
}

import_bundle() {
  local bundle="$1"
  local tmp_json="/tmp/$bundle.json"
  echo "Importing $bundle"
  cp "$REPO_ROOT/bundles/$bundle.json" "$tmp_json"
  chmod 0644 "$tmp_json"
  psql_cmd -c "SELECT bundle.import_repository(pg_read_file('$tmp_json'));"
}

if [[ "$GAMES_ONLY" -eq 0 ]]; then
  check_bundle_files "${CUSTOM_BUNDLES[@]}"
fi
if [[ "$WITH_GAMES" -eq 1 ]]; then
  check_bundle_files "${GAME_BUNDLES[@]}"
fi

echo "Checking schema prerequisites..."
psql_cmd <<'SQL'
DO $$
BEGIN
    IF to_regclass('bundle.repository') IS NULL THEN
        RAISE EXCEPTION 'bundle schema is missing; run the core proof installer first';
    END IF;
    IF to_regclass('ai.agent') IS NULL THEN
        RAISE EXCEPTION 'ai schema is missing; load extensions/ai/*.sql first';
    END IF;
    IF to_regclass('companion.plan') IS NULL THEN
        RAISE EXCEPTION 'companion schema is missing; load extensions/companion/*.sql first';
    END IF;
    IF to_regclass('navigation.surface') IS NULL THEN
        RAISE EXCEPTION 'navigation schema is missing; load extensions/navigation/000-navigation.sql first';
    END IF;
    IF to_regclass('advisor.advisor') IS NULL THEN
        RAISE EXCEPTION 'advisor schema is missing; load extensions/advisor/000-advisor.sql first';
    END IF;
END $$;
SQL

if [[ "$GAMES_ONLY" -eq 0 ]]; then

if [[ "$SKIP_COMPAT" -eq 0 ]]; then
  echo "Loading pg_bundle cda47c6 checkout compatibility shim..."
  local_compat_sql=$(mktemp /tmp/pg_bundle-cda47c6-checkout-compat.XXXXXX.sql)
  trap 'rm -f "$local_compat_sql"' EXIT
  cp "$REPO_ROOT/scripts/pg_bundle-cda47c6-checkout-compat.sql" "$local_compat_sql"
  chmod 644 "$local_compat_sql"
  psql_cmd -f "$local_compat_sql"
fi

for bundle in "${CUSTOM_BUNDLES[@]}"; do
  import_bundle "$bundle"
done

echo "Dropping orphan ai_agent_* roles created outside ai.agent rows..."
psql_cmd <<'SQL'
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
SQL

echo "Checking out custom layer bundles..."
capability_values=""
for cap in "${CAPABILITY_NAMES[@]}"; do
  capability_values+="('$cap'),"
done
capability_values="${capability_values%,}"

psql_cmd -v capability_values="$capability_values" <<'SQL'
SELECT bundle.checkout('io.bundle.aquameta.navigation', true);
SELECT bundle.checkout('io.bundle.aquameta.advisor', true);

BEGIN;
SET CONSTRAINTS ALL DEFERRED;

DELETE FROM ai.capability
WHERE name IN (
    SELECT capability_name
    FROM (VALUES :capability_values) AS bundled_capabilities(capability_name)
);

SELECT bundle.checkout('io.bundle.ai.core', true);

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
SQL

fi # end GAMES_ONLY guard

if [[ "$WITH_GAMES" -eq 1 ]]; then
  echo "Importing and checking out optional game bundles..."
  for bundle in "${GAME_BUNDLES[@]}"; do
    import_bundle "$bundle"
    psql_cmd -c "SELECT bundle.checkout('$bundle', true);"
  done
fi

echo "Verifying expected routes and widgets..."
psql_cmd <<'SQL'
SELECT path
FROM endpoint.resource
WHERE path IN (
    '/ai/experiments', '/ai/runs', '/companion', '/ideas',
    '/plans', '/ai/plans',
    '/blackjack', '/craps', '/magic8ball', '/office-quest', '/roulette'
)
ORDER BY path;

SELECT name
FROM widget.widget
WHERE name IN (
    'ai_experiment', 'ai_run_summary', 'ai_idea', 'companion_session_brief',
    'companion_plan_viewer',
    'craps', 'magic8ball', 'rl_game', 'bj_game', 'office_quest'
)
ORDER BY name;
SQL

echo "Custom layer bundle checkout completed."
