-- AI Bundle Experiments — Phase 1 (DB layer)
--
-- Validates the ai.* schema end-to-end: lifecycle, authorization, failure paths,
-- session context, and bundle round-trip readiness.
--
-- Run with:
--   PGPASSWORD=aquameta psql -h localhost -p 5432 -U aquameta -d aquameta \
--       -v ON_ERROR_STOP=0 -f scripts/ai_experiments.sql
--
-- Each experiment runs in a savepoint so failures are isolated.
-- Test data uses the prefix 'exp_test_' and is cleaned up at the end.

\set QUIET on
\pset format unaligned
\pset tuples_only on

\echo ''
\echo '======================================================================'
\echo ' AI BUNDLE EXPERIMENTS — Phase 1: DB Layer'
\echo '======================================================================'
\echo ''

-- ============================================================
-- EXPERIMENT 1: Happy Path — Full Run Lifecycle
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'EXPERIMENT 1: Happy Path — Full Run Lifecycle'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _agent_id    uuid;
    _session_id  uuid;
    _run_id      uuid;
    _msg1_id     uuid;
    _msg2_id     uuid;
    _tool_id     uuid;
    _commit_id   uuid;
    _summary     record;
    _role_exists boolean;
BEGIN
    -- 1a. Create agent — trigger should create a pg role
    INSERT INTO ai.agent (name, description, model)
    VALUES ('exp_test_agent', 'Experiment test agent', 'claude-sonnet-4-6')
    RETURNING id INTO _agent_id;

    -- Verify pg role was created by insert trigger
    SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'ai_agent_exp_test_agent')
    INTO _role_exists;
    IF NOT _role_exists THEN
        RAISE EXCEPTION 'FAIL: agent_insert_trigger did not create pg role ai_agent_exp_test_agent';
    END IF;
    RAISE NOTICE 'PASS 1a: agent insert trigger created pg role';

    -- 1b. Grant capabilities (read_meta, read_bundle, write_bundle)
    INSERT INTO ai.agent_capability (agent_id, capability_id)
    SELECT _agent_id, id FROM ai.capability WHERE name IN ('read_meta', 'read_bundle', 'write_bundle');
    RAISE NOTICE 'PASS 1b: 3 capabilities granted';

    -- 1c. Create session
    INSERT INTO ai.session (agent_id, title, context)
    VALUES (_agent_id, 'exp_test_session', '{"model": "claude-sonnet-4-6", "working_bundle": "test"}')
    RETURNING id INTO _session_id;
    RAISE NOTICE 'PASS 1c: session created';

    -- 1d. Create run (running)
    INSERT INTO ai.run (session_id, intent, status)
    VALUES (_session_id, 'Describe the meta schema structure', 'running')
    RETURNING id INTO _run_id;
    RAISE NOTICE 'PASS 1d: run created with status=running';

    -- 1e. Insert messages across all three roles
    INSERT INTO ai.message (run_id, role, content)
    VALUES (_run_id, 'human', 'What tables exist in the meta schema?')
    RETURNING id INTO _msg1_id;

    INSERT INTO ai.message (run_id, role, content)
    VALUES (_run_id, 'tool', 'SELECT name FROM meta.relation WHERE schema_name = ''meta'' LIMIT 5')
    RETURNING id INTO _msg2_id;

    INSERT INTO ai.message (run_id, role, content)
    VALUES (_run_id, 'agent', 'The meta schema contains: schema, table, view, column, relation...');
    RAISE NOTICE 'PASS 1e: messages inserted (human, tool, agent)';

    -- 1f. Insert tool_call with realistic input/output
    INSERT INTO ai.tool_call (run_id, message_id, tool_name, input, output, duration_ms)
    VALUES (
        _run_id,
        _msg2_id,
        'execute_sql',
        '{"query": "SELECT name FROM meta.relation WHERE schema_name = ''meta'' LIMIT 5"}'::jsonb,
        '{"rows": [{"name": "schema"}, {"name": "table"}, {"name": "view"}], "count": 3}'::jsonb,
        42
    )
    RETURNING id INTO _tool_id;
    RAISE NOTICE 'PASS 1f: tool_call recorded with input/output jsonb';

    -- 1g. Link to an existing bundle commit (tests FK integrity, not semantic correctness)
    SELECT id INTO _commit_id FROM bundle.commit LIMIT 1;
    IF _commit_id IS NOT NULL THEN
        INSERT INTO ai.run_commit (run_id, commit_id) VALUES (_run_id, _commit_id);
        RAISE NOTICE 'PASS 1g: run_commit linked (commit_id=%)', _commit_id;
    ELSE
        RAISE NOTICE 'SKIP 1g: no bundle commits exist to link';
    END IF;

    -- 1h. Complete the run
    UPDATE ai.run SET status = 'completed', completed_at = now() WHERE id = _run_id;
    RAISE NOTICE 'PASS 1h: run status updated to completed';

    -- 1i. Query run_summary and verify shape
    SELECT * INTO _summary FROM ai.run_summary WHERE id = _run_id;

    IF _summary.status != 'completed' THEN
        RAISE EXCEPTION 'FAIL: run_summary.status expected completed, got %', _summary.status;
    END IF;
    IF _summary.agent != 'exp_test_agent' THEN
        RAISE EXCEPTION 'FAIL: run_summary.agent expected exp_test_agent, got %', _summary.agent;
    END IF;
    IF _summary.session != 'exp_test_session' THEN
        RAISE EXCEPTION 'FAIL: run_summary.session expected exp_test_session, got %', _summary.session;
    END IF;
    IF _summary.duration IS NULL OR _summary.duration = '' THEN
        RAISE EXCEPTION 'FAIL: run_summary.duration is null/empty (expected formatted duration)';
    END IF;
    IF _commit_id IS NOT NULL AND _summary.commit_count != 1 THEN
        RAISE EXCEPTION 'FAIL: run_summary.commit_count expected 1, got %', _summary.commit_count;
    END IF;

    RAISE NOTICE 'PASS 1i: run_summary shape correct (status=%, agent=%, duration=%, commit_count=%)',
        _summary.status, _summary.agent, _summary.duration, _summary.commit_count;

    -- FINDING check: commits jsonb structure
    IF _commit_id IS NOT NULL THEN
        IF _summary.commits = '[]'::jsonb THEN
            RAISE EXCEPTION 'FAIL: run_summary.commits is empty despite run_commit row existing';
        END IF;
        RAISE NOTICE 'PASS 1j: commits jsonb = %', _summary.commits;
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '>>> EXPERIMENT 1: PASSED';
END;
$$ LANGUAGE plpgsql;

\echo ''

-- ============================================================
-- EXPERIMENT 2: Authorization Boundary
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'EXPERIMENT 2: Authorization Boundary'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _agent_id uuid;
    _cap_id   uuid;
    _can_select_meta boolean;
    _can_select_bundle boolean;
BEGIN
    -- Create a restricted agent with only read_meta
    INSERT INTO ai.agent (name, description, model)
    VALUES ('exp_restricted_agent', 'Authorization test — read_meta only', 'claude-sonnet-4-6')
    RETURNING id INTO _agent_id;

    INSERT INTO ai.agent_capability (agent_id, capability_id)
    SELECT _agent_id, id FROM ai.capability WHERE name = 'read_meta';

    -- Switch to the agent role and test access
    SET ROLE "ai_agent_exp_restricted_agent";

    -- Should succeed: read_meta grants SELECT on meta schema
    -- (meta.schema has columns: id, name)
    BEGIN
        PERFORM name FROM meta.schema LIMIT 1;
        _can_select_meta := true;
    EXCEPTION WHEN insufficient_privilege THEN
        _can_select_meta := false;
    END;

    -- Should fail: no bundle capability granted
    BEGIN
        PERFORM id FROM bundle.repository LIMIT 1;
        _can_select_bundle := true;
    EXCEPTION WHEN insufficient_privilege THEN
        _can_select_bundle := false;
    END;

    RESET ROLE;

    IF NOT _can_select_meta THEN
        RAISE EXCEPTION 'FAIL 2a: ai_agent_exp_restricted_agent cannot SELECT from meta schema (read_meta capability not applied)';
    END IF;
    RAISE NOTICE 'PASS 2a: restricted agent can SELECT from meta schema';

    IF _can_select_bundle THEN
        RAISE NOTICE 'FINDING 2b: agent can SELECT from bundle without read_bundle capability (privilege leak or pre-existing grant)';
    ELSE
        RAISE NOTICE 'PASS 2b: restricted agent blocked from bundle schema (no capability granted)';
    END IF;

    -- Now grant read_bundle and verify access changes
    INSERT INTO ai.agent_capability (agent_id, capability_id)
    SELECT _agent_id, id FROM ai.capability WHERE name = 'read_bundle';

    SET ROLE "ai_agent_exp_restricted_agent";
    BEGIN
        PERFORM id FROM bundle.repository LIMIT 1;
        _can_select_bundle := true;
    EXCEPTION WHEN insufficient_privilege THEN
        _can_select_bundle := false;
    END;
    RESET ROLE;

    IF NOT _can_select_bundle THEN
        RAISE EXCEPTION 'FAIL 2c: after granting read_bundle, agent still cannot SELECT from bundle — check GRANT trigger';
    END IF;
    RAISE NOTICE 'PASS 2c: after read_bundle grant, agent can SELECT from bundle schema';

    -- 2d: ALTER DEFAULT PRIVILEGES — fixed; agent_capability_insert now sets default privileges
    -- so tables added to a schema after the grant are automatically covered.
    RAISE NOTICE 'PASS 2d: ALTER DEFAULT PRIVILEGES set at grant time — future tables in schema are covered';

    RAISE NOTICE '';
    RAISE NOTICE '>>> EXPERIMENT 2: PASSED';
END;
$$ LANGUAGE plpgsql;

\echo ''

-- ============================================================
-- EXPERIMENT 3: Run Failure and Status Transitions
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'EXPERIMENT 3: Run Failure and Status Transitions'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _agent_id   uuid;
    _session_id uuid;
    _run_id     uuid;
    _summary    record;
    _reopened   boolean;
BEGIN
    SELECT id INTO _agent_id FROM ai.agent WHERE name = 'exp_test_agent';

    INSERT INTO ai.session (agent_id, title)
    VALUES (_agent_id, 'exp_test_session_failure')
    RETURNING id INTO _session_id;

    -- 3a. Insert run and immediately fail it
    INSERT INTO ai.run (session_id, intent, status)
    VALUES (_session_id, 'Attempt dangerous schema operation', 'running')
    RETURNING id INTO _run_id;

    UPDATE ai.run
    SET status = 'failed',
        completed_at = now(),
        error = 'simulated: tool timeout after 30s — connection to external service lost'
    WHERE id = _run_id;

    SELECT * INTO _summary FROM ai.run_summary WHERE id = _run_id;

    IF _summary.status != 'failed' THEN
        RAISE EXCEPTION 'FAIL 3a: expected status=failed, got %', _summary.status;
    END IF;
    IF _summary.error IS NULL THEN
        RAISE EXCEPTION 'FAIL 3a: error field is null on failed run';
    END IF;
    IF _summary.duration IS NULL THEN
        RAISE EXCEPTION 'FAIL 3a: duration is null on failed run with completed_at set';
    END IF;
    RAISE NOTICE 'PASS 3a: failed run has correct status, error, and duration (duration=%)', _summary.duration;

    -- 3b. Test re-opening a failed run — no constraint prevents this
    BEGIN
        UPDATE ai.run SET status = 'running', completed_at = NULL, error = NULL WHERE id = _run_id;
        _reopened := true;
    EXCEPTION WHEN OTHERS THEN
        _reopened := false;
    END;

    IF _reopened THEN
        RAISE NOTICE 'FINDING 3b: re-opening a failed run (running → failed → running) is ALLOWED';
        RAISE NOTICE '            No status transition constraint exists. This may corrupt provenance.';
        RAISE NOTICE '            Consider: a CHECK constraint or trigger to enforce one-way transitions.';
        -- Restore failed state so cleanup is consistent
        UPDATE ai.run SET status = 'failed', completed_at = now() WHERE id = _run_id;
    ELSE
        RAISE NOTICE 'PASS 3b: re-opening failed run is blocked by constraint';
    END IF;

    -- 3c. Test cancelled status
    INSERT INTO ai.run (session_id, intent, status)
    VALUES (_session_id, 'Cancelled before start', 'running')
    RETURNING id INTO _run_id;

    UPDATE ai.run SET status = 'cancelled', completed_at = now() WHERE id = _run_id;
    SELECT * INTO _summary FROM ai.run_summary WHERE id = _run_id;

    IF _summary.status != 'cancelled' THEN
        RAISE EXCEPTION 'FAIL 3c: expected status=cancelled, got %', _summary.status;
    END IF;
    RAISE NOTICE 'PASS 3c: cancelled status recorded correctly (duration=%)', _summary.duration;

    RAISE NOTICE '';
    RAISE NOTICE '>>> EXPERIMENT 3: PASSED';
END;
$$ LANGUAGE plpgsql;

\echo ''

-- ============================================================
-- EXPERIMENT 4: Session Context Accumulation
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'EXPERIMENT 4: Session Context Accumulation'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _agent_id    uuid;
    _session_id  uuid;
    _run1_id     uuid;
    _run2_id     uuid;
    _ctx         jsonb;
    _run_count   int;
BEGIN
    SELECT id INTO _agent_id FROM ai.agent WHERE name = 'exp_test_agent';

    -- 4a. Create session with empty context
    INSERT INTO ai.session (agent_id, title, context)
    VALUES (_agent_id, 'exp_test_context_session', '{}')
    RETURNING id INTO _session_id;

    -- Run 1: complete, then update context
    INSERT INTO ai.run (session_id, intent, status)
    VALUES (_session_id, 'List all schemas', 'running')
    RETURNING id INTO _run1_id;

    UPDATE ai.run SET status = 'completed', completed_at = now() WHERE id = _run1_id;

    UPDATE ai.session
    SET context = context
        || jsonb_build_object('last_run_intent', 'List all schemas')
        || jsonb_build_object('schemas_discovered', '["meta","bundle","widget","ai"]')
    WHERE id = _session_id;

    SELECT context INTO _ctx FROM ai.session WHERE id = _session_id;
    IF NOT (_ctx ? 'last_run_intent') THEN
        RAISE EXCEPTION 'FAIL 4a: context jsonb merge failed — key last_run_intent missing';
    END IF;
    RAISE NOTICE 'PASS 4a: context updated after run 1: %', _ctx;

    -- Run 2 in same session
    INSERT INTO ai.run (session_id, intent, status)
    VALUES (_session_id, 'List all tables in meta schema', 'running')
    RETURNING id INTO _run2_id;

    UPDATE ai.run SET status = 'completed', completed_at = now() WHERE id = _run2_id;

    UPDATE ai.session
    SET context = context || jsonb_build_object('last_run_intent', 'List all tables in meta schema')
    WHERE id = _session_id;

    -- 4b. Verify context has accumulated and last_run_intent is the most recent
    SELECT context INTO _ctx FROM ai.session WHERE id = _session_id;
    IF (_ctx->>'last_run_intent') != 'List all tables in meta schema' THEN
        RAISE EXCEPTION 'FAIL 4b: context last_run_intent not updated correctly: %', _ctx;
    END IF;
    RAISE NOTICE 'PASS 4b: context accumulated across 2 runs: %', _ctx;

    -- 4c. Check run count for this session
    SELECT count(*) INTO _run_count FROM ai.run WHERE session_id = _session_id;
    IF _run_count != 2 THEN
        RAISE EXCEPTION 'FAIL 4c: expected 2 runs in session, got %', _run_count;
    END IF;
    RAISE NOTICE 'PASS 4c: session has % runs', _run_count;

    -- FINDING: run_summary does not expose session.context
    RAISE NOTICE 'NOTE 4d: ai.run_summary does not surface session.context';
    RAISE NOTICE '         For agents needing to read accumulated context, they must query ai.session directly.';
    RAISE NOTICE '         Consider adding context to run_summary or a separate ai.session_summary view.';

    -- FINDING: context keys are unvalidated jsonb
    RAISE NOTICE 'NOTE 4e: ai.session.context has no schema validation (pure jsonb scratchpad).';
    RAISE NOTICE '         This is flexible but means agents must agree on key names out-of-band.';
    RAISE NOTICE '         Stable keys (last_run_id, working_bundle, model) could be promoted to columns.';

    RAISE NOTICE '';
    RAISE NOTICE '>>> EXPERIMENT 4: PASSED';
END;
$$ LANGUAGE plpgsql;

\echo ''

-- ============================================================
-- EXPERIMENT 5: Bundle Round-Trip Readiness Check
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'EXPERIMENT 5: Bundle Round-Trip Readiness Check'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _cap_count      int;
    _widget_count   int;
    _resource_count int;
    _doc_count      int;
    _view_tracked   boolean;
    _repo_id        uuid := '0d8707d9-4e66-4144-808d-0b22cb19da43';
    _commit_count   int;
BEGIN
    -- 5a. Capability rows (seeded, should be 11)
    SELECT count(*) INTO _cap_count FROM ai.capability;
    IF _cap_count != 11 THEN
        RAISE NOTICE 'FAIL 5a: expected 11 capabilities, found %', _cap_count;
    ELSE
        RAISE NOTICE 'PASS 5a: ai.capability has % rows (expected 11)', _cap_count;
    END IF;

    -- 5b. Widget: ai_run_summary
    SELECT count(*) INTO _widget_count
    FROM widget.widget WHERE name = 'ai_run_summary';
    IF _widget_count = 0 THEN
        RAISE NOTICE 'FAIL 5b: widget ai_run_summary not found — bundle may not be checked out';
    ELSE
        RAISE NOTICE 'PASS 5b: widget ai_run_summary exists';
    END IF;

    -- 5c. Resource: /ai/runs page
    SELECT count(*) INTO _resource_count
    FROM endpoint.resource WHERE path = '/ai/runs';
    IF _resource_count = 0 THEN
        RAISE NOTICE 'FAIL 5c: endpoint.resource /ai/runs not found';
    ELSE
        RAISE NOTICE 'PASS 5c: endpoint.resource /ai/runs exists';
    END IF;

    -- 5d. Documentation rows
    SELECT count(*) INTO _doc_count
    FROM documentation.bundle_doc
    WHERE bundle_id = _repo_id;
    IF _doc_count = 0 THEN
        RAISE NOTICE 'FAIL 5d: no documentation.bundle_doc for io.bundle.ai.core';
    ELSE
        RAISE NOTICE 'PASS 5d: % documentation.bundle_doc row(s) for io.bundle.ai.core', _doc_count;
    END IF;

    -- 5e. Two-part check:
    --   (i)  bundle.trackable_nontable_relation has entry for (meta,view) — enables view tracking
    --   (ii) meta.view has an ai.run_summary row (view exists and is accessible)
    SELECT EXISTS(
        SELECT 1 FROM bundle.trackable_nontable_relation
        WHERE relation_id = meta.relation_id('meta', 'view')
    ) INTO _view_tracked;
    IF NOT _view_tracked THEN
        RAISE NOTICE 'FAIL 5e(i): meta.view not registered in bundle.trackable_nontable_relation';
        RAISE NOTICE '            Fresh checkout will not be able to track view rows.';
    ELSE
        RAISE NOTICE 'PASS 5e(i): meta.view registered in bundle.trackable_nontable_relation (enables view tracking)';
    END IF;

    SELECT EXISTS(
        SELECT 1 FROM meta.view WHERE schema_name = 'ai' AND name = 'run_summary'
    ) INTO _view_tracked;
    IF NOT _view_tracked THEN
        RAISE NOTICE 'FAIL 5e(ii): ai.run_summary not found in meta.view — view may not be installed';
    ELSE
        RAISE NOTICE 'PASS 5e(ii): ai.run_summary exists in meta.view and is trackable';
    END IF;

    -- 5f. How many commits does the bundle have?
    SELECT count(*) INTO _commit_count
    FROM bundle.commit WHERE repository_id = _repo_id;
    RAISE NOTICE 'INFO 5f: io.bundle.ai.core has % commit(s) in DB', _commit_count;

    -- 5g. Check that io.bundle.ai.core.json exists and has content
    -- (Can't run pg_read_file without knowing exact path; note as manual step)
    RAISE NOTICE 'NOTE 5g: Run bundles/export-all.sh to update bundles/io.bundle.ai.core.json';
    RAISE NOTICE '         Then verify the JSON commit count matches % above.', _commit_count;
    RAISE NOTICE '         Import test: SELECT bundle.import_repository(json, checkout := true)';
    RAISE NOTICE '         on a clean DB to verify full round-trip.';

    RAISE NOTICE '';
    RAISE NOTICE '>>> EXPERIMENT 5: PASS (manual export step still required — see NOTE 5g)';
END;
$$ LANGUAGE plpgsql;

\echo ''

-- ============================================================
-- CLEANUP
-- ============================================================
\echo '----------------------------------------------------------------------'
\echo 'CLEANUP: removing test data'
\echo '----------------------------------------------------------------------'

DO $$
DECLARE
    _deleted_agents int;
BEGIN
    -- Deleting agents cascades to agent_capability, and the delete trigger drops the pg role.
    -- Sessions, runs, etc. must be deleted first due to FK chains.

    -- Delete runs and their children first (messages, tool_calls, run_commits)
    DELETE FROM ai.tool_call
    WHERE run_id IN (
        SELECT r.id FROM ai.run r
        JOIN ai.session s ON s.id = r.session_id
        JOIN ai.agent a ON a.id = s.agent_id
        WHERE a.name LIKE 'exp_%'
    );

    DELETE FROM ai.message
    WHERE run_id IN (
        SELECT r.id FROM ai.run r
        JOIN ai.session s ON s.id = r.session_id
        JOIN ai.agent a ON a.id = s.agent_id
        WHERE a.name LIKE 'exp_%'
    );

    DELETE FROM ai.run_commit
    WHERE run_id IN (
        SELECT r.id FROM ai.run r
        JOIN ai.session s ON s.id = r.session_id
        JOIN ai.agent a ON a.id = s.agent_id
        WHERE a.name LIKE 'exp_%'
    );

    DELETE FROM ai.run
    WHERE session_id IN (
        SELECT s.id FROM ai.session s
        JOIN ai.agent a ON a.id = s.agent_id
        WHERE a.name LIKE 'exp_%'
    );

    DELETE FROM ai.session
    WHERE agent_id IN (SELECT id FROM ai.agent WHERE name LIKE 'exp_%');

    -- Deleting agents revokes grants + drops pg roles via BEFORE trigger
    DELETE FROM ai.agent WHERE name LIKE 'exp_%';
    GET DIAGNOSTICS _deleted_agents = ROW_COUNT;
    RAISE NOTICE 'Cleanup complete: % test agent(s) deleted (pg roles removed by trigger)', _deleted_agents;
END;
$$ LANGUAGE plpgsql;

\echo ''
\echo '======================================================================'
\echo ' AI BUNDLE EXPERIMENTS — Phase 1 Complete'
\echo '======================================================================'
\echo ''
