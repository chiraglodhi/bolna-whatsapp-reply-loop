# Demo script

This is a proposed proof of concept demonstrating how Bolna's post-call WhatsApp gap could be filled. It is not an official Bolna integration.

This is a recording checklist and shot list, not a narration script. What is said on the recording is up to the person recording.

**Target length:** 90 to 120 seconds. One phone plays the customer in every step, which is a limitation of the demo, not of the design.

## Before recording

### Accounts and workflows
- [ ] Both n8n workflows are published (production webhook URLs, not test URLs)
- [ ] The Bolna agent's webhook points to the WF1 production URL and was saved
- [ ] The Twilio sandbox "when a message comes in" URL points to the WF2 production URL
- [ ] OpenAI credential and the `BOLNA_LLM_MODEL` variable work (one earlier test reply classified)
- [ ] Slack alerts channel exists and the bot is a member
- [ ] n8n has enough executions left: a connected call is 3 to 5 executions, each reply about 1, and a retake costs the same again

### Phone and sandbox
- [ ] The phone joined the sandbox within the last 3 days (sandbox sessions expire after 3 days). If not, send `join <your sandbox keyword>` to the sandbox number
- [ ] The phone is verified in Bolna (trial accounts can only call verified numbers)
- [ ] The phone messaged the sandbox within the last 24 hours, ideally just before the take. Without that, the follow-up send fails (Twilio 21610 or 21608)
- [ ] No test message starts with the word "stop": the sandbox treats it as a sandbox opt-out and disconnects the phone

### Data and screen hygiene
- [ ] `opt_outs` is empty (a number in it makes WF1 skip the follow-up)
- [ ] Close or hide anything showing secrets: the Supabase API keys page, n8n credentials and variables, the Bolna API key in any HTTP client, `.env` files
- [ ] Decide whether the phone number is visible. If not, blur or crop it in every shot (Supabase rows, WhatsApp header, Slack alerts)
- [ ] Notifications off; no unrelated tabs or personal chats in frame
- [ ] Windows are arranged in advance: n8n executions, Supabase table editor, WhatsApp on the phone or WhatsApp Web, Slack

## Shot list

Times are targets for a 90 to 120 second cut. They are not a script.

| # | Shot | What must be visible | Target |
|---|---|---|---|
| 1 | Starting state | Supabase tables, empty or showing only earlier test rows; the three table names | 8 s |
| 2 | The workflows | n8n with both workflows published; scroll the node sequence of each | 12 s |
| 3 | Trigger the call | The call request being sent (agent ID and phone masked) and the phone ringing | 10 s |
| 4 | Take a short call | Phone on screen during a brief call; the call ends | 15 s |
| 5 | WF1 execution | The `completed` execution passing the terminal-status check and finishing | 10 s |
| 6 | Call stored | `bolna_call_contexts` row: status, duration, `whatsapp_sent` true | 8 s |
| 7 | Follow-up arrives | The WhatsApp message on the phone | 6 s |
| 8 | Reply | A short customer reply sent from the phone | 8 s |
| 9 | WF2 execution | Signature check, classification and template reply path | 12 s |
| 10 | Classified | `whatsapp_replies` row: intent, confidence, response text | 8 s |
| 11 | Reply on phone | The fixed-template answer arriving on WhatsApp | 5 s |
| 12 | Slack | The alert in the alerts channel | 8 s |
| 13 | Optional: opt-out | A second reply using an opt-out phrase; confirmation arrives; the opt-out alert and the `opt_outs` row | 15 s |

Total with shot 13: about 125 s. Without it: about 110 s. Cut shot 2 or shorten 4 if you need to trim.

## Test inputs

Use plain, normal-sounding customer replies; the system is meant to handle ordinary text.

- For the main path, a clear positive reply works well because it produces the most visible result: an immediate alert for a likely sale.
- For the opt-out shot, use a phrase the keyword rules match, for example one of the English or Roman-script Hinglish phrases listed in `prompts/optout-patterns.json`. Do not start it with "stop".
- Do the opt-out last. Once the number is in `opt_outs`, WF1 skips every later follow-up to it.
- Do not demo a Devanagari-script opt-out: it is a known gap (see the README limitations).

## If something goes wrong on camera

| Symptom | Likely cause | Fix |
|---|---|---|
| No follow-up message arrives | Phone has not messaged the sandbox in the last 24 h, or the 3-day join expired | Message the sandbox again or rejoin, then retake |
| Follow-up skipped, no error | The number is in `opt_outs`, or the call had `conversation_duration` 0 | Delete the `opt_outs` row; make sure someone actually speaks on the call |
| Reply gets no answer and Slack shows a signature alert | Auth token or webhook URL variable does not match the production URL Twilio calls | Fix the two n8n variables |
| Phone stops receiving sandbox messages after a test | A message started with "stop" | Rejoin the sandbox |
| Call request is refused | The number is not verified in Bolna, or the API key is wrong | Verify the number; recheck the key |

## After recording

- [ ] Delete the number from `opt_outs` if the opt-out shot was used (`delete from opt_outs where phone = '<test number>';`)
- [ ] Check the recording for visible secrets, full phone numbers, the agent ID, API keys, the n8n instance name and the Supabase project URL
- [ ] Revoke any Bolna API key that was created only for the demo
- [ ] Unpublish workflows that are no longer needed, so they stop using executions
- [ ] Add the recording link to the README
