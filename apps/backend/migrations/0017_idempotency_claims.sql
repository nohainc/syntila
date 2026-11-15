-- Route-level idempotency (src/domain/routes/route-idempotency.ts) claims a
-- key with a pending receipt (response_status 0) before the handler runs, so
-- a concurrent retry cannot run the request a second time.
ALTER TABLE mutation_receipts DROP CONSTRAINT mutation_receipts_response_status_check;
ALTER TABLE mutation_receipts ADD CONSTRAINT mutation_receipts_response_status_check
  CHECK (response_status = 0 OR response_status BETWEEN 200 AND 299);
