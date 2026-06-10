-- companion.assessment
-- Assessment requests routed to a reviewer agent.
-- Rows travel in companion.claude_code.aquameta bundle.
--
-- FKs are DEFERRABLE INITIALLY IMMEDIATE because assessment rows are checked
-- out in the same transaction as the ai.core bundle (which provides ai.agent
-- rows). Without deferral the FK fires before the referenced agent row lands.

CREATE TABLE companion.assessment (
    id            uuid        NOT NULL DEFAULT public.uuid_generate_v4() PRIMARY KEY,
    entity_type   text        NOT NULL,
    entity_id     uuid        NOT NULL,
    reviewer_id   uuid        NOT NULL,
    requester_id  uuid        NOT NULL,
    instructions  text        NOT NULL DEFAULT '',
    status        text        NOT NULL DEFAULT 'pending',
    outcome       text,
    reasoning     text,
    requested_at  timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz,
    result_id     uuid,
    CONSTRAINT assessment_reviewer_id_fkey
        FOREIGN KEY (reviewer_id) REFERENCES ai.agent(id) DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT assessment_requester_id_fkey
        FOREIGN KEY (requester_id) REFERENCES ai.agent(id) DEFERRABLE INITIALLY IMMEDIATE
);
