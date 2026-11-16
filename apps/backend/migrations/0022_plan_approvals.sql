-- A plan is approved once. The handler checked the queue for phase rows of the
-- plan, but that check ran before the queue lock, so parallel approvals each
-- enqueued the whole phase set, and once the phases had been sent and removed
-- from the queue the plan could be approved again. The approval is now a row
-- with the plan as its primary key, written in the same batch as the phases:
-- the second writer violates plan_approvals_pkey, the whole batch (including
-- its phases) rolls back, and the router answers 409 "This plan was already
-- approved". The row outlives the queue entries; it goes with the plan.
CREATE TABLE plan_approvals (
  plan_work_request_id text PRIMARY KEY REFERENCES work_requests(id) ON DELETE CASCADE,
  thread_id text NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  approved_by_user_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX plan_approvals_thread_id_fkidx ON plan_approvals (thread_id);

-- Existing approvals, from the two places a phase leaves evidence: phase rows
-- still in the queue, and phase Work Requests already sent (their input names
-- the plan). The earliest row of each plan gives the approver and the time.
-- Not recoverable: a plan whose phases were all sent and whose phase Work
-- Requests were later deleted (e.g. by retention) leaves no evidence, so it
-- stays approvable. Nothing is deleted or changed in the source tables.
INSERT INTO plan_approvals (plan_work_request_id, thread_id, approved_by_user_id, created_at)
SELECT DISTINCT ON (e.plan_id) e.plan_id, p.thread_id, e.approver, e.at
  FROM (
    SELECT request_json::jsonb #>> '{planWorkRequestId}' AS plan_id, author_user_id AS approver, created_at AS at
      FROM thread_request_queue
    UNION ALL
    SELECT input_json::jsonb #>> '{planWorkRequestId}', requested_by_user_id, created_at
      FROM work_requests
  ) e
  JOIN work_requests p ON p.id = e.plan_id AND p.workflow_id = 'plan_implement'
 WHERE e.plan_id IS NOT NULL
 ORDER BY e.plan_id, e.at
ON CONFLICT DO NOTHING;
