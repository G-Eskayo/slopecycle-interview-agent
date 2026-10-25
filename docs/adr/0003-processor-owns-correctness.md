# 3. The processor owns correctness; n8n owns triggers and Google I/O

Date: 2026-10-25. Status: accepted.

## Decision
A small local Python service (the processor) does everything that must be right: the run ledger, duplicate detection, text extraction, the model call, validation, calculated values and spreadsheet escaping. It is unit-tested. n8n does the visible steps teammates can point at in a demo: schedule, list the Inbox, download, call the processor, write to Sheets, report back.

Every write is idempotent. Interview rows are keyed by an `interview_id` derived from the Drive file id; Evidence rows by `evidence_id`; Run Log rows by `run_id`. n8n uses append-or-update on those keys, so retrying a write whose response was lost cannot create a duplicate. A run is only marked completed after n8n reports the writes succeeded; a run stuck waiting for that is handed back with its cached result and written again.

## Why
n8n workflows are hard to test and Sheets append is not exactly-once. Keeping the rules in tested code and making every write a keyed upsert gives the spec's guarantees without a database the team has to understand.
