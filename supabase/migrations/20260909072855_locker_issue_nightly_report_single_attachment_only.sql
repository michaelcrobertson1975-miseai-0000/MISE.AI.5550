insert into locker_issues (title, description, area, status) values (
'ingest-nightly-report only reads the first attachment — extra attachments are silently dropped',
'Confirmed by reading the actual code this session. The nightly-report ingestion function does `const first = files[0]` and never loops over the rest of the files array, unlike ingest-invoice which correctly processes every page. If a restaurant ever emails multiple attachments (e.g. two photos of one long POS report, or a report plus something else) to the sales@ / nightly_report address, only the first is processed — no error, no flag, no trace that anything was dropped.

Also still true from earlier: the whole function assumes the report always arrives as an image/PDF, same as invoices. That assumption has never been confirmed against a real nightly report — if the real export turns out to be a CSV/spreadsheet, this needs a different reader entirely, not a tweak.

NEXT STEP: fix the single-attachment limitation before relying on this path for a real restaurant, ideally at the same time as finally testing it against a real report to confirm the format assumption.',
'nightly-report-ingestion',
'open'
);
