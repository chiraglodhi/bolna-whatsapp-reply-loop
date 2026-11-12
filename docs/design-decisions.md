# Design decisions

This is a proposed proof of concept demonstrating how Bolna's post-call WhatsApp gap could be filled. It is not an official Bolna integration.

Each entry says what was decided, why, what the alternative was, and what the decision costs. "Observed" means seen in testing on this project's trial accounts; the sample is small and the Limitations section of the README says so.

## Data and idempotency

### 1. Two tables for calls and replies
- **Decision:** `bolna_call_contexts` (one row per call) and `whatsapp_replies` (one row per message), linked by a foreign key.
- **Why:** one call can lead to several replies, and the database should enforce that link.
- **Alternative:** one table with an array column. That gives up foreign-key integrity.
- **Cost:** an unknown sender produces a reply row with no call, so `call_context_id` is nullable.

### 2. Deduplicate on the sender's own IDs
- **Decision:** Bolna events are keyed on the execution `id`, Twilio messages on `MessageSid`. Each is checked before processing and also protected by a UNIQUE constraint.
- **Why:** webhook senders can deliver the same event more than once, and Bolna sends several POSTs for every call. Timestamps are not a reliable identity.
- **Cost:** the check and the write are separate steps, so two identical events arriving at the same instant could both pass the check. The constraint prevents duplicate rows but not duplicate processing. Not load-tested.

### 3. Keep Bolna's `extracted_data` as JSONB, exactly as received
- **Decision:** store the nested object unchanged; flatten it only in flight when building the model prompt.
- **Why:** extraction names are configured per agent and can change, and the shape is nested (`[Category][Name]`). Fixed columns would break whenever the agent's extractions change.
- **Alternative:** flatten into columns.
- **Cost:** queries need JSON paths, and Bolna's own `General` / `Call Summary` entry has to be skipped by any code that loops over categories.

### 4. Match a reply to a call by the top-level `user_number`
- **Decision:** the customer's phone, normalised to E.164, is the join key. A reply is attached to that number's most recent call.
- **Why:** `user_number` is top-level in Bolna's payload and already E.164. The alternative, `context_details.recipient_phone_number`, is nested.
- **Cost:** a customer with two recent calls is matched to the later one. A production system would need a conversation or message identifier instead. This also fails if Bolna's PII masking is switched on, because the number would arrive as null (it was off on the test account).

## Ingesting Bolna webhooks

### 5. Filter for terminal statuses before validating
- **Decision:** the first check in WF1 is whether the status is terminal; only then is the payload validated.
- **Why:** non-terminal pings can lack fields. Validating first would raise false alerts on every ping. It also stops useless work early: in testing, 14 of the 18 executions on one day were non-terminal pings.
- **Alternative:** validate first. That is noisy in Slack.

### 6. Run Bolna on "All statuses" and filter inside the workflow
- **Decision:** the webhook is not narrowed in Bolna's dashboard.
- **Why:** Bolna's status dropdown does not offer `failed`, `canceled`, `stopped`, `error` or `balance-low`, so the dashboard filter cannot express the full terminal set.
- **Alternative:** narrow to `completed`, `no-answer` and `busy`. That costs about one execution per call, but failed or errored calls might never arrive. Untested.
- **Cost:** every call costs 3 to 5 workflow executions, which matters on a metered trial.

### 7. `call-disconnected` is not a terminal status
- **Why:** observed on real calls: its payload already contains the transcript but reports a duration of 0. The later `completed` payload carries the real duration. Treating `call-disconnected` as final would store a call that looks silent.

### 8. Send a follow-up only when there was a conversation
- **Decision:** a `completed` call gets the follow-up only if `conversation_duration > 0`. `no-answer` and `busy` get their own templates. Failed or errored calls get a Slack alert instead of a customer message.
- **Why:** `completed` does not guarantee anyone spoke, and the follow-up text refers to a conversation.
- **Cost:** any answered call, even a few seconds, triggers the "thank you for speaking" message.

## Classifying replies

### 9. Structured Outputs plus validation in code
- **Decision:** the model must return JSON matching a strict schema. A code step then re-checks everything before anything acts on it: no refusal, normal finish, parseable JSON, intent in the allowed set, confidence a number from 0 to 1, required fields present.
- **Why:** the schema constrains the output, but the code does not trust it. The 0 to 1 range is checked in code because support for numeric range keywords in strict mode was not confirmed.
- **Cost:** two layers to maintain.

### 10. Five intents
- **Decision:** CONFIRM, RESCHEDULE, QUESTION, OBJECTION, ESCALATE.
- **Why:** enough to route differently (alert, template, human), few enough to stay reliable. Three would be too coarse; ten or more adds confusion between neighbours.
- **Cost:** no multi-turn handling. Each reply is classified on its own.

### 11. Low confidence becomes ESCALATE
- **Decision:** below a confidence of 0.6, the result is overridden to ESCALATE.
- **Why:** a wrongly auto-handled reply is worse than a human looking at an uncertain one.
- **Status:** the override has been tested offline only. Across the live replies the lowest confidence was 0.78, so it has never fired on real traffic. See the open question on the threshold value.

### 12. Customers only ever receive fixed templates
- **Decision:** the text sent to a customer is chosen from five fixed templates by the validated intent. The model's `suggested_reply` is stored for a human and never sent.
- **Why:** predictable wording, no chance of the model making a promise, and no path from model output to a customer message that bypasses validation.
- **Cost:** replies are generic. A question gets "a team member will get back to you", not an answer.

### 13. One retry, then a safe default
- **Decision:** if the model call fails or the output is invalid, the identical request is sent once more. If that also fails, the result is ESCALATE with `used_fallback = true`, the error is stored and Slack is alerted.
- **Why:** it catches transient failures, bounds the loop, and makes failure visible instead of silent.
- **Evidence:** the fallback path ran once for real during testing.

### 14. Customer text and call content are treated as untrusted
- **Decision:** the transcript, summary, extracted answers and the reply are all passed as data, and the prompt says not to follow instructions inside them.
- **Why:** all of it originates with the customer or with a model reading the customer's speech.
- **Cost:** the prompt rule is only a second layer. The real protection is that model output goes through validation and only fixed templates reach the customer. A prompt-injection test was not recorded.

### 15. Keep the model behind an adapter, with the model ID in a variable
- **Decision:** intents, schema, routing and templates are provider-independent. Only the HTTP call and the line that reads the answer are specific to the provider. The model ID lives in an n8n variable, not in a node.
- **Why:** swapping or fixing the model should not require editing nodes, and nothing about the business logic should depend on one vendor.

## Opt-out handling

### 16. Detect opt-out with fixed keyword rules, before the model
- **Decision:** a deterministic check (15 rules, English and Roman-script Hinglish) runs before classification. A match records the number, sends a fixed confirmation and alerts Slack.
- **Why:** it is testable offline (checked on hand-written phrases during development; the cases are not committed), cannot be talked out of its behaviour by a message, and still works when the model call fails. The earlier design relied on the classifier returning ESCALATE; in that version the customer got an ordinary "a team member will get back to you" reply and the next follow-up still went out.
- **Cost:** rules are narrow. Devanagari-script opt-outs are not matched, the Hinglish list is unvalidated on real customers, and one false positive is known ("remove me from tomorrow's slot").

### 17. The opt-out lookup in WF1 fails closed
- **Decision:** if WF1 cannot read `opt_outs`, it sends nothing and raises an alert.
- **Why:** an error must never turn into a message to someone who may have opted out. The cost is a skipped follow-up, which is recoverable.
- **Status:** the failure path itself has not been tested live.

### 18. Opt-out scope is WhatsApp follow-ups only
- **Why:** Bolna's calls are outside this prototype's control. Stating the scope avoids a compliance claim the prototype cannot back.

## Security and infrastructure

### 19. Verify Twilio's signature inside the workflow
- **Decision:** WF2's first step recomputes the HMAC-SHA1 over the URL and sorted parameters and compares it with `X-Twilio-Signature`.
- **Why:** the endpoint is public, and without this anyone could post a fake reply.
- **Status:** valid signatures pass on real requests. Rejection of a forged signature was not recorded as tested.
- **Cost:** the auth token has to be available to a Code node, so it is held in an n8n variable. This is the only secret not kept in a credential.

### 20. Do not invent authentication for Bolna's unsigned webhook
- **Decision:** WF1 accepts any POST to its URL. Mitigations are the terminal-status filter, field validation and duplicate protection.
- **Why:** Bolna does not sign payloads. The only built-in option is a shared secret in a custom header, and a source-address check is possible but its reliability as a control was not established. A homemade scheme would give a false sense of safety.
- **Cost:** this is a real weakness, stated in the limitations. A shared-secret header or address check is the obvious next step.

### 21. Second Twilio account for this project
- **Why:** a sandbox allows only one "when a message comes in" URL. The other project on the same n8n instance already uses the first account's sandbox, so sharing it would break one of them. The sandbox is also free.
- **Cost:** a verified phone can be on at most three Twilio accounts, and the sandbox has its own limits (24-hour window, rejoin every three days).

### 22. Database access only through the service-role key, with RLS on and no policies
- **Why:** the tables hold customer phone numbers and message text. With row-level security on and no policies, the public (anon) key can read and write nothing. The workflows connect with the service-role key, which bypasses RLS.
- **Cost:** the service-role key must be kept secret and never exposed to a browser.

### 23. Reply handling stays in one place, alerts go through one formatter
- **Decision:** every alert in each workflow passes through a single Build Alert node and a single Slack node.
- **Why:** one format (type, phone, workflow, details, time, action needed) and one place to change it. Reply alerts show the classification, the model's short stated reason, any requested date or time text, and a truncated copy of the customer's reply. The reason and reply are free text, so they are display-only.

## Author's reasons

Two choices came down to the author's circumstances rather than to a technical comparison. They are stated here in the author's own words.

- **OpenAI for classification.** "I chose the OpenAI API for classification because I already had enough credits in my OpenAI account." Nothing in the design depends on this choice: decision 15 keeps the provider behind an adapter, so changing it means changing the HTTP call and the line that reads the answer.
- **n8n instead of writing code.** "I used n8n because it is an orchestration platform and it makes it easy to build what I need."
