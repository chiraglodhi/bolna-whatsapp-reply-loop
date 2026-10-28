# Test payloads

**Every file here is constructed, not captured.** No real call, message, phone number, ID or transcript is included. Each file carries a `_note` field saying so.

- Bolna payloads follow the field names in Bolna's public execution-payload documentation and the fields WF1 reads. The nested `extracted_data` shape (`[Category][Name]` with seven keys, plus Bolna's own `General` / `Call Summary` entry) matches what was seen in testing.
- Twilio payloads contain the form fields WF2 reads (`MessageSid`, `From`, `Body`, `ProfileName`, `NumMedia`) plus the other standard inbound fields. `body` and `headers` mirror what the n8n webhook node hands to the workflow.
- Placeholder values: customer `+910000000001`, agent number `+910000000002`, execution IDs `00000000-0000-0000-0000-00000000000N`, profile name `Test User`, SIDs of the form `SMXXXX...`, recording URL on the reserved `example.invalid` domain.

## Bolna (`bolna/`)

| File | Status | Duration | Expected WF1 behaviour |
|---|---|---|---|
| `completed-confirmed.json` | completed | 48 s | Stored; follow-up sent |
| `completed-unclear-answer.json` | completed | 6 s | Stored; follow-up sent (answered calls get one, even if short) |
| `completed-zero-duration.json` | completed | 0 s | Stored; no WhatsApp (nothing was said) |
| `no-answer.json` | no-answer | 0 s | Stored; no-answer template sent |
| `busy.json` | busy | 0 s | Stored; busy template sent |
| `failed-after-conversation.json` | failed | 12 s | Stored; no WhatsApp; call-failure Slack alert |
| `in-progress-nonterminal.json` | in-progress | 0 s | Dropped by the terminal-status filter |

Evidence level of each: `completed-confirmed` and `no-answer` follow shapes seen on real calls. `completed-unclear-answer` follows the shape seen for an `unclear` answer. `busy`, `failed` and `completed-zero-duration` are constructed from the documented fields and the workflow rules; their field values (for example hangup fields left `null`) are not known from real traffic. Whether Bolna delivers `failed` webhooks at all is unverified.

## Twilio (`twilio/`)

| File | Reply text | Expected WF2 behaviour |
|---|---|---|
| `reply-confirm.json` | English "yes" | Goes to the classifier |
| `reply-reschedule.json` | asks for another time | Goes to the classifier |
| `reply-unclear.json` | `???` | Goes to the classifier (expected to end as ESCALATE if confidence is low) |
| `reply-optout-roman-hinglish.json` | "please message mat karo" | Matched by the keyword rules; opt-out recorded, no classifier |
| `reply-optout-devanagari-not-matched.json` | Hindi in Devanagari script | **Not** matched by the keyword rules (Roman script only), so it goes to the classifier. This documents a known gap. |

The classifier outcomes above are expectations, not results: classifier output depends on the model and was only checked on live traffic.

## What was checked

The expected behaviours in the Bolna table and the opt-out column of the Twilio table were checked by running the workflows' own decision rules (terminal-status list, required-field check, send rules, and the opt-out regexes from `prompts/optout-patterns.json`) over these files in a script. That is a check of the logic, not a run through n8n.

## Using them

The Twilio signature in these files is a placeholder, so WF2 will reject them as-is; a real request has to be signed with your own auth token and webhook URL. A Bolna payload POSTed to WF1 will try to message the placeholder number, and the send is expected to fail and raise an alert. Each POST also uses one n8n execution.
