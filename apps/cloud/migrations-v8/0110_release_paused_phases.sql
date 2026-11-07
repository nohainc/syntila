-- Phases that paused for input were left `waiting` after their Workflow
-- finished. Only the remaining phases pause now; release the old ones so they
-- no longer read as processing or block Cancel and Stop.
UPDATE work_requests
   SET status = 'completed', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
 WHERE status = 'waiting'
   AND json_extract(input_json, '$.isPhased') = 1
   AND EXISTS (SELECT 1 FROM workflow_tasks t WHERE t.work_request_id = work_requests.id)
   AND NOT EXISTS (SELECT 1 FROM workflow_tasks t
                    WHERE t.work_request_id = work_requests.id
                      AND t.status IN ('queued', 'running', 'waiting'));
