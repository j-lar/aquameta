-- ai run binding
-- Active run tracking via a persistent binding row (not a GUC).
-- Keyed by current_user (the agent's PostgreSQL role), so it survives
-- connection reuse, discrete psql -f calls, and is visible to all four
-- Aquameta interfaces (psql, REST, PGFS, IDE).
--
-- Protocol for agents:
--   SET ROLE ai_agent_<name>;
--   SELECT ai.open_session('optional title');   -- lazy: only when doing Aquameta work
--   SELECT ai.open_run('intent description');   -- once per task
--   ... do work, call bundle.commit() ...
--   SELECT ai.close_run();
--   SELECT ai.close_session();                  -- when conversation ends
--
-- bundle.commit() records ai.run_commit automatically when a run is bound.
-- Without a bound run it emits a NOTICE (soft enforcement) and commits anyway.


-------------------------------------------------------------------------------
-- ai.active_run
-- One row per agent role currently doing Aquameta work.
-- binding_key = current_user = the agent's PostgreSQL role name.
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ai.active_run (
    binding_key  text        NOT NULL PRIMARY KEY,
    session_id   uuid        REFERENCES ai.session(id),
    run_id       uuid        REFERENCES ai.run(id),
    bound_at     timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON ai.active_run TO ai_agent_claude_code;
GRANT SELECT, INSERT, UPDATE, DELETE ON ai.active_run TO ai_agent_dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA ai GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ai_agent_claude_code;
ALTER DEFAULT PRIVILEGES IN SCHEMA ai GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ai_agent_dev;

-- Bundle schema access for agent roles
GRANT USAGE ON SCHEMA bundle TO ai_agent_claude_code;
GRANT USAGE ON SCHEMA bundle TO ai_agent_dev;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bundle TO ai_agent_claude_code;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bundle TO ai_agent_dev;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA bundle TO ai_agent_claude_code;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA bundle TO ai_agent_dev;

-- Companion schema access
GRANT USAGE ON SCHEMA companion TO ai_agent_claude_code;
GRANT USAGE ON SCHEMA companion TO ai_agent_dev;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA companion TO ai_agent_claude_code;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA companion TO ai_agent_dev;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA companion TO ai_agent_claude_code;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA companion TO ai_agent_dev;

-- Meta schema (needed for bundle operations)
GRANT USAGE ON SCHEMA meta TO ai_agent_claude_code;
GRANT USAGE ON SCHEMA meta TO ai_agent_dev;
GRANT SELECT ON ALL TABLES IN SCHEMA meta TO ai_agent_claude_code;
GRANT SELECT ON ALL TABLES IN SCHEMA meta TO ai_agent_dev;


-------------------------------------------------------------------------------
-- ai.open_session(title)
-- Creates an ai.session row and binds it to the current agent role.
-- Derives agent name by stripping the 'ai_agent_' prefix from current_user.
-- Call lazily — only when Aquameta work is about to begin.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ai.open_session(title text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    _agent_name text;
    _agent_id   uuid;
    _session_id uuid;
BEGIN
    IF current_user LIKE 'ai_agent_%' THEN
        _agent_name := substring(current_user FROM 10);
    ELSE
        RAISE EXCEPTION
            'open_session() requires SET ROLE to an ai_agent_* role first. '
            'Current role: %. Example: SET ROLE ai_agent_claude_code', current_user;
    END IF;

    SELECT id INTO _agent_id FROM ai.agent WHERE name = _agent_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No ai.agent row for name %. '
            'Register with: INSERT INTO ai.agent (name) VALUES (%)', _agent_name, _agent_name;
    END IF;

    INSERT INTO ai.session (agent_id, title, started_at)
    VALUES (
        _agent_id,
        coalesce(title, 'session ' || to_char(now(), 'YYYY-MM-DD')),
        now()
    )
    RETURNING id INTO _session_id;

    INSERT INTO ai.active_run (binding_key, session_id, run_id, bound_at)
    VALUES (current_user, _session_id, NULL, now())
    ON CONFLICT (binding_key) DO UPDATE
        SET session_id = _session_id,
            run_id     = NULL,
            bound_at   = now();

    RETURN _session_id;
END;
$$;

GRANT EXECUTE ON FUNCTION ai.open_session(text) TO ai_agent_claude_code;
GRANT EXECUTE ON FUNCTION ai.open_session(text) TO ai_agent_dev;


-------------------------------------------------------------------------------
-- ai.open_run(intent)
-- Creates an ai.run row under the current session and binds it.
-- Requires an active session (open_session must have been called first).
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ai.open_run(intent text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    _session_id uuid;
    _run_id     uuid;
BEGIN
    SELECT session_id INTO _session_id
    FROM ai.active_run
    WHERE binding_key = current_user;

    IF NOT FOUND OR _session_id IS NULL THEN
        RAISE EXCEPTION
            'No active session for %. Call ai.open_session() before ai.open_run().', current_user;
    END IF;

    INSERT INTO ai.run (session_id, intent, status, started_at)
    VALUES (_session_id, intent, 'running', now())
    RETURNING id INTO _run_id;

    UPDATE ai.active_run
    SET run_id = _run_id
    WHERE binding_key = current_user;

    RETURN _run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION ai.open_run(text) TO ai_agent_claude_code;
GRANT EXECUTE ON FUNCTION ai.open_run(text) TO ai_agent_dev;


-------------------------------------------------------------------------------
-- ai.close_run(final_status)
-- Marks the current run complete and unbinds it (session stays open).
-- Default status: 'complete'. Use 'cancelled' for interrupted runs.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ai.close_run(final_status text DEFAULT 'completed')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    _run_id uuid;
BEGIN
    SELECT run_id INTO _run_id
    FROM ai.active_run
    WHERE binding_key = current_user;

    IF _run_id IS NULL THEN
        RAISE NOTICE 'close_run(): no active run for %, nothing to close', current_user;
        RETURN;
    END IF;

    UPDATE ai.run
    SET status       = final_status::ai.run_status,
        completed_at = now()
    WHERE id = _run_id;

    UPDATE ai.active_run SET run_id = NULL WHERE binding_key = current_user;
END;
$$;

GRANT EXECUTE ON FUNCTION ai.close_run(text) TO ai_agent_claude_code;
GRANT EXECUTE ON FUNCTION ai.close_run(text) TO ai_agent_dev;


-------------------------------------------------------------------------------
-- ai.close_session()
-- Marks the current session ended and removes the binding row entirely.
-- Closes any open run first (as 'cancelled') to avoid orphaned running rows.
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION ai.close_session()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    _session_id uuid;
    _run_id     uuid;
BEGIN
    SELECT session_id, run_id INTO _session_id, _run_id
    FROM ai.active_run
    WHERE binding_key = current_user;

    IF NOT FOUND OR _session_id IS NULL THEN
        RAISE NOTICE 'close_session(): no active session for %, nothing to close', current_user;
        RETURN;
    END IF;

    IF _run_id IS NOT NULL THEN
        UPDATE ai.run
        SET status = 'cancelled', completed_at = now()
        WHERE id = _run_id;
    END IF;

    UPDATE ai.session SET ended_at = now() WHERE id = _session_id;
    DELETE FROM ai.active_run WHERE binding_key = current_user;
END;
$$;

GRANT EXECUTE ON FUNCTION ai.close_session() TO ai_agent_claude_code;
GRANT EXECUTE ON FUNCTION ai.close_session() TO ai_agent_dev;


-------------------------------------------------------------------------------
-- bundle.commit() — add ai.run_commit attribution
-- Wraps bundle._commit() with a lookup of ai.active_run for the current
-- current_user. If a run is bound, records ai.run_commit automatically.
-- If no run is bound and current_user is not a privileged role, emits a
-- NOTICE (soft enforcement). Tighten to RAISE EXCEPTION once workflow is proven.
--
-- Degrades gracefully if ai schema is not installed (catches undefined_table).
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bundle.commit(
    repository_name text,
    message         text,
    author_name     text,
    author_email    text,
    parent_commit_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
    new_commit_id  uuid;
    active_run_id  uuid;
BEGIN
    IF NOT bundle.repository_exists(repository_name) THEN
        RAISE EXCEPTION 'Repository with name % does not exist', repository_name;
    END IF;

    -- Look up active run binding. Degrade gracefully if ai schema absent.
    BEGIN
        SELECT run_id INTO active_run_id
        FROM ai.active_run
        WHERE binding_key = current_user AND run_id IS NOT NULL;
    EXCEPTION WHEN undefined_table THEN
        active_run_id := NULL;
    END;

    -- Soft enforcement: warn when committing without a bound run (non-privileged roles only)
    IF active_run_id IS NULL AND current_user NOT IN ('aquameta', 'postgres') THEN
        RAISE NOTICE
            'bundle.commit(): no active ai.run for current_user %. '
            'Attribution will not be recorded. '
            'Call SET ROLE ai_agent_<name>; SELECT ai.open_session(); SELECT ai.open_run(''intent'');',
            current_user;
    END IF;

    new_commit_id := bundle._commit(
        bundle.repository_id(repository_name),
        message,
        author_name,
        author_email,
        parent_commit_id
    );

    -- Record attribution when a run is bound
    IF active_run_id IS NOT NULL THEN
        INSERT INTO ai.run_commit (run_id, commit_id)
        VALUES (active_run_id, new_commit_id)
        ON CONFLICT (run_id, commit_id) DO NOTHING;
    END IF;

    RETURN new_commit_id;
END;
$$;
