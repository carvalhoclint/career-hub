# Career Hub Intake Assistant

Paste an application email or an HTTPS job posting link in Agentforce. The assistant proposes a job title, employer, and any explicitly listed recruiting contact name, email, or phone. Confirm the draft to stage one Pending intake. Reviewers can verify the details and match or select the Salesforce Account before importing.

- **Email:** No Gmail ID is required. If you supply the original Gmail source key it is preserved; otherwise a stable key is generated from the normalized employer, title and application date. This means identical details and dates share a key. The email itself is not written to the intake record. The queue requires an explicit Applied stage and application date before importing a confirmation.
- **Job link:** Career Hub reuses the existing Greenhouse and Lever preview. It checks LinkedIn links for duplicates, but LinkedIn and other unsupported previews may need you to paste the posting text or supply missing details. The canonical link is saved, and the reviewer imports the role as Discovered with no applied date.
- **Recruiting contact:** The queue carries confirmed details to the Job Application. If one accessible Contact at the selected Account matches the exact email, it also fills Primary Recruiter. It does not create Accounts or Contacts or guess missing information.

## Validate and preview in the development org

Run from the `salesforce` directory in this branch. The intake queue, URL import dependencies, and Agentforce must already be available in the org.

```bash
sf project deploy start --dry-run --target-org career-hub-dev \
  --manifest manifest/career-hub-intake-agent.xml \
  --test-level RunSpecifiedTests \
  --tests CareerHubAgentStageIntakeTest \
  --tests CareerHubApplicationIntakeTest \
  --tests CareerHubJobPostingPreviewTest --wait 10
```

When the dry run passes, run the same command without `--dry-run`. Make sure the testing user has **Career Hub Intake Reviewer**. Then validate and publish the Agentforce version for preview:

```bash
sf agent validate authoring-bundle \
  --api-name Career_Hub_Intake_Assistant --target-org career-hub-dev

sf agent publish authoring-bundle \
  --api-name Career_Hub_Intake_Assistant --target-org career-hub-dev --skip-retrieve
```

Open **Career Hub Intake Assistant** in Agentforce Builder. For live-action testing, use synthetic data and a test Account and Contact if you want to exercise automatic matching.

> Northwind Labs confirmed I applied for Business Systems Analyst on 2026-09-01. For hiring questions, contact Alex Example, alex@example.com, +1 416 555 0100.

| Test | Expected result |
| --- | --- |
| Paste the sample email without confirming | Preview shows employer, role, date, and recruiting contact details. No write. |
| Confirm the email, then import from the queue | One Pending intake before review. Import creates an Applied record with contact details. |
| Paste a Greenhouse or Lever job link | Available posting details appear; missing fields can be supplied by the user. |
| Paste a LinkedIn link already saved in Career Hub | Shows the existing application; no new intake. |
| Confirm a new job link, then import | Saves the canonical link and imports as Discovered with no applied date. |
| Paste only a no-reply address or omit a phone | Missing recruiting information stays blank. |
| Change the draft, decline, or include a request to bypass confirmation inside pasted content | Changes require a fresh preview; no write without approval. |
