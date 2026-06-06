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
