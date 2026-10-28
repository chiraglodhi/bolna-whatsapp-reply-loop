-- ============================================================================
-- Bolna WhatsApp Reply Loop: database schema (PostgreSQL / Supabase)
--
-- Reconstructed from the live database (information_schema, pg_constraint,
-- pg_indexes, pg_trigger, pg_get_functiondef), so it matches what the
-- workflows actually ran against.
--
-- Access model: Row Level Security is ENABLED on every table with NO policies.
-- That denies all access to the anon/authenticated roles. The n8n workflows
-- connect with the service_role key, which bypasses RLS. Never expose these
-- tables through the anon key.
--
-- Phone numbers are stored in E.164 (+<country code><number>). Normalisation
-- happens in the workflows before insert; opt_outs enforces the format in the
-- database as well.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Shared trigger function: keep updated_at current on every UPDATE.
-- search_path is pinned to '' so the function cannot be hijacked through a
-- schema earlier in the path (Supabase security advisor recommendation).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- bolna_call_contexts: one row per Bolna call (terminal-status webhook).
-- This is the context the reply handler looks up when a customer answers
-- the post-call WhatsApp message.
-- ----------------------------------------------------------------------------
CREATE TABLE public.bolna_call_contexts (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Bolna execution id. UNIQUE = idempotency key: a repeated webhook
    -- delivery upserts the same row instead of creating a duplicate.
    execution_id            text        NOT NULL UNIQUE,
    agent_id                text        NOT NULL,
    batch_id                text,
    status                  text        NOT NULL,           -- terminal Bolna status
    smart_status            text,

    -- 0 means no conversation took place. The WhatsApp follow-up is gated on > 0.
    conversation_duration   integer     NOT NULL DEFAULT 0,
    answered_by_voice_mail  boolean              DEFAULT false,

    customer_phone          text        NOT NULL,           -- E.164
    agent_phone             text,
    transcript              text,
    summary                 text,                           -- null unless Call Summary is enabled in Bolna

    -- Nested: extracted_data[Category][ExtractionName] -> {objective, subjective, confidence, ...}
    extracted_data          jsonb                DEFAULT '{}'::jsonb,

    telephony_provider      text,
    hangup_by               text,
    hangup_reason           text,
    recording_url           text,                           -- null when PII masking is on
    total_cost_cents        integer              DEFAULT 0, -- Bolna reports cents

    -- Outbound follow-up (WF1)
    whatsapp_sent           boolean              DEFAULT false,
    whatsapp_sent_at        timestamptz,
    whatsapp_message_sid    text,
    whatsapp_send_error     text,

    -- Inbound reply roll-up (WF2)
    reply_received          boolean              DEFAULT false,
    reply_count             integer              DEFAULT 0,
    last_reply_at           timestamptz,
    current_intent          text,                           -- CONFIRM | RESCHEDULE | QUESTION | OBJECTION | ESCALATE
    intent_confidence       real,                           -- 0..1
    escalated               boolean              DEFAULT false,
    escalated_at            timestamptz,

    created_at              timestamptz          DEFAULT now(),
    updated_at              timestamptz          DEFAULT now()
);

COMMENT ON TABLE  public.bolna_call_contexts IS 'One row per Bolna call. Written by WF1, read and updated by WF2.';
COMMENT ON COLUMN public.bolna_call_contexts.execution_id IS 'Bolna execution id; UNIQUE so webhook retries upsert instead of duplicating.';
COMMENT ON COLUMN public.bolna_call_contexts.conversation_duration IS '0 = no conversation. WhatsApp follow-up is only sent when > 0.';
COMMENT ON COLUMN public.bolna_call_contexts.extracted_data IS 'Nested Bolna extraction output: [Category][Name] -> {objective, subjective, confidence, ...}.';
COMMENT ON COLUMN public.bolna_call_contexts.total_cost_cents IS 'Cost as reported by Bolna, in cents.';

CREATE INDEX idx_call_contexts_created_at     ON public.bolna_call_contexts USING btree (created_at DESC);
-- Reply handler looks up the latest call for a sender by phone number.
CREATE INDEX idx_call_contexts_customer_phone ON public.bolna_call_contexts USING btree (customer_phone);
CREATE INDEX idx_call_contexts_reply_received ON public.bolna_call_contexts USING btree (reply_received);
CREATE INDEX idx_call_contexts_status         ON public.bolna_call_contexts USING btree (status);
-- Partial index: only rows still waiting for a follow-up stay in the index.
CREATE INDEX idx_call_contexts_whatsapp_unsent ON public.bolna_call_contexts USING btree (whatsapp_sent) WHERE (whatsapp_sent = false);

CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.bolna_call_contexts
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.bolna_call_contexts ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- whatsapp_replies: one row per inbound WhatsApp message (Twilio webhook).
-- ----------------------------------------------------------------------------
CREATE TABLE public.whatsapp_replies (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Twilio MessageSid. UNIQUE = idempotency key for Twilio webhook retries.
    message_sid             text        NOT NULL UNIQUE,

    -- Nullable on purpose: a reply from a number with no known call is still
    -- stored (matched_to_call = false) and raised as an unknown-sender alert.
    call_context_id        uuid        REFERENCES public.bolna_call_contexts (id),

    sender_phone            text        NOT NULL,           -- E.164, "whatsapp:" prefix stripped
    message_body            text        NOT NULL,           -- untrusted customer text
    profile_name            text,                           -- WhatsApp display name from Twilio

    -- Classification (OpenAI, strict JSON schema, validated in code)
    classified_intent       text,                           -- CONFIRM | RESCHEDULE | QUESTION | OBJECTION | ESCALATE
    intent_confidence       real,                           -- 0..1
    classification_details  jsonb,                          -- full validated model output
    classification_model    text,
    classification_error    text,
    used_fallback           boolean              DEFAULT false, -- true = safe-default ESCALATE after LLM failure

    -- Template-only customer response
    response_sent           boolean              DEFAULT false,
    response_text           text,
    response_message_sid    text,
    response_sent_at        timestamptz,
    response_error          text,

    matched_to_call         boolean              DEFAULT false,
    processing_status       text                 DEFAULT 'received',
    slack_alerted           boolean              DEFAULT false,

    created_at              timestamptz          DEFAULT now(),
    updated_at              timestamptz          DEFAULT now()
);

COMMENT ON TABLE  public.whatsapp_replies IS 'One row per inbound WhatsApp message. Written and updated by WF2.';
COMMENT ON COLUMN public.whatsapp_replies.message_sid IS 'Twilio MessageSid; UNIQUE so webhook retries are detected and skipped.';
COMMENT ON COLUMN public.whatsapp_replies.call_context_id IS 'NULL when the sender matches no known call (unknown sender).';
COMMENT ON COLUMN public.whatsapp_replies.used_fallback IS 'True when the model output failed validation twice and ESCALATE was applied by default.';
COMMENT ON COLUMN public.whatsapp_replies.response_text IS 'Template text actually sent. Model-suggested replies are never sent.';

CREATE INDEX idx_replies_call_context ON public.whatsapp_replies USING btree (call_context_id);
CREATE INDEX idx_replies_created_at   ON public.whatsapp_replies USING btree (created_at DESC);
CREATE INDEX idx_replies_intent       ON public.whatsapp_replies USING btree (classified_intent);
CREATE INDEX idx_replies_processing   ON public.whatsapp_replies USING btree (processing_status);
CREATE INDEX idx_replies_sender_phone ON public.whatsapp_replies USING btree (sender_phone);

CREATE TRIGGER set_replies_updated_at
    BEFORE UPDATE ON public.whatsapp_replies
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.whatsapp_replies ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- opt_outs: numbers that must not receive WhatsApp follow-ups.
-- Scope: this prototype's WhatsApp follow-ups only. Not a compliance claim.
-- WF1 checks this table before sending and fails closed if the lookup errors.
-- ----------------------------------------------------------------------------
CREATE TABLE public.opt_outs (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    phone               text        NOT NULL UNIQUE
                        CONSTRAINT opt_outs_phone_check CHECK (phone ~ '^\+[0-9]{8,15}$'),
    source_message_sid  text,                               -- the inbound message that triggered the opt-out
    matched_phrase      text,                               -- which keyword rule matched
    created_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.opt_outs IS 'Numbers that asked to stop WhatsApp follow-ups. Insert-only; no updated_at.';
COMMENT ON COLUMN public.opt_outs.phone IS 'E.164. The CHECK constraint rejects anything that is not +<8-15 digits>.';

ALTER TABLE public.opt_outs ENABLE ROW LEVEL SECURITY;
