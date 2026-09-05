# Session 8 security review

Scope: plan.md Session 8; commits a5e7e067..bb1710f1. Reviewer: security owner, no delegates. Cycle 1.

## FINDING 1 — HIGH — lib/accounts/purge.rb:1017

A killed export worker can leave an uploaded whole-account archive named only by `summary.staged_blob_id`. The account purge inventories attached files, then `delete_account_exports!` deletes the export row without deleting its staged blob. The account is reported purged while the archive remains in storage permanently; the retention sweeps can no longer find it. This is reachable by purging a pending-deletion account after a worker dies during upload, before stale recovery runs.

Triage: REAL by code inspection; regression pending. Fix-now: Session 8 export/purge-scheduling Done-when.

## FINDING 2 — MEDIUM — app/controllers/concerns/support_impersonation_guard.rb:389

The refusal audit persists `request.path` verbatim. A support operator opening a valid signer `/s/:slug` or embedded-builder `/embed/template_builder/:token` URL copies the bearer credential into `operator_events.details`, even though the action is refused. Those credentials permit access without the impersonation cookie and are retained in audit history. The session-only refusal concern uses the same raw-path pattern.

Triage: REAL by code inspection; regression pending. Fix-now: Session 8 impersonation-denial Done-when. Preserve route identity and record ids while redacting credential path components.

### Cycle 1 evidence and checkpoint

Both findings reproduced on the original implementation: `sec8-scratch/regression-before-valid.log` — 3 examples, 3 failures (the staged file survived; storage failure did not stop the purge; the refusal row contained the real fixture slug). The preceding `regression-before.log` had a missing submitter UUID in the new fixture; that setup error was corrected before claiming reproduction of Finding 2.

Finding 1: fixed for staged archives present at purge entry. Purge locks each export, deletes its archive and staged file storage-first, then removes its row. A storage error preserves the locator and prevents a tombstone.

Finding 2: fixed. Both audit writers use the recognized route, redact bearer path parameters, and preserve record identifiers. Existing route sweeps retain every refusal/account/operator assertion; their exact path expectation now requires redaction. The first implementation over-redacted repeated placeholder values; the next appended a default JSON format absent from the URL. Both mismatches were caught and corrected, without dropping assertions.

Verification: `sec8-scratch/cycle1-pass.log` — 116 examples, 0 failures (3 security regressions plus complete existing impersonation and account-export files). `git diff --check` passed. Beginning cycle 2 re-review of these changes and their concurrent lifecycle boundaries.
