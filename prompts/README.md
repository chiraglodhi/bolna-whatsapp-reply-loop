# Prompts and templates

Everything the system says or asks a model, extracted verbatim from the deployed n8n workflows.
The workflow JSON in `workflows/` is the source of truth; these files exist so the wording can be
read and reviewed without opening n8n.

| File | Used by | Purpose |
|---|---|---|
| `classifier-system-prompt.txt` | WF2, node "Build Classifier Request" | System prompt for intent classification |
| `classifier-user-template.txt` | WF2, same node | User message layout; `{{...}}` are filled from the database (transcript capped at 6000 chars, summary at 1000, each extracted answer at 200) |
| `classifier-output-schema.json` | WF2, same node | JSON Schema sent as OpenAI Structured Outputs (`strict: true`) |
| `customer-message-templates.json` | WF1 and WF2 | The only text ever sent to a customer |
| `optout-patterns.json` | WF2, node "Opt-Out Check" | Rule-based opt-out keywords (English and Roman-script Hinglish) |

## How the pieces fit

1. The reply is first checked against `optout-patterns.json`. A match records the opt-out and sends the fixed confirmation. The model is not involved.
2. Otherwise the reply is classified by the model using the prompt, template and schema above.
3. The model output is parsed and validated in code (allowed intent, confidence in 0 to 1, required fields). A confidence below 0.6 is overridden to ESCALATE. Invalid output is retried once, then falls back to ESCALATE with `used_fallback = true`.
4. The customer receives the fixed template for the validated intent. `suggested_reply` is stored for a human and never sent.

## Design notes

- Transcript, summary, extracted answers and the customer's reply are all treated as untrusted data (rule 3 in the system prompt). Code-level validation and template-only replies are the real defence; the prompt rule is a second layer, not the guarantee.
- The model ID is not in these files. It is an n8n variable (`BOLNA_LLM_MODEL`); see `.env.example`.
- The model is not given a temperature or token limit; those parameters were left out until verified for the chosen model.

## Known gaps

- Devanagari-script opt-outs are not caught by the keyword rules. In testing, the classifier labelled such a message ESCALATE, so a human was alerted, but the standard reply was sent instead of the opt-out confirmation and the number was not added to `opt_outs`.
- The Hinglish patterns were written by hand and checked on a few test messages, not validated on real customers.
- The low-confidence override has never fired on live traffic.
