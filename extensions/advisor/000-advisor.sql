/*******************************************************************************
 * Advisor
 * Pre-loaded expert advisor for Aquameta development
 *
 * An advisor is a named Claude API persona with a corpus of context documents.
 * The corpus is version-controlled as bundle rows, not prompt engineering in code.
 * Invocations are recorded as rows — every call is a ledger entry.
 *
 * Copyright (c) 2026 - Aquameta - http://aquameta.org/
 ******************************************************************************/

create schema advisor;


/*******************************************************************************
 * advisor.advisor
 *
 * A named advisor persona. model selects the Claude model used for invocations.
 * system_prompt defines the advisor's behavior and framing.
 * Switch models by updating the model column — no code change needed.
 ******************************************************************************/

create table advisor.advisor (
    id            uuid        not null default public.uuid_generate_v4() primary key,
    name          text        not null unique,
    description   text,
    model         text        not null default 'claude-opus-4-8',
    system_prompt text        not null,
    created_at    timestamptz not null default now()
);


/*******************************************************************************
 * advisor.context_document
 *
 * Pre-loaded knowledge corpus. Assembled in sort_order (ascending) and injected
 * into every invocation. Lower sort_order = higher priority = appears first.
 * Update rows to keep context current; the bundle tracks history.
 ******************************************************************************/

create table advisor.context_document (
    id         uuid        not null default public.uuid_generate_v4() primary key,
    advisor_id uuid        not null references advisor.advisor(id) on delete cascade,
    title      text        not null,
    body       text        not null,
    sort_order int         not null default 100,
    updated_at timestamptz not null default now()
);

create index on advisor.context_document (advisor_id, sort_order);


/*******************************************************************************
 * advisor.invocation
 *
 * Every call to an advisor is recorded here. Ledger, not cache.
 * context_snapshot captures what context was used at invocation time,
 * making it possible to replay or audit advice given under an older corpus.
 ******************************************************************************/

create table advisor.invocation (
    id               uuid        not null default public.uuid_generate_v4() primary key,
    advisor_id       uuid        not null references advisor.advisor(id),
    question         text        not null,
    context_snapshot text,
    response         text,
    model_used       text,
    input_tokens     int,
    output_tokens    int,
    created_at       timestamptz not null default now()
);
