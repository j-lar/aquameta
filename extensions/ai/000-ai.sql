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
    ('read_meta',      'Read schema catalog',           'meta',      'SELECT'),
    ('read_bundle',    'Read version control data',     'bundle',    'SELECT'),
    ('write_bundle',   'Commit and manage bundles',     'bundle',    'ALL'),
    ('read_widget',    'Read widget definitions',       'widget',    'SELECT'),
    ('write_widget',   'Create and modify widgets',     'widget',    'ALL'),
    ('read_endpoint',  'Read endpoint routes/resources','endpoint',  'SELECT'),
    ('write_endpoint', 'Manage endpoint routes',        'endpoint',  'ALL'),
    ('read_semantics', 'Read semantic annotations',     'semantics', 'SELECT'),
    ('write_semantics','Write semantic annotations',    'semantics', 'ALL'),
    ('read_ai',        'Read agent/session data',       'ai',        'SELECT'),
    ('write_ai',       'Write agent/session data',      'ai',        'ALL');


/*******************************************************************************
 * ai.session
 *
 * Conversational context container. One agent, many runs.
 * title and context are mutable — agents can update their own session state.
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
 * status values: pending | running | complete | abandoned
 * findings: null until the experiment completes; free text
 ******************************************************************************/

create table ai.experiment (
    id          uuid not null default public.uuid_generate_v4() primary key,
    name        text not null,
    description text,
    status      text not null default 'pending',
    findings    text,
    created_at  timestamptz not null default now()
);


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
