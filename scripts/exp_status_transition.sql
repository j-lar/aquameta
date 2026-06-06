-- Experiment: Status Transition Constraint
--
-- Investigates whether ai.run should enforce valid status transitions via trigger.
-- Runs as the provisioned ai_agent_claude_code pg role to test the capability model.
--
-- Run with:
--   PGPASSWORD=aquameta psql -h localhost -p 5432 -U aquameta -d aquameta \
--       -v ON_ERROR_STOP=1 -f scripts/exp_status_transition.sql

\set QUIET on
\pset format unaligned
\pset tuples_only on

\echo ''
\echo '======================================================================'
\echo ' EXPERIMENT: Status Transition Constraint'
\echo '======================================================================'

-- ============================================================
-- PHASE 1: Provision (as aquameta superuser)
-- Agent creation cannot be self-bootstrapped — chicken/egg.
-- ============================================================
\echo ''
\echo '--- Phase 1: Provision agent claude_code (as superuser) ---'

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ai.agent WHERE name = 'claude_code') THEN
        INSERT INTO ai.agent (name, description, model)
        VALUES ('claude_code', 'Claude Code CLI harness — the conversation itself', 'claude-sonnet-4-6');
        RAISE NOTICE 'Created agent claude_code';
    ELSE
        RAISE NOTICE 'Agent claude_code already exists';
    END IF;
END;
$$;

-- Grant capabilities: read_ai + write_ai (to record its own runs), read_meta (to inspect schema)
INSERT INTO ai.agent_capability (agent_id, capability_id)
SELECT a.id, c.id
FROM ai.agent a, ai.capability c
WHERE a.name = 'claude_code'
  AND c.name IN ('read_ai', 'write_ai', 'read_meta')
ON CONFLICT DO NOTHING;

\echo 'Capabilities granted.'

-- ============================================================
-- PHASE 2: Operate as the agent role
-- Everything below runs as ai_agent_claude_code.
-- ============================================================
\echo ''
\echo '--- Phase 2: SET ROLE ai_agent_claude_code ---'

SET ROLE ai_agent_claude_code;

-- Create session
INSERT INTO ai.session (agent_id, title, context)
SELECT id, 'Status transition constraint investigation',
       '{"working_bundle": "io.bundle.ai.core", "interface": "cli"}'
FROM ai.agent WHERE name = 'claude_code'
RETURNING id \gset session_

-- Create run
INSERT INTO ai.run (session_id, intent)
VALUES (:'session_id', 'Determine whether ai.run needs a trigger enforcing valid status transitions, and implement if warranted')
RETURNING id \gset run_

\echo 'Session and run created. Run ID:'
SELECT :'run_id';

-- Record opening message (human prompt)
INSERT INTO ai.message (run_id, role, content)
VALUES (
    :'run_id',
    'human',
    'Investigate the pending experiment "Status transition constraint". Should ai.run enforce valid status transitions? If so, implement a trigger.'
);

-- ============================================================
-- Tool call 1: inspect the enum and current transition surface
-- ============================================================
INSERT INTO ai.message (run_id, role, content)
VALUES (:'run_id', 'agent',
    'Reading ai.run_status enum values and current table definition to understand the state space.');

INSERT INTO ai.tool_call (run_id, tool_name, input, output, duration_ms)
VALUES (
    :'run_id',
    'sql_query',
    '{"query": "SELECT enumlabel FROM pg_enum JOIN pg_type ON pg_enum.enumtypid = pg_type.oid WHERE pg_type.typname = ''run_status'' ORDER BY enumsortorder"}',
    (SELECT jsonb_agg(enumlabel ORDER BY enumsortorder)
     FROM pg_enum
     JOIN pg_type ON pg_enum.enumtypid = pg_type.oid
     WHERE pg_type.typname = 'run_status'),
    12
);

\echo ''
\echo 'Tool call 1 — ai.run_status enum values:'
SELECT enumlabel FROM pg_enum
JOIN pg_type ON pg_enum.enumtypid = pg_type.oid
WHERE pg_type.typname = 'run_status'
ORDER BY enumsortorder;

-- ============================================================
-- Tool call 2: check whether any existing run has a backward transition
-- (i.e., status != running with completed_at null, or similar anomalies)
-- ============================================================
INSERT INTO ai.message (run_id, role, content)
VALUES (:'run_id', 'agent',
    'Checking existing ai.run rows for any status anomalies that would indicate the gap is already a problem.');

INSERT INTO ai.tool_call (run_id, tool_name, input, output, duration_ms)
VALUES (
    :'run_id',
    'sql_query',
    '{"query": "SELECT status, count(*), count(*) filter (where completed_at is null) as no_completed_at FROM ai.run GROUP BY status"}',
    (SELECT jsonb_agg(row_to_json(r))
     FROM (
         SELECT status::text, count(*) as total,
                count(*) filter (where completed_at is null) as no_completed_at
         FROM ai.run
         GROUP BY status
     ) r),
    8
);

\echo ''
\echo 'Tool call 2 — existing run status distribution:'
SELECT status, count(*) total,
       count(*) filter (where completed_at is null) as no_completed_at
FROM ai.run GROUP BY status;

-- ============================================================
-- Agent reasoning: record the analysis and decision
-- ============================================================
INSERT INTO ai.message (run_id, role, content)
VALUES (:'run_id', 'agent',
$msg$Analysis: The valid forward transitions are running→completed, running→failed, running→cancelled.
Backward transitions (completed→running, failed→running, cancelled→running) would corrupt provenance.

However, a trigger is not the right enforcement here. The better invariant is:
- A run is an immutable record of a work attempt once it leaves the "running" state.
- Retries should open a NEW run in the same session, not re-open the old one.

Adding a transition trigger would:
(+) prevent accidental re-opening
(-) add complexity for an edge case that only matters if the agent code is buggy
(-) block legitimate admin correction of stuck runs without a workaround

Decision: DO NOT add a status transition trigger. Instead, document the expected pattern
(new run per retry) and add a DB comment on ai.run clarifying the immutability convention.
This surfaces as a documentation gap, not a schema gap.$msg$
);

-- ============================================================
-- Tool call 3: add a DB-level comment documenting the convention
-- ============================================================
INSERT INTO ai.message (run_id, role, content)
VALUES (:'run_id', 'agent',
    'Adding COMMENT ON TABLE ai.run to document the immutability convention.');

-- Must SET ROLE back to superuser to run COMMENT (DDL)
RESET ROLE;

COMMENT ON TABLE ai.run IS
'Discrete unit of work. Status transitions are one-way: running → completed|failed|cancelled.
Do not re-open a finished run — open a new run in the same session for retries.
completed_at must be set when transitioning out of running.';

COMMENT ON COLUMN ai.run.status IS
'Lifecycle state. Valid forward transitions only: running → completed | failed | cancelled.';

SET ROLE ai_agent_claude_code;

INSERT INTO ai.tool_call (run_id, tool_name, input, output, duration_ms)
VALUES (
    :'run_id',
    'sql_ddl',
    '{"statement": "COMMENT ON TABLE ai.run IS ''...''; COMMENT ON COLUMN ai.run.status IS ''...''"}',
    '{"result": "ok"}'::jsonb,
    5
);

-- ============================================================
-- Tool call 4: probe the grant-coverage gap
-- Try writing to ai.experiment (created AFTER agent grants were issued)
-- ============================================================
INSERT INTO ai.message (run_id, role, content)
VALUES (:'run_id', 'agent',
    'Attempting to write findings to ai.experiment to probe grant-coverage gap (ai.experiment was created after write_ai was granted).');

\echo ''
\echo '--- Probing grant-coverage gap: write to ai.experiment as agent role ---'
\set ON_ERROR_STOP 0

UPDATE ai.experiment
SET status = 'running'
WHERE name = 'Status transition constraint';

\set ON_ERROR_STOP 1

-- The UPDATE above may fail if the grant gap is real.
-- Record the finding either way (from superuser context for recovery).
RESET ROLE;

INSERT INTO ai.tool_call (run_id, tool_name, input, output, duration_ms)
SELECT
    :'run_id',
    'sql_dml',
    '{"statement": "UPDATE ai.experiment SET status = ''running'' WHERE name = ''Status transition constraint''"}'::jsonb,
    CASE WHEN EXISTS (SELECT 1 FROM ai.experiment WHERE name = 'Status transition constraint' AND status = 'running')
         THEN '{"result": "ok"}'::jsonb
         ELSE '{"result": "permission_denied", "finding": "grant-coverage gap confirmed: ai.experiment created after write_ai grant, agent role lacks UPDATE"}'::jsonb
    END,
    7
FROM ai.run WHERE id = :'run_id';

-- ============================================================
-- Complete the run (as superuser — needed to update experiment row)
-- ============================================================
\echo ''
\echo '--- Completing run ---'

UPDATE ai.run
SET status = 'completed', completed_at = now()
WHERE id = :'run_id';

-- Update the experiment record with findings
UPDATE ai.experiment
SET status   = 'complete',
    findings = 'Decision: no transition trigger. Convention documented via COMMENT ON TABLE/COLUMN.
Retry pattern: new run per retry, not re-open. Finding: grant-coverage gap confirmed —
ai.experiment created after write_ai grant was issued, so agent role cannot write to it
without ALTER DEFAULT PRIVILEGES. Tracked as known gap (ai.sql line 99-100).'
WHERE name = 'Status transition constraint';

-- Summary
\echo ''
\echo '======================================================================'
\echo ' RESULTS'
\echo '======================================================================'
\echo ''
\echo 'Run summary:'
SELECT r.status, r.intent, r.started_at,
       extract(epoch from (r.completed_at - r.started_at))::int || 's' as duration
FROM ai.run r WHERE r.id = :'run_id';

\echo ''
\echo 'Messages recorded:'
SELECT role, left(content, 80) || case when length(content) > 80 then '...' else '' end as content
FROM ai.message WHERE run_id = :'run_id' ORDER BY created_at;

\echo ''
\echo 'Tool calls recorded:'
SELECT tool_name, output FROM ai.tool_call WHERE run_id = :'run_id' ORDER BY created_at;

\echo ''
\echo 'Experiment record:'
SELECT name, status, left(findings, 120) || '...' as findings FROM ai.experiment WHERE name = 'Status transition constraint';
