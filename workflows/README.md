# n8n workflows

Sanitized exports of the two workflows.

| File | Webhook path | Nodes |
|---|---|---|
| `bolna-wf1-call-intake.json` | `bolna-call-intake` | 21 |
| `bolna-wf2-reply-handler.json` | `bolna-twilio-reply` | 38 |

## What was removed or replaced

- Supabase project ref in node URLs: `<YOUR_SUPABASE_PROJECT_REF>`
- Slack channel ID: `<YOUR_SLACK_CHANNEL_ID>`
- Credential IDs: `REPLACE_WITH_YOUR_CREDENTIAL_ID` (credential names are kept; after import, re-select each credential on its nodes)
- Webhook IDs and workflow/version metadata: removed, n8n regenerates them
- The Slack credential is renamed `Slack - Alerts Bot` in the export

No secrets were ever stored in node parameters. Credentials and variables are not included.

## Before importing

Create these in your n8n instance (names as used by the nodes):

- Credentials: `Bolna - Supabase` (service_role key), `Bolna - Twilio Sandbox`, `Bolna - OpenAI` (Header Auth), `Slack - Alerts Bot`
- Variables: `BOLNA_TWILIO_AUTH_TOKEN`, `BOLNA_TWILIO_WEBHOOK_URL`, `BOLNA_LLM_MODEL`, `TWILIO_SANDBOX_NUMBER` (see `.env.example`)

Create the database first (`database/schema.sql`). Publish both workflows, then point Bolna's webhook at the WF1 production URL and Twilio's inbound webhook at the WF2 production URL.

## Status of these exports

They are exports of the versions that ran during testing. They have not been re-imported into a clean n8n instance, so expect to fix node-level credential selection on first import.
