/*******************************************************************************
 * AI
 * Agentic substrate for Aquameta
 *
 * An agent is a PostgreSQL role with named capabilities (schema-level grants).
 * Sessions are conversational containers; runs are discrete work units that
 * track intent separately from action. All entities are bundle-tracked rows.
 *
 * Copyright (c) 2026 - Aquameta - http://aquameta.org/
 ******************************************************************************/

create schema ai;


/*******************************************************************************
 * ai.agent
 *
 * An agent is an identity with a corresponding PostgreSQL role.
 * INSERT creates the pg role via meta.role (DDL as DML).
 * DELETE drops it.
 ******************************************************************************/

create table ai.agent (
    id          uuid not null default public.uuid_generate_v4() primary key,
    name        text not null unique,
    description text,
    model       text not null default 'claude-sonnet-4-6',
    created_at  timestamptz not null default now()
);

create or replace function ai.agent_insert() returns trigger as $$
begin
    -- create a pg role for this agent; role name is prefixed to avoid conflicts
    insert into meta.role (name, can_login, inherit)
    values ('ai_agent_' || NEW.name, true, true);
    return NEW;
end;
$$ language plpgsql;

create trigger agent_insert_trigger
    after insert on ai.agent
    for each row execute procedure ai.agent_insert();

create or replace function ai.agent_delete() returns trigger as $$
declare
    _role_name text;
    _cap       record;
begin
    _role_name := 'ai_agent_' || OLD.name;

    -- Revoke all schema access before dropping the role.
    -- Must run BEFORE the CASCADE deletes agent_capability rows, which is why
    -- this is a BEFORE trigger — CASCADE fires after BEFORE triggers complete.
    for _cap in
        select distinct c.schema_name, c.privilege
        from ai.agent_capability ac
        join ai.capability c on c.id = ac.capability_id
        where ac.agent_id = OLD.id
    loop
        execute format('alter default privileges in schema %I revoke %s on tables from %I',
            _cap.schema_name, _cap.privilege, _role_name);
        execute format('revoke %s on all tables in schema %I from %I',
            _cap.privilege, _cap.schema_name, _role_name);
        execute format('revoke usage on schema %I from %I', _cap.schema_name, _role_name);
    end loop;

    delete from meta.role where name = _role_name;
    return OLD;
end;
$$ language plpgsql;

create trigger agent_delete_trigger
    before delete on ai.agent
    for each row execute procedure ai.agent_delete();


/*******************************************************************************
 * ai.capability
 *
 * A named schema-level permission.
 * privilege is a SQL privilege keyword: SELECT, INSERT, UPDATE, DELETE, ALL.
 * Capabilities are defined once and granted to many agents.
 ******************************************************************************/

create table ai.capability (
    id          uuid not null default public.uuid_generate_v4() primary key,
    name        text not null unique,
    description text,
    schema_name text not null,
    privilege   text not null  -- SELECT | INSERT | UPDATE | DELETE | ALL
);


/*******************************************************************************
 * ai.agent_capability
 *
 * Grants a capability to an agent.
 * INSERT fires GRANT privilege ON ALL TABLES IN SCHEMA to the agent's pg role,
 * plus ALTER DEFAULT PRIVILEGES so tables added to the schema later are covered.
 * DELETE fires the corresponding REVOKEs.
 *
 * Trust boundary: the schema is the unit of agent access. If a schema needs
 * both agent-visible and agent-restricted tables, split it into two schemas.
 ******************************************************************************/

create table ai.agent_capability (
    id            uuid not null default public.uuid_generate_v4() primary key,
    agent_id      uuid not null references ai.agent(id) on delete cascade,
    capability_id uuid not null references ai.capability(id) on delete cascade,
    granted_at    timestamptz not null default now(),
    unique (agent_id, capability_id)
);

create or replace function ai.agent_capability_insert() returns trigger as $$
declare
    _agent_name text;
    _schema_name text;
    _privilege  text;
    _role_name  text;
begin
    select a.name, c.schema_name, c.privilege
    into _agent_name, _schema_name, _privilege
    from ai.agent a join ai.capability c on true
    where a.id = NEW.agent_id and c.id = NEW.capability_id;

    _role_name := 'ai_agent_' || _agent_name;

    execute format('grant usage on schema %I to %I', _schema_name, _role_name);
    execute format('grant %s on all tables in schema %I to %I',
        _privilege, _schema_name, _role_name);
    execute format('alter default privileges in schema %I grant %s on tables to %I',
        _schema_name, _privilege, _role_name);
    return NEW;
end;
$$ language plpgsql;

create trigger agent_capability_insert_trigger
    after insert on ai.agent_capability
    for each row execute procedure ai.agent_capability_insert();

create or replace function ai.agent_capability_delete() returns trigger as $$
declare
    _agent_name  text;
    _schema_name text;
    _privilege   text;
    _role_name   text;
    _remaining   int;
begin
    select a.name, c.schema_name, c.privilege
    into _agent_name, _schema_name, _privilege
    from ai.agent a join ai.capability c on true
    where a.id = OLD.agent_id and c.id = OLD.capability_id;

    -- Agent may already be deleted (CASCADE from agent delete).
    -- Skip REVOKE in that case — the role itself will be dropped by agent_delete_trigger.
    if not found then
        return OLD;
    end if;

    _role_name := 'ai_agent_' || _agent_name;

    execute format('alter default privileges in schema %I revoke %s on tables from %I',
        _schema_name, _privilege, _role_name);
    execute format('revoke %s on all tables in schema %I from %I',
        _privilege, _schema_name, _role_name);

    -- If this was the last capability for this schema, also revoke schema USAGE.
    -- Without this, DROP ROLE fails because the role still holds schema-level privileges.
    -- NOTE: in AFTER DELETE trigger, OLD.id is already gone from the table.
    select count(*) into _remaining
    from ai.agent_capability ac
    join ai.capability c on c.id = ac.capability_id
    where ac.agent_id = OLD.agent_id
      and c.schema_name = _schema_name;

    if _remaining = 0 then
        execute format('revoke usage on schema %I from %I', _schema_name, _role_name);
    end if;

    return OLD;
end;
$$ language plpgsql;

create trigger agent_capability_delete_trigger
    after delete on ai.agent_capability
    for each row execute procedure ai.agent_capability_delete();


/*******************************************************************************
 * Standard capabilities
 *
 * Defined here so they exist on fresh install. Agents receive capabilities
 * by inserting into ai.agent_capability.
 ******************************************************************************/

insert into ai.capability (name, description, schema_name, privilege) values
    ('read_meta',       'Read schema catalog',           'meta',      'SELECT'),
    ('read_bundle',     'Read version control data',     'bundle',    'SELECT'),
    ('write_bundle',    'Commit and manage bundles',     'bundle',    'ALL'),
    ('read_widget',     'Read widget definitions',       'widget',    'SELECT'),
    ('write_widget',    'Create and modify widgets',     'widget',    'ALL'),
    ('read_endpoint',   'Read endpoint routes/resources','endpoint',  'SELECT'),
    ('write_endpoint',  'Manage endpoint routes',        'endpoint',  'ALL'),
    ('read_semantics',  'Read semantic annotations',     'semantics', 'SELECT'),
    ('write_semantics', 'Write semantic annotations',    'semantics', 'ALL'),
    ('read_ai',         'Read agent/session data',       'ai',        'SELECT'),
    ('write_ai',        'Write agent/session data',      'ai',        'ALL'),
    ('read_companion',  'Read companion session data',   'companion', 'SELECT'),
    ('write_companion', 'Write companion session data',  'companion', 'ALL');


/*******************************************************************************
 * ai.session
 *
 * Conversational context container. One agent, many runs.
 * title and context are mutable — agents can update their own session state.
 *
 * Established context keys (jsonb scratchpad, all optional):
 *   working_bundle      text   — active bundle name for commits this session
 *   interface           text   — how the agent is running: 'cli' | 'pgfs'
 *   environment         text   — host context, e.g. 'lxc+fuse'
 *   claude_code_version text   — model/harness version string
 ******************************************************************************/

create table ai.session (
    id         uuid not null default public.uuid_generate_v4() primary key,
    agent_id   uuid not null references ai.agent(id),
    title      text,
    context    jsonb not null default '{}',
    started_at timestamptz not null default now(),
    ended_at   timestamptz
);


/*******************************************************************************
 * ai.run
 *
 * Discrete unit of work within a session.
 *
 * intent  = what was asked (the "why")
 * status  = lifecycle state
 * error   = populated on failure
 *
 * What the run actually did lives in ai.tool_call (actions taken) and
 * ai.run_commit (substrate changes produced).
 ******************************************************************************/

create type ai.run_status as enum ('running', 'completed', 'failed', 'cancelled');

create table ai.run (
    id           uuid not null default public.uuid_generate_v4() primary key,
    session_id   uuid not null references ai.session(id),
    intent       text not null,
    status       ai.run_status not null default 'running',
    started_at   timestamptz not null default now(),
    completed_at timestamptz,
    error        text
);


/*******************************************************************************
 * ai.message
 *
 * Individual turns within a run. role distinguishes speaker.
 ******************************************************************************/

create type ai.message_role as enum ('human', 'agent', 'tool');

create table ai.message (
    id         uuid not null default public.uuid_generate_v4() primary key,
    run_id     uuid not null references ai.run(id),
    role       ai.message_role not null,
    content    text not null,
    created_at timestamptz not null default now()
);


/*******************************************************************************
 * ai.tool_call
 *
 * Individual tool invocations within a run — the "action" layer.
 * input/output are jsonb so any tool schema is representable.
 * duration_ms is wall time for the call.
 ******************************************************************************/

create table ai.tool_call (
    id          uuid not null default public.uuid_generate_v4() primary key,
    run_id      uuid not null references ai.run(id),
    message_id  uuid references ai.message(id),
    tool_name   text not null,
    input       jsonb not null default '{}',
    output      jsonb,
    created_at  timestamptz not null default now(),
    duration_ms integer
);


/*******************************************************************************
 * ai.run_commit
 *
 * Links a run to the bundle commits it produced.
 * "What did this run actually change in the substrate?"
 *
 * One run → many commits (iterative work).
 * One commit → one run (a commit has a clear cause).
 ******************************************************************************/

create table ai.run_commit (
    id        uuid not null default public.uuid_generate_v4() primary key,
    run_id    uuid not null references ai.run(id),
    commit_id uuid not null references bundle.commit(id),
    unique (run_id, commit_id)
);


/*******************************************************************************
 * ai.experiment — log and queue of experiments run against the ai schema
 *
 * status values: pending | complete | deferred | abandoned
 * findings: null until the experiment completes; free text
 ******************************************************************************/

create table ai.experiment (
    id          uuid not null default public.uuid_generate_v4() primary key,
    name        text not null,
    description text,
    status      text not null default 'pending'
                     check (status in ('pending', 'complete', 'deferred', 'abandoned')),
    findings    text,
    created_at  timestamptz not null default now()
);


/*******************************************************************************
 * ai.outbox
 *
 * Ephemeral dispatch queue for the NOTIFY-based run queue.
 * Producer inserts a row; trigger fires pg_notify('ai_run_pending', run_id).
 * Consumer calls ai.claim_next_run() which atomically deletes and returns run_id.
 * Rows are deleted on claim — outbox is transient, ai.run is the durable record.
 ******************************************************************************/

create table ai.outbox (
    id         uuid        not null default public.uuid_generate_v4() primary key,
    run_id     uuid        not null references ai.run(id),
    created_at timestamptz not null default now()
);

create or replace function ai.notify_outbox_insert() returns trigger as $$
begin
    perform pg_notify('ai_run_pending', NEW.run_id::text);
    return NEW;
end;
$$ language plpgsql;

create trigger ai_outbox_notify
    after insert on ai.outbox
    for each row execute function ai.notify_outbox_insert();

-- Atomically claims the oldest pending run: deletes the outbox row, returns run_id.
-- FOR UPDATE SKIP LOCKED is safe under concurrent consumers.
create or replace function ai.claim_next_run() returns uuid as $$
    delete from ai.outbox
    where id = (
        select id from ai.outbox
        order by created_at
        for update skip locked
        limit 1
    )
    returning run_id;
$$ language sql;


/*******************************************************************************
 * Views
 ******************************************************************************/

-- Full run summary: intent, status, duration, commits produced
create view ai.run_summary as
    select
        r.id,
        r.status,
        a.name                                                          as agent,
        s.title                                                         as session,
        r.intent,
        r.started_at,
        r.completed_at,
        -- human-readable duration: "1m 7s", "42s", or "running 3m 12s"
        case
            when r.status = 'running' then
                'running ' || to_char(
                    make_interval(secs => extract(epoch from now() - r.started_at)::int),
                    'MI"m" SS"s"'
                )
            when r.completed_at is not null then
                trim(to_char(
                    make_interval(secs => extract(epoch from r.completed_at - r.started_at)::int),
                    'MI"m" SS"s"'
                ))
        end                                                             as duration,
        count(distinct rc.commit_id)                                    as commit_count,
        -- array of {bundle, message, commit_id} for every commit this run produced
        coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'bundle',    repo.name,
                    'message',   c.message,
                    'commit_id', c.id
                )
                order by c.commit_time
            ) filter (where c.id is not null),
            '[]'::jsonb
        )                                                               as commits,
        r.error
    from ai.run r
        join ai.session s on s.id = r.session_id
        join ai.agent a on a.id = s.agent_id
        left join ai.run_commit rc on rc.run_id = r.id
        left join bundle.commit c on c.id = rc.commit_id
        left join bundle.repository repo on repo.id = c.repository_id
    group by r.id, r.status, a.name, s.title, r.intent,
             r.started_at, r.completed_at, r.error
    order by r.started_at desc;
-- companion schema
-- Session continuity substrate for Claude Code + Aquameta working sessions.
-- Replaces MEMO.md with structured, queryable, bundle-tracked rows.
--
-- Tables:
--   companion.context   -- mutable key/value state, updated in place each session
--   companion.note      -- durable structured notes by topic
--   companion.decision  -- design decisions with rationale
--
-- View:
--   companion.session_brief -- single query to orient at session start

CREATE SCHEMA companion;


-------------------------------------------------------------------------------
-- companion.context
-- Mutable "where we are" state. One row per key, updated in place.
-------------------------------------------------------------------------------

CREATE TABLE companion.context (
    id         uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    key        text        NOT NULL UNIQUE,
    value      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION companion.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER context_updated_at
    BEFORE UPDATE ON companion.context
    FOR EACH ROW EXECUTE PROCEDURE companion.set_updated_at();


-------------------------------------------------------------------------------
-- companion.note
-- Durable structured notes. topic groups related entries.
-- Suggested topics: architecture | finding | reference | convention | open_question
-------------------------------------------------------------------------------

CREATE TABLE companion.note (
    id         uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    topic      text        NOT NULL,
    title      text        NOT NULL,
    body       text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);


-------------------------------------------------------------------------------
-- companion.decision
-- Design decisions with rationale. Status tracks whether a decision is still live.
-- status: 'open' | 'decided' | 'revisited'
-------------------------------------------------------------------------------

CREATE TABLE companion.decision (
    id         uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    title      text        NOT NULL,
    decision   text        NOT NULL,
    rationale  text,
    status     text        NOT NULL DEFAULT 'decided',
    decided_at timestamptz NOT NULL DEFAULT now()
);


-------------------------------------------------------------------------------
-- companion.session_brief
-- Single query to orient at session start.
-- Returns context state, live decisions, and recent notes.
-- Combine with: SELECT * FROM ai.experiment WHERE status='pending'
-------------------------------------------------------------------------------

CREATE VIEW companion.session_brief AS
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

    SELECT 'note'      AS type,
           topic || ': ' || title AS title,
           body,
           updated_at
    FROM companion.note

    ORDER BY type, updated_at DESC;
/*******************************************************************************
 * AI Ideas
 * Deliberation substrate for cross-agent design reasoning.
 *
 * ai.idea         — proposals for architecture, schema, or behavior changes
 * ai.idea_reply   — threaded responses from agents (support, concern, refine, etc.)
 * ai.idea_context — links ideas to source/context rows elsewhere in Aquameta
 *
 * Distinct from ai.experiment (execution) and companion.note (observations).
 * This is where agents reason together before committing to work.
 ******************************************************************************/


create table ai.idea (
    id          uuid not null default public.uuid_generate_v4() primary key,
    title       text not null,
    body        text,
    status      text not null default 'proposed'
                     check (status in ('proposed', 'accepted', 'rejected', 'superseded', 'implemented')),
    topic       text,  -- 'architecture' | 'schema_design' | 'agent_behavior' | etc.
    parent_idea_id uuid,  -- references ai.idea(id); self-FK removed for bundle compatibility
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table ai.idea_reply (
    id             uuid not null default public.uuid_generate_v4() primary key,
    idea_id        uuid not null references ai.idea(id) on delete cascade,
    agent_id       uuid references ai.agent(id),
    parent_reply_id uuid,  -- references ai.idea_reply(id); self-FK removed for bundle compatibility
    body           text not null,
    verdict        text check (verdict in ('support', 'concern', 'question', 'refine', 'neutral')),
    created_at     timestamptz not null default now()
);

create table ai.idea_context (
    id           uuid not null default public.uuid_generate_v4() primary key,
    idea_id      uuid not null references ai.idea(id) on delete cascade,
    target       meta.row_id not null,
    relationship text not null
                     check (relationship in ('origin', 'context', 'followup', 'evidence', 'outcome')),
    excerpt      text,
    created_at   timestamptz not null default now()
);

-- Index for the common "what are the latest active ideas?" query
create index idx_idea_status_topic on ai.idea(status, topic, updated_at desc);
create index idx_idea_reply_idea on ai.idea_reply(idea_id, created_at);
create index idx_idea_context_idea on ai.idea_context(idea_id, relationship, created_at);
create index idx_idea_context_target on ai.idea_context(((target).schema_name), ((target).relation_name), ((target).pk_values));
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
    plan_id     uuid        NOT NULL REFERENCES companion.plan(id) ON DELETE CASCADE,
    position    integer     NOT NULL CHECK (position > 0),
    title       text        NOT NULL CHECK (title <> ''),
    detail      text,
    status      text        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending','claimed','running','completed','failed','skipped')),
    agent_id    uuid        REFERENCES ai.agent(id),
    claimed_at  timestamptz,
    result      text,
    experiment_id uuid       REFERENCES ai.experiment(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (plan_id, position),
    -- claimed/running steps must have agent_id and claimed_at
    CHECK (status NOT IN ('claimed','running') OR (agent_id IS NOT NULL AND claimed_at IS NOT NULL))
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
-- companion.plan_review / companion.plan_step_with_review / companion.claimable_step
-- Review records for plans and plan steps.
--
-- Design decisions:
--   - Immutable event rows: supersede a blocked review by inserting a new approved one.
--   - Latest outcome per step (by created_at) determines blocked status.
--   - Enforcement is by convention in v1: SQL agents claim via companion.claimable_step,
--     which excludes blocked steps. No trigger enforcement — Decision #1 posture.
--   - Humans reviewing plans get ai.agent rows (uniform participant model).
--   - plan_review data rows travel in io.bundle.aquameta.plan alongside plan/plan_step rows.


-------------------------------------------------------------------------------
-- companion.plan_review
-------------------------------------------------------------------------------

CREATE TABLE companion.plan_review (
    id           uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    plan_id      uuid        NOT NULL REFERENCES companion.plan(id) ON DELETE CASCADE,
    plan_step_id uuid                 REFERENCES companion.plan_step(id) ON DELETE CASCADE,
    reviewer_id  uuid        NOT NULL REFERENCES ai.agent(id),
    run_id       uuid                 REFERENCES ai.run(id),
    outcome      text        NOT NULL
                             CHECK (outcome IN ('comment','approved','changes_requested','blocked')),
    review_text  text        NOT NULL CHECK (review_text <> ''),
    created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE companion.plan_review IS
    'Review records for plans and plan steps. Immutable — supersede by adding a new row. '
    'Latest outcome per step (by created_at) determines blocked status. '
    'Enforcement is by convention: cooperating SQL agents claim via companion.claimable_step.';

COMMENT ON COLUMN companion.plan_review.plan_step_id IS
    'NULL = plan-level review. Non-null = step-level review. Step must belong to plan_id (enforced by trigger).';

-- Enforce that plan_step_id belongs to plan_id (cross-table — cannot be a CHECK constraint).
CREATE OR REPLACE FUNCTION companion.plan_review_step_belongs_to_plan()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.plan_step_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM companion.plan_step
            WHERE id = NEW.plan_step_id AND plan_id = NEW.plan_id
        ) THEN
            RAISE EXCEPTION 'plan_review: plan_step_id % does not belong to plan_id %',
                NEW.plan_step_id, NEW.plan_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER plan_review_step_consistency
    BEFORE INSERT OR UPDATE ON companion.plan_review
    FOR EACH ROW EXECUTE FUNCTION companion.plan_review_step_belongs_to_plan();

COMMENT ON COLUMN companion.plan_review.outcome IS
    'comment: informational, no verdict. '
    'approved: step/plan looks good. '
    'changes_requested: work needed before proceeding. '
    'blocked: do not claim/proceed until a later approved review supersedes this.';


-------------------------------------------------------------------------------
-- companion.plan_step_with_review
-- Step rows augmented with their latest review. is_blocked and blocking_review_text
-- travel with the step so agents see the block in scope at claim time.
-------------------------------------------------------------------------------

CREATE VIEW companion.plan_step_with_review AS
SELECT
    ps.*,
    lr.outcome       AS latest_review_outcome,
    lr.review_text   AS latest_review_text,
    lr.reviewer_name AS latest_reviewer,
    COALESCE(lr.outcome = 'blocked', false)                  AS is_blocked,
    CASE WHEN lr.outcome = 'blocked' THEN lr.review_text END AS blocking_review_text
FROM companion.plan_step ps
LEFT JOIN LATERAL (
    SELECT pr.outcome, pr.review_text, a.name AS reviewer_name
    FROM companion.plan_review pr
    JOIN ai.agent a ON a.id = pr.reviewer_id
    WHERE pr.plan_step_id = ps.id
    ORDER BY pr.created_at DESC
    LIMIT 1
) lr ON true;

COMMENT ON VIEW companion.plan_step_with_review IS
    'plan_step extended with latest review outcome per step. '
    'is_blocked = true when the most recent review has outcome=''blocked''. '
    'A later approved/comment/changes_requested review clears the block.';


-------------------------------------------------------------------------------
-- companion.claimable_step
-- Pending steps with no current block. The intended claim surface for SQL agents.
-- Does not enforce against direct plan_step writes or PGFS agents — convention only in v1.
-------------------------------------------------------------------------------

CREATE VIEW companion.claimable_step AS
SELECT
    id, plan_id, position, title, detail, status, agent_id,
    claimed_at, result, created_at, updated_at, experiment_id,
    latest_review_outcome, latest_review_text, latest_reviewer
FROM companion.plan_step_with_review
WHERE status = 'pending'
  AND NOT is_blocked;

COMMENT ON VIEW companion.claimable_step IS
    'Pending plan steps not currently blocked by a review. '
    'The intended claim surface for SQL agents. Bypassing this view is possible but not sanctioned.';


-------------------------------------------------------------------------------
-- companion.session_brief (replace)
-- Added: blocking info inlined into plan_step body;
--        plan-level actionable reviews (blocked/changes_requested) as own section.
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

    -- Active plan steps; blocking info travels in the body so agents see it at claim time.
    SELECT 'plan_step'                                                       AS type,
           p.title || ' [' || p.status || '] #' || ps.position::text
               || ': ' || ps.title                                          AS title,
           coalesce(ps.detail, '')
               || CASE WHEN ps.status != 'pending'
                       THEN E'\nstatus: ' || ps.status ELSE '' END
               || CASE WHEN ps.is_blocked
                       THEN E'\nBLOCKED by ' || coalesce(ps.latest_reviewer, 'unknown')
                            || ': ' || ps.blocking_review_text
                       ELSE '' END                                          AS body,
           ps.updated_at
    FROM companion.plan p
    JOIN companion.plan_step_with_review ps ON ps.plan_id = p.id
    WHERE p.status = 'active'

    UNION ALL

    -- Plan-level (not step-level) actionable reviews on active plans.
    -- Step-level reviews are inlined above; this arm covers plan-wide blocks/changes_requested.
    SELECT 'plan_review'                                                     AS type,
           p.title || ' [' || pr.outcome || '] by ' || a.name              AS title,
           pr.review_text                                                   AS body,
           pr.created_at                                                    AS updated_at
    FROM companion.plan_review pr
    JOIN companion.plan p ON p.id = pr.plan_id
    JOIN ai.agent a ON a.id = pr.reviewer_id
    WHERE pr.plan_step_id IS NULL
      AND pr.outcome IN ('blocked', 'changes_requested')
      AND p.status = 'active'

    ORDER BY type, updated_at DESC;
