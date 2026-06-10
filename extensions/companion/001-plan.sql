-- companion.plan / companion.plan_step
-- Structured plan tracking for multi-agent coordination.
-- Tables ship via extension SQL (infra); rows travel in io.bundle.aquameta.plan.
--
-- Claim convention (no trigger — predicate is the contract):
--   UPDATE companion.plan_step
--   SET status = 'claimed', agent_id = $me, claimed_at = now()
--   WHERE id = $step AND status = 'pending'
--   RETURNING id;
-- Zero rows returned = already claimed. Claim via SQL only; PGFS writes are
-- unconditional and cannot compare-and-swap.


-------------------------------------------------------------------------------
-- companion.plan
-------------------------------------------------------------------------------

CREATE TABLE companion.plan (
    id          uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    title       text        NOT NULL CHECK (title <> ''),
    description text,
    status      text        NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','active','completed','abandoned')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER plan_updated_at
    BEFORE UPDATE ON companion.plan
    FOR EACH ROW EXECUTE PROCEDURE companion.set_updated_at();


-------------------------------------------------------------------------------
-- companion.plan_step
-------------------------------------------------------------------------------

CREATE TABLE companion.plan_step (
    id          uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    plan_id     uuid        NOT NULL,
    position    integer     NOT NULL CHECK (position > 0),
    title       text        NOT NULL CHECK (title <> ''),
    detail      text,
    status      text        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','claimed','running','completed','failed','skipped')),
    agent_id    uuid        REFERENCES ai.agent(id),
    claimed_at  timestamptz,
    result      text,
    experiment_id uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (plan_id, position),
    -- claimed/running steps must have agent_id and claimed_at
    CHECK (status NOT IN ('claimed','running') OR (agent_id IS NOT NULL AND claimed_at IS NOT NULL)),
    -- DEFERRABLE: plan_step rows in io.bundle.ai.core reference companion.plan rows in
    -- io.bundle.aquameta.plan, and vice versa. Both bundles must be checked out in a
    -- single transaction with SET CONSTRAINTS ALL DEFERRED to avoid circular FK failures.
    CONSTRAINT plan_step_plan_id_fkey
        FOREIGN KEY (plan_id) REFERENCES companion.plan(id) ON DELETE CASCADE
        DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT plan_step_experiment_id_fkey
        FOREIGN KEY (experiment_id) REFERENCES ai.experiment(id)
        DEFERRABLE INITIALLY IMMEDIATE
);

CREATE TRIGGER plan_step_updated_at
    BEFORE UPDATE ON companion.plan_step
    FOR EACH ROW EXECUTE PROCEDURE companion.set_updated_at();


-------------------------------------------------------------------------------
-- Extend session_brief to surface active plans
-- One row per step of any active plan, for quick orientation at session start.
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW companion.session_brief AS
    SELECT 'context'  AS type,
           key        AS title,
           value      AS body,
           updated_at
    FROM companion.context

    UNION ALL

    SELECT 'decision'                                               AS type,
           title,
           decision || coalesce(E'\nRationale: ' || rationale, '') AS body,
           decided_at                                              AS updated_at
    FROM companion.decision
    WHERE status != 'revisited'

    UNION ALL

    SELECT 'note'                    AS type,
           topic || ': ' || title   AS title,
           body,
           updated_at
    FROM companion.note

    UNION ALL

    SELECT 'plan_step'                                                      AS type,
           p.title || ' [' || p.status || '] #' || ps.position::text
               || ': ' || ps.title                                         AS title,
           coalesce(ps.detail, '')
               || CASE WHEN ps.status != 'pending'
                       THEN E'\nstatus: ' || ps.status
                       ELSE '' END                                         AS body,
           ps.updated_at
    FROM companion.plan p
    JOIN companion.plan_step ps ON ps.plan_id = p.id
    WHERE p.status = 'active'

    ORDER BY type, updated_at DESC;
