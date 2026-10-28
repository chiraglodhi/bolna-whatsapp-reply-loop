# Architecture

This is a proposed proof of concept. It is not an official Bolna integration.

The system closes one gap: after a Bolna voice call, a WhatsApp follow-up goes out, but nothing handles the customer's reply. Two n8n workflows cover it. WF1 records each finished call and sends the follow-up. WF2 receives the reply, decides what it means, answers with a fixed template and alerts a human when needed.

## System view

```
                         (1) call ends, terminal-status webhook
   +-------------+  ------------------------------------------->  +---------------------+
   |  Bolna AI   |                                                |  n8n  WF1           |
   |  voice call |                                                |  Call Intake        |
   +-------------+                                                +----------+----------+
                                                                             |
                      (2) store call context          (3) follow-up (template)|
                    +---------------------------+                            |
                    v                                                        v
            +---------------+                                       +----------------+
            |   Supabase    |                                       | Twilio WhatsApp|
            |  PostgreSQL   |                                       |    sandbox     |
            |  3 tables     |                                       +-------+--------+
            +-------+-------+                                               |
                    ^                                                        v
                    |                                                  customer phone
                    |                                                        |
                    |                         (4) customer replies           |
                    |                                                        v
            +-------+-------+     (5) signed inbound webhook         +-------+--------+
            |  n8n  WF2     | <--------------------------------------+ Twilio WhatsApp|
            |  Reply Handler|                                        |    sandbox     |
            +---+-------+---+                                        +----------------+
                |       |
   (6) classify |       | (8) alerts
                v       v
        +---------+   +---------+
        | OpenAI  |   |  Slack  |        (7) fixed-template reply goes back
        | Chat    |   | #alerts |            out through Twilio
        | Compl.  |   +---------+
        +---------+
```

## Data model

Three tables, described in full in `database/schema.sql`.

| Table | One row per | Written by | Key |
|---|---|---|---|
| `bolna_call_contexts` | Bolna call | WF1 (insert), WF2 (reply roll-up) | `execution_id` is UNIQUE |
| `whatsapp_replies` | inbound WhatsApp message | WF2 | `message_sid` is UNIQUE; `call_context_id` links to the call and may be NULL |
| `opt_outs` | number that asked to stop | WF2 | `phone` is UNIQUE and must match E.164 |

A reply is matched to a call by phone number: WF2 looks up the most recent `bolna_call_contexts` row whose `customer_phone` equals the sender. This is a simplification (see Limitations).

## WF1: Call Intake

Trigger: Bolna webhook, path `bolna-call-intake`. Bolna sends several POSTs per call as its status changes, so the first job is to discard the ones that are not final.

```
Bolna Webhook
  -> Is Terminal Status?            no  -> Ignore Non-Terminal
  -> Validate Payload               required: id, status, user_number; phone to E.164
  -> Payload Valid?                 no  -> Build Alert -> Slack
  -> Check Duplicate (execution id) error -> Build Alert -> Slack
  -> Is New Call?                   no  -> Skip Duplicate
  -> Normalize Payload
  -> Upsert Call Context            error -> Build Alert -> Slack
  -> Build WhatsApp Message         template by status; answered call only if duration > 0
  -> Check Opt-Out                  lookup failure -> Build Alert (no message is sent)
  -> Apply Opt-Out                  opted-out number -> skip the follow-up
  -> Send WhatsApp?
       yes -> Send WhatsApp         ok    -> Update Send Status
                                    error -> Record Send Failure -> Build Alert -> Slack
       no  -> Call Failure?         yes   -> Build Alert -> Slack
                                    no    -> No Send Needed
```

Rules implemented here:

- Terminal statuses: `completed`, `no-answer`, `busy`, `failed`, `canceled`, `stopped`, `error`, `balance-low`. `call-disconnected` is deliberately not terminal: in testing its payload carried the transcript but a duration of 0.
- A `completed` call only gets the follow-up when `conversation_duration > 0`. `no-answer` and `busy` get their own templates.
- A `failed` or `error` call with a conversation raises a call-failure alert instead of messaging the customer.
- Duplicate protection: an existing `execution_id` ends the run; the write is also an upsert on the UNIQUE key.
- The opt-out lookup fails closed: if it cannot be answered, nothing is sent.

## WF2: Reply Handler

Trigger: Twilio inbound webhook, path `bolna-twilio-reply`.

```
Twilio Inbound
  -> Validate Signature             HMAC-SHA1 of URL + sorted params vs X-Twilio-Signature
  -> Signature OK?                  no  -> Build Alert -> Slack
  -> Extract & Normalize            strips "whatsapp:", E.164, body capped at 1000 chars
  -> Reply Valid?                   no  -> Build Alert -> Slack
  -> Check Duplicate (MessageSid)   error -> Build Alert -> Slack
  -> Is New Message?                no  -> Skip Duplicate
  -> Find Call Context              latest call for this phone number
  -> Insert Reply Record            stored even when no call matches (call_context_id NULL)
  -> Opt-Out Check                  15 keyword rules, English + Roman-script Hinglish, no AI
  -> Opted Out?
       yes -> Record Opt-Out -> Send Opt-Out Confirmation -> Save Opt-Out Status
              -> Build Opt-Out Alert -> Slack
       no  -> Context Found?
                no  -> Build Alert (UNKNOWN SENDER) -> Slack
                yes -> Build Classifier Request
                    -> OpenAI Classify -> Validate Classification -> Classification Valid?
                         valid                     -> Build Response
                         invalid or request error  -> OpenAI Retry (same request, once)
                              -> Validate Retry     -> Build Response
                              -> request error again -> Build Fallback -> Build Response
                    -> Save Classification
                    -> Update Call Context
                    -> Send Response (fixed template)   error -> Record Response Failure -> Alert
                    -> Save Response Status
                    -> Alert Needed? -> Build Alert -> Slack
```

Slack posting is shared: every alert goes through `Build Alert` (formats the message) and `Post Slack Alert`. In WF2 a successful post is followed by marking the reply row `slack_alerted`.

### Classification, in detail

1. Intents: `CONFIRM`, `RESCHEDULE`, `QUESTION`, `OBJECTION`, `ESCALATE`.
2. The request uses OpenAI Chat Completions with Structured Outputs (`strict: true` JSON schema). The prompt, template and schema are in `prompts/`.
3. The call transcript, summary, extracted answers and the customer's reply are passed as untrusted data, and the system prompt says so.
4. A code node validates the response: no refusal, `finish_reason` is `stop`, JSON parses, `intent` is in the allowed set, `confidence` is a number from 0 to 1, required fields are present. Confidence below 0.6 is overridden to `ESCALATE`.
5. If the call fails or validation fails, the identical request is sent once more. If that also fails, the result is `ESCALATE` with `used_fallback = true` and the error stored.
6. The customer only ever receives the fixed template for the validated intent. The model's `suggested_reply` is stored for a human and never sent.

### Alert routing

Alerts go to one Slack channel. They are built in code from stored fields, the validated classification (including the model's short free-text reason) and a truncated copy of the reply. Types: `HOT LEAD` (CONFIRM), `ESCALATION`, `RESCHEDULE`, `OBJECTION`, `QUESTION` (only when the model flags it for a human), `FALLBACK`, `UNKNOWN SENDER`, `OPT-OUT`, `CALL FAILURE`, and `ERROR` for failed nodes or invalid input. Each alert includes the phone number and, for reply alerts, up to 200 characters of the customer's message. Full transcripts and credentials are never posted.

## Trust boundaries and controls

| Boundary | Control | Status |
|---|---|---|
| Twilio to WF2 | Signature check on every request | Verified on real Twilio requests. A forged request being rejected was not tested. |
| Bolna to WF1 | None cryptographic: Bolna does not sign webhooks | The URL is open to anyone who knows it. Mitigated by the terminal-status filter, payload checks and duplicate check. Source-IP allowlisting is not implemented. |
| Customer text to the model | Treated as untrusted data in the prompt | Prompt-level only, backed by code-side validation |
| Model output to the customer | Output is validated, then only a fixed template is sent | Enforced in code |
| Database | RLS on, no policies; n8n uses the service_role key | Never expose these tables through the anon key |
| Secrets | In n8n credentials; the one variable-held secret is the Twilio auth token, needed for the signature check | See `.env.example` |

## Idempotency

| Source | Key | How |
|---|---|---|
| Bolna | execution `id` | lookup before insert, plus UNIQUE `execution_id` and upsert |
| Twilio | `MessageSid` | lookup before insert, plus UNIQUE `message_sid` |

Both are check-then-write. Two deliveries of the same event arriving at the same instant could both pass the check; the UNIQUE constraint prevents duplicate rows, but a duplicate could still be processed twice. This was not load-tested.

## Execution budget

Each webhook POST that starts a workflow counts as one n8n execution. In testing a connected call produced 5 Bolna POSTs and an unanswered call 3, so the terminal-status filter is the first node in WF1. The Bolna webhook was run on "All statuses" because the dashboard's status dropdown does not offer all five of the rarer terminal states, so the filtering happens inside the workflow.

## Limitations of this design

- Reply-to-call matching uses the phone number and the most recent call. A customer with two recent calls will be matched to the later one.
- The WhatsApp sandbox only allows free-form messages within 24 hours of the customer's last message and requires rejoining every 3 days. A production deployment would need an approved WhatsApp Business setup and templates.
- Opt-out handling covers this prototype's WhatsApp follow-ups only. It is not a compliance mechanism, and it does not stop Bolna calls.
- The opt-out keyword rules cover English and Roman-script Hinglish. A Devanagari-script opt-out is not matched; it falls through to the classifier.
- No rate limiting, multi-tenancy or monitoring beyond Slack alerts. This is a hardened prototype, not a production system.
