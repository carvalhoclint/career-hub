# Learn Salesforce development by building Career Hub

Use two real workflows: the Salesforce Intake Queue creates applications from reviewed submission confirmations; the Application Updates sheet proposes changes to existing applications. Keep those paths separate. The Gmail check stages suggestions, and the approval path applies only explicitly reviewed changes.

## 1. Trigger architecture: application stage history

Audit existing Apex triggers, record-triggered flows, and history tracking on Job Application before adding automation. Start with a single business rule: capture genuine stage changes for funnel reporting. If existing field history satisfies the requirement, use it; if it does not, implement this as a bulk action in the existing trigger or handler. Compare old and new stages across the entire batch and write history in one DML operation. Keep callouts and spreadsheet logic outside the trigger.

Practice by comparing a thin trigger and handler, a shared dispatcher, and a metadata ordered Trigger Actions Framework. Adopt the simpler handler until independent actions or ordering justify a framework. Prove the rule handles 200 records, ignores unchanged rows, and works for both manual and approved integration updates without duplicates.

## 2. Integration patterns: make approved updates replayable

Use the Sheets-to-Salesforce approval worker as the real integration exercise. Preview the proposed record match; require a reviewer to select an exact record when the requisition is ambiguous. Use the Gmail message key to identify the event and the Salesforce record ID to identify the application. Keep the update and its replay marker atomic on the Salesforce side.

Practice bounded backoff for throttling, timeouts, and temporary server errors; route validation and ambiguous matches back to review. Test a Salesforce success followed by a Sheets status failure: replay must neither duplicate the note nor roll the application back to an older stage. Add a separate Queueable Apex exercise only where Salesforce owns the asynchronous work. Persist the operation state, test callouts with mocks, and verify that exhausted retries are visible to an operator. The existing worker remains the external scheduler; do not add a second writer to the same queue.

## 3. Lightning Web Components: a fast review queue

The intake queue uses a Lightning datatable on desktop and retains a plain table on smaller devices. Filtering runs on the current set of up to 100 rows across employer, title, and status, with no additional Apex request. Existing staging and review actions remain single-record operations.

In the developer org, verify filter and clear, keyboard navigation, opening linked applications, reviewing a pending item, completed rows with no linked application, and the smaller-screen fallback. Record first-load and filter timings with representative data before changing the query or adding pagination. Use these findings before extending the design to the separate updates queue.

For a portfolio demo, use synthetic applications and show one submission reviewed, one approved stage change, and one failed update safely replayed. Report measured timings and transaction behavior before making performance claims.
