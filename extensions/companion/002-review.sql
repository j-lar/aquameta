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
    review_text  text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE companion.plan_review IS
    'Review records for plans and plan steps. Immutable — supersede by adding a new row. '
    'Latest outcome per step (by created_at) determines blocked status. '
    'Enforcement is by convention: cooperating SQL agents claim via companion.claimable_step.';

COMMENT ON COLUMN companion.plan_review.plan_step_id IS
    'NULL = plan-level review. Non-null = step-level review. Step must belong to plan_id (by convention).';

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
