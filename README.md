# Bolna WhatsApp Reply Loop

Catches a customer's WhatsApp reply to a post-call follow-up, works out what they mean, answers with a fixed message and alerts a person when it matters.

> This is a proposed proof of concept demonstrating how Bolna's post-call WhatsApp gap could be filled. It is not an official Bolna integration.

## Why I built this

I'm Chirag, a self-taught AI generalist. I'm not a software engineer, but I'm good at orchestrating AI tools: connecting them and turning them into working workflows. I take Claude's help for the code and use its connectors and MCPs heavily. I also notice patterns in problems and build something that solves them. I studied how Bolna's post-call flow works and read its documentation. Bolna's WhatsApp step sends a message and moves on. In the docs and the workflow builder, I couldn't find a way for a customer's reply to start or continue a workflow, so I built one version of that outside Bolna. It is a hardened prototype, not a throwaway demo, and it shows how I spot a gap and close it. I'm looking for a founder's office role or an internship, and Bolna is the team I'm most interested in.

## The gap

Bolna's workflow builder includes an AiSensy WhatsApp node. Bolna's docs say this node is fire-and-forget with a single exit, meaning it returns no delivery status to branch on. Separately, as of 28 October 2026 I found no node or trigger in the workflow builder that starts from or branches on a customer's reply, and no documentation page that mentions one. This project handles that reply outside Bolna: it receives the reply, decides what it means, answers with a fixed template and alerts a person when needed.

Bolna has a Callback node that lets an outside system resume a paused workflow. In principle a reply handler like this one could feed its result back through it. I did not test this. As I read the docs, the Callback node resumes an execution that is already waiting; it is not a trigger that starts one when a reply arrives. The gap I mean is the missing native reply trigger.

**How I checked, and what I could not verify**
- Checked: Bolna's [AiSensy integration page](https://www.bolna.ai/integrations/aisensy), its [Workflows introduction](https://www.bolna.ai/docs/workflows/introduction), and the node list in the workflow builder of a trial account on 28 October 2026.
- Not verified: I did not read all of Bolna's documentation. The workflow builder is marked Beta and may change. The Callback return path described above is untested.

## What it does

```
 Bolna voice call ends
        |  webhook (terminal status only)
        v
 WF1  Call Intake  ---->  Supabase: call context  ---->  WhatsApp follow-up (Twilio sandbox)
                                                                |
                                                          customer replies
                                                                v
 WF2  Reply Handler  <----  signed Twilio webhook
        |-- opt-out keywords?  yes -> record, fixed confirmation, Slack alert
        |-- no -> OpenAI classifies the reply (strict schema, validated)
        |           -> fixed-template answer to the customer
        |           -> Slack alert when a human should look
        v
 Supabase: reply, intent, confidence, what was sent
```

1. Bolna sends a webhook for every call status change. WF1 ignores non-final statuses, validates the rest, skips duplicates and stores the call, including transcript, summary and extracted answers.
2. WF1 sends a WhatsApp follow-up, unless the call had no conversation or the number has opted out.
3. When the customer replies, WF2 verifies Twilio's signature, skips duplicates, and matches the reply to that number's most recent call.
4. A fixed set of keyword rules (English and Roman-script Hinglish) catches opt-out requests first, without a model.
5. Otherwise a model classifies the reply as CONFIRM, RESCHEDULE, QUESTION, OBJECTION or ESCALATE. The output is validated in code; low confidence becomes ESCALATE; a failed or invalid result is retried once and then falls back to ESCALATE.
6. The customer receives a fixed template for the intent. The model's own suggested reply is stored for a human and never sent.
7. Slack gets an alert for hot leads, escalations, reschedules, objections, fallbacks, opt-outs, unknown senders and failures.

Full node-by-node flows are in [`docs/architecture.md`](docs/architecture.md).

## What I observed in testing

These are observations from a small number of runs on trial accounts. No real customers were involved. They are not performance figures.

- **Calls.** Ten outbound calls to one verified number on 27 and 28 October 2026: eight completed with a conversation, one went unanswered and one came back as busy. Nine follow-up messages were sent; the tenth was skipped because that number had opted out.
- **Replies.** Twenty-seven inbound messages were recorded: 24 classified (one of them by the ESCALATE fallback), one handled by the opt-out rules, and two from a number with no matching call (stored and flagged, not classified).
- **Classification.** All five intents were produced. Among replies the model classified without falling back, confidence ranged from 0.78 to 0.99. The fallback path ran once for real. The rule that turns low confidence into ESCALATE has never fired on a live reply; it was tested offline only.
- **Extraction answers.** The agent's yes / no / unclear extraction returned all three answers. The two "unclear" answers had low confidence (0.2) and came from near-empty calls. A vague answer from a caller produced "no", not "unclear".
- **Language.** The agent and the transcripts came out in Devanagari Hindi, including when the caller spoke Hinglish. A Roman-script Hinglish opt-out worked end to end: the reply was recorded and the next call's follow-up was skipped. A Devanagari opt-out is not caught by the keyword rules; the classifier labelled it ESCALATE and the standard reply went out.
- **Failures.** Two replies ended with the answer failing to send. In both, the row was marked as an error and Slack was alerted. The cause was not recorded.
- **Webhook volume.** Bolna sent three to five webhook calls per phone call, which is why the terminal-status check is the first step.

## What is real and what is simulated

| Real | Simulated or substituted |
|---|---|
| Calls placed from a Bolna trial account to a verified number | Bolna's AiSensy follow-up is replaced by a message from the Twilio WhatsApp sandbox |
| Bolna webhooks delivered to n8n Cloud | One phone plays every customer role |
| Twilio sandbox messages in both directions, with signature checks on real requests | No real customers, and no production WhatsApp Business setup |
| OpenAI classification of real replies | The files in `test-payloads/` are constructed examples, not captures |
| Supabase storage and Slack alerts | |

Not claimed: any integration with Bolna's production systems, any partnership with Bolna, or any testing with real customers.

## Design decisions

The short version. The reasoning, alternatives and costs for 23 decisions are in [`docs/design-decisions.md`](docs/design-decisions.md).

- **Terminal-status check first.** Non-final pings can lack fields and would raise false alerts, and each one costs a workflow execution.
- **Duplicates are handled on the sender's own IDs.** Bolna's execution ID and Twilio's message ID are checked before processing and enforced by unique constraints.
- **Structured output, then validation in code.** The schema constrains the model; the code does not trust it.
- **Customers only receive fixed templates.** There is no path from model output to a customer message.
- **Opt-out uses fixed rules, not the model, and fails closed.** If the opt-out table cannot be read, nothing is sent.
- **No invented authentication for Bolna's unsigned webhook.** Bolna does not sign its webhooks, and a homemade scheme would give false confidence. This is a real weakness and is listed below.

## Known limitations

This is a hardened prototype: it handles the main path, common error cases and duplicate events, and it logs what it does. It is not production software.

- **Open Bolna webhook.** Bolna does not sign webhooks, and the WF1 URL accepts any POST. The terminal-status check, field validation and duplicate check reduce harm but are not authentication. A shared-secret header or caller-address check is not implemented.
- **Reply matching is by phone number.** A reply is attached to that number's most recent call.
- **No path back into Bolna.** WF2 answers the customer itself. It does not feed the result into a Bolna workflow. Bolna's Callback node is the natural route and is the obvious next step; it is untested.
- **Opt-out is narrow.** It covers WhatsApp follow-ups from this prototype only, not Bolna calls, and it is not a compliance mechanism. The keyword list is English and Roman-script Hinglish, was not validated on real customers, misses Devanagari, and has one known false positive ("remove me from tomorrow's slot"). The failure paths of the opt-out steps were not tested live.
- **Twilio sandbox constraints.** Free-form messages only within 24 hours of the customer's last message, rejoin every three days, and a message starting with "stop" disconnects the sandbox.
- **Not observed.** `failed`, `canceled`, `stopped`, `error` and `balance-low` calls never occurred in testing, and Bolna's status filter does not offer them; whether those webhooks arrive is unverified. The `busy` result was seen once. The forged-signature rejection of the Twilio check was not recorded as tested.
- **Small test set.** The classifier was checked on a handful of hand-written replies and the opt-out rules on a set of hand-written phrases during development (the cases are not committed). No evaluation set, no prompt-injection test recorded.
- **Duplicate protection is check-then-write.** Two identical events at the same instant could both be processed; the unique keys prevent duplicate rows only. Not load-tested.
- **Sent means accepted.** `whatsapp_sent = true` means Twilio accepted the message, not that it was delivered.
- **No multi-tenancy, rate limiting or monitoring** beyond Slack alerts.
- **Temporary infrastructure.** The n8n Cloud trial, the Bolna trial and the Twilio sandbox are time-limited. The workflow exports and schema are what remain.

## Setup

Step 1 was tested: the schema applies without errors to a blank PostgreSQL 16 database, and its constraints and trigger behave as designed. Steps 2 to 6 have not been run on a clean n8n instance.

1. Create a Supabase project and run [`database/schema.sql`](database/schema.sql).
2. In n8n, create the credentials and variables listed in [`.env.example`](.env.example).
3. Import both files from [`workflows/`](workflows/) and re-select the credential on each node. Replace the two placeholders (`<YOUR_SUPABASE_PROJECT_REF>`, `<YOUR_SLACK_CHANNEL_ID>`).
4. Publish both workflows and note their production webhook URLs.
5. In Bolna, set the agent's webhook URL to the WF1 URL. In Twilio, set the sandbox's incoming-message URL to the WF2 URL.
6. Try the examples in [`test-payloads/`](test-payloads/), keeping in mind that they use placeholder numbers and an unsigned Twilio request, as explained in that folder's README.

## Repository map

```
database/schema.sql          tables, indexes, trigger, RLS
workflows/                   sanitized n8n exports (WF1, WF2)
prompts/                     classifier prompt, schema, customer templates, opt-out rules
test-payloads/               constructed Bolna and Twilio examples
docs/architecture.md         system view and node-level flows
docs/design-decisions.md     why it is built this way
docs/demo-script.md          recording checklist and shot list
.env.example                 variables and credentials, names only
```

## How this was built

Built by Chirag Lodhi with AI assistance from Claude. The commit history shows it in the co-author lines.

## License

MIT. See [`LICENSE`](LICENSE).
