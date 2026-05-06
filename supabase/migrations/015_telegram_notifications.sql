-- ============================================================
-- 015: Telegram notifications for client transactions and purchases
-- ============================================================
-- Уведомления в Telegram-группу клиента при:
--   * пополнении счёта (client_transactions.type = 'deposit')
--   * снятии со счёта (client_transactions.type = 'debit')
--   * выкупе/покупке (purchases — если NEW.client_id указан)
--
-- Архитектура:
--   * `pg_net.http_post` — асинхронный POST к Telegram Bot API.
--   * Токен бота в private.app_secrets (name='telegram_bot_token').
--   * chat_id группы — в clients.telegram_chat_id.
--   * Триггеры AFTER INSERT не падают сам INSERT при сбое уведомления.
--
-- Идемпотентно — безопасно перезапускать.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Extensions + schema
-- ─────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS telegram_chat_id text;

CREATE TABLE IF NOT EXISTS private.app_secrets (
  name text PRIMARY KEY,
  value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────
-- 2. Helpers
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.get_secret(p_name text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp
AS $$ SELECT value FROM private.app_secrets WHERE name = p_name LIMIT 1 $$;

CREATE OR REPLACE FUNCTION private.fmt_money(p_amount double precision, p_currency text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_temp AS $$
  SELECT trim(to_char(coalesce(p_amount, 0), 'FM999G999G999G990D00'))
       || ' ' || coalesce(p_currency, '')
$$;

CREATE OR REPLACE FUNCTION private.html_escape(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_temp AS $$
  SELECT replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- Общий баланс клиента по всем валютам в одну строку
CREATE OR REPLACE FUNCTION private.fmt_client_total_balance(p_client_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_balances jsonb;
  v_parts text[] := '{}';
  v_key text;
  v_val numeric;
BEGIN
  SELECT balances INTO v_balances
    FROM public.client_balances WHERE client_id = p_client_id;
  IF v_balances IS NULL THEN RETURN '0'; END IF;
  FOR v_key, v_val IN
    SELECT key, (value)::numeric FROM jsonb_each_text(v_balances) AS t(key, value)
  LOOP
    IF abs(v_val) > 0.001 THEN
      v_parts := v_parts || private.fmt_money(v_val::double precision, v_key);
    END IF;
  END LOOP;
  IF array_length(v_parts, 1) IS NULL THEN RETURN '0'; END IF;
  RETURN array_to_string(v_parts, ', ');
END $$;

-- Отправить сообщение в Telegram (fire-and-forget). Возвращает request_id pg_net.
CREATE OR REPLACE FUNCTION private.tg_send(p_chat_id text, p_text text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = private, public, net, pg_temp
AS $$
DECLARE
  v_token text := private.get_secret('telegram_bot_token');
  v_request_id bigint;
BEGIN
  IF v_token IS NULL OR v_token = ''
     OR p_chat_id IS NULL OR p_chat_id = ''
     OR p_text IS NULL OR p_text = '' THEN
    RETURN NULL;
  END IF;

  -- pg_net создаёт схему `net`, не `extensions.net`. Использовать
  -- `extensions.net.http_post` нельзя — Postgres воспринимает это как
  -- database.schema.function и падает с "cross-database references...".
  SELECT net.http_post(
    url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'chat_id', p_chat_id,
      'text', p_text,
      'parse_mode', 'HTML',
      'disable_web_page_preview', true
    )
  ) INTO v_request_id;

  RETURN v_request_id;
END $$;

-- ─────────────────────────────────────────────────────────────
-- 3. Триггер: уведомления о пополнении/снятии
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.notify_client_transaction()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_client public.clients%ROWTYPE;
  v_user_name text := 'Сотрудник';
  v_branch_name text := '';
  v_balance_before double precision;
  v_total_balance text;
  v_title text;
  v_emoji text;
  v_sign text;
  v_arrow text;
  v_text text;
BEGIN
  SELECT * INTO v_client FROM public.clients WHERE id = NEW.client_id;
  IF NOT FOUND
     OR v_client.telegram_chat_id IS NULL
     OR v_client.telegram_chat_id = '' THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(NULLIF(display_name, ''), email, 'Сотрудник')
    INTO v_user_name
    FROM public.users WHERE id = NEW.created_by;

  IF v_client.branch_id IS NOT NULL AND v_client.branch_id <> '' THEN
    BEGIN
      SELECT name INTO v_branch_name
        FROM public.branches WHERE id = v_client.branch_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_branch_name := '';
    END;
  END IF;

  v_balance_before := coalesce(NEW.balance_after, 0)
    + (CASE WHEN NEW.type = 'deposit' THEN -NEW.amount ELSE NEW.amount END);

  v_total_balance := private.fmt_client_total_balance(NEW.client_id);

  IF NEW.type = 'deposit' THEN
    v_title := 'ПОПОЛНЕНИЕ';
    v_emoji := '💰';
    v_sign  := '+';
    v_arrow := '➕';
  ELSE
    v_title := 'СНЯТИЕ СО СЧЁТА';
    v_emoji := '💸';
    v_sign  := '−';
    v_arrow := '➖';
  END IF;

  v_text :=
    v_emoji || ' <b>' || v_title || '</b>' || E'\n' ||
    '━━━━━━━━━━━━━━━' || E'\n' ||
    '💼 Общий баланс: <b>' || v_total_balance || '</b>' || E'\n' ||
    '─────────────' || E'\n' ||
    '👤 ' || private.html_escape(v_client.name) || E'\n' ||
    v_arrow || ' Сумма: <b>' || v_sign
      || private.fmt_money(NEW.amount, NEW.currency) || '</b>' || E'\n' ||
    '📊 Было: ' || private.fmt_money(v_balance_before, NEW.currency)
      || ' → Стало: ' || private.fmt_money(NEW.balance_after, NEW.currency) || E'\n' ||
    (CASE WHEN coalesce(NEW.description, '') <> ''
       THEN '📝 ' || private.html_escape(NEW.description) || E'\n'
       ELSE '' END) ||
    '─────────────' || E'\n' ||
    (CASE WHEN coalesce(NEW.transaction_code, '') <> ''
       THEN '🧾 Код: <code>' || NEW.transaction_code || '</code>' || E'\n'
       ELSE '' END) ||
    (CASE WHEN coalesce(v_branch_name, '') <> ''
       THEN '🏢 ' || private.html_escape(v_branch_name) || E'\n'
       ELSE '' END) ||
    '👨‍💼 ' || private.html_escape(v_user_name) || E'\n' ||
    '🕐 ' || to_char(NEW.created_at AT TIME ZONE 'Asia/Tashkent', 'DD.MM.YYYY HH24:MI');

  PERFORM private.tg_send(v_client.telegram_chat_id, v_text);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'tg notify (client_transaction) failed: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_notify_client_transaction ON public.client_transactions;
CREATE TRIGGER trg_notify_client_transaction
  AFTER INSERT ON public.client_transactions
  FOR EACH ROW EXECUTE FUNCTION private.notify_client_transaction();

-- ─────────────────────────────────────────────────────────────
-- 4. Триггер: уведомления о выкупе (purchases)
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.notify_purchase()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_client public.clients%ROWTYPE;
  v_user_name text := 'Сотрудник';
  v_branch_name text := '';
  v_total_balance text := '0';
  v_payments_lines text := '';
  v_payment jsonb;
  v_text text;
BEGIN
  IF NEW.client_id IS NULL OR NEW.client_id = '' THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT * INTO v_client FROM public.clients WHERE id = NEW.client_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN NEW;
  END;

  IF v_client.id IS NULL
     OR v_client.telegram_chat_id IS NULL
     OR v_client.telegram_chat_id = '' THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(NULLIF(display_name, ''), email, 'Сотрудник')
    INTO v_user_name
    FROM public.users WHERE id = NEW.created_by;

  SELECT name INTO v_branch_name FROM public.branches WHERE id = NEW.branch_id;

  v_total_balance := private.fmt_client_total_balance(v_client.id);

  FOR v_payment IN SELECT * FROM jsonb_array_elements(coalesce(NEW.payments, '[]'::jsonb)) LOOP
    v_payments_lines := v_payments_lines
      || '  • ' || private.html_escape(coalesce(v_payment->>'accountName', '—'))
      || '   <b>' || private.fmt_money(
            coalesce((v_payment->>'amount')::double precision, 0),
            coalesce(v_payment->>'currency', NEW.currency))
      || '</b>' || E'\n';
  END LOOP;

  v_text :=
    '🛒 <b>ВЫКУП</b>' || E'\n' ||
    '━━━━━━━━━━━━━━━' || E'\n' ||
    '💼 Баланс клиента: <b>' || v_total_balance || '</b>' || E'\n' ||
    '─────────────' || E'\n' ||
    '📦 ' || private.html_escape(NEW.description) || E'\n' ||
    (CASE WHEN coalesce(NEW.category, '') <> ''
       THEN '🏷 Категория: ' || private.html_escape(NEW.category) || E'\n'
       ELSE '' END) ||
    '👤 ' || private.html_escape(v_client.name) || E'\n' ||
    '💰 Сумма: <b>' || private.fmt_money(NEW.total_amount, NEW.currency) || '</b>' || E'\n' ||
    E'\n' ||
    '💳 Оплачено с касс:' || E'\n' || v_payments_lines ||
    '─────────────' || E'\n' ||
    (CASE WHEN coalesce(NEW.transaction_code, '') <> ''
       THEN '🧾 Код: <code>' || NEW.transaction_code || '</code>' || E'\n'
       ELSE '' END) ||
    (CASE WHEN coalesce(v_branch_name, '') <> ''
       THEN '🏢 ' || private.html_escape(v_branch_name) || E'\n'
       ELSE '' END) ||
    '👨‍💼 ' || private.html_escape(v_user_name) || E'\n' ||
    '🕐 ' || to_char(NEW.created_at AT TIME ZONE 'Asia/Tashkent', 'DD.MM.YYYY HH24:MI');

  PERFORM private.tg_send(v_client.telegram_chat_id, v_text);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'tg notify (purchase) failed: %', SQLERRM;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_notify_purchase ON public.purchases;
CREATE TRIGGER trg_notify_purchase
  AFTER INSERT ON public.purchases
  FOR EACH ROW EXECUTE FUNCTION private.notify_purchase();

-- ─────────────────────────────────────────────────────────────
-- 5. RPC для UI: задать telegram_chat_id клиента + тестовое сообщение
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.set_client_telegram_chat_id(
  p_client_id uuid,
  p_chat_id text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  UPDATE public.clients
     SET telegram_chat_id = NULLIF(trim(p_chat_id), '')
   WHERE id = p_client_id;
END $$;

CREATE OR REPLACE FUNCTION public.set_client_telegram_chat_id(
  p_client_id uuid,
  p_chat_id text
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.set_client_telegram_chat_id(p_client_id, p_chat_id) $$;

CREATE OR REPLACE FUNCTION private.send_telegram_test(p_client_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_chat_id text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  SELECT telegram_chat_id, name INTO v_chat_id, v_name
    FROM public.clients WHERE id = p_client_id;
  IF v_chat_id IS NULL OR v_chat_id = '' THEN
    RAISE EXCEPTION 'У клиента не указан telegram_chat_id';
  END IF;
  PERFORM private.tg_send(
    v_chat_id,
    '✅ <b>Тестовое сообщение</b>' || E'\n' ||
    'Группа клиента «' || private.html_escape(coalesce(v_name, '')) || '» успешно подключена.'
  );
END $$;

CREATE OR REPLACE FUNCTION public.send_telegram_test(p_client_id uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.send_telegram_test(p_client_id) $$;

REVOKE ALL ON FUNCTION public.set_client_telegram_chat_id(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_client_telegram_chat_id(uuid, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.send_telegram_test(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_telegram_test(uuid) TO authenticated, service_role;

-- ============================================================
-- ПОСЛЕ применения миграции:
--   1. (BotFather) Сделай /revoke токену, который засветился в чате,
--      и получи новый.
--   2. Сохрани новый токен в Supabase SQL editor:
--        INSERT INTO private.app_secrets (name, value)
--          VALUES ('telegram_bot_token', '<НОВЫЙ_ТОКЕН>')
--          ON CONFLICT (name) DO UPDATE
--            SET value = EXCLUDED.value, updated_at = now();
--   3. Для каждого клиента укажи chat_id его группы (через UI или SQL):
--        UPDATE public.clients SET telegram_chat_id = '-1001234567890'
--          WHERE id = '<client uuid>';
-- ============================================================
