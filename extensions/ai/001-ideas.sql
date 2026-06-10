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
