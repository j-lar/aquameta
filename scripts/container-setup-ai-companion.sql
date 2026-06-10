--
-- Container setup: AI + Companion schemas + bundle backward-compat patch
--
-- Run on a clean Aquameta v0.5 container before checking out
-- io.bundle.ai.core or companion.claude_code.aquameta.
--
-- Load order matters due to FK dependencies.
--

\echo 'Loading ai schema...'
\i extensions/ai/000-ai.sql

\echo 'Loading companion base schema...'
\i extensions/companion/000-companion.sql

\echo 'Loading ai ideas...'
\i extensions/ai/001-ideas.sql

\echo 'Loading companion plan...'
\i extensions/companion/001-plan.sql

\echo 'Loading companion review...'
\i extensions/companion/002-review.sql

\echo 'Creating companion.assessment (missing from extension files, needed by companion.claude_code.aquameta)...'
CREATE TABLE IF NOT EXISTS companion.assessment (
    id            uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    entity_type   text        NOT NULL,
    entity_id     uuid        NOT NULL,
    reviewer_id   uuid        NOT NULL REFERENCES ai.agent(id),
    requester_id  uuid        NOT NULL REFERENCES ai.agent(id),
    instructions  text        NOT NULL DEFAULT '',
    status        text        NOT NULL DEFAULT 'pending',
    outcome       text,
    reasoning     text,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz,
    result_id     uuid
);

\echo 'Loading ai session/run binding...'
\i scripts/create_ai_run_binding.sql

\echo 'Loading bundle backward-compat patch for v0.4 row IDs...'
\i scripts/bundle-backward-compat-patch.sql

\echo 'Done. The container can now checkout io.bundle.ai.core and companion.claude_code.aquameta.'
