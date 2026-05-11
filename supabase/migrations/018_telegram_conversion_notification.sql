-- ============================================================
-- 018: Single Telegram notification for client wallet conversions
-- ============================================================
-- Контекст: trigger trg_notify_client_transaction (миграция 015) шлёт
-- по одному сообщению на каждый INSERT в client_transactions.  Атомарная
-- конвертация (миграция 017, public.convert_client_currency) создаёт ДВЕ
-- ноги (debit + deposit) с общим conversion_id, поэтому клиент получал
-- в Telegram два уведомления подряд («СНЯТИЕ» и «ПОПОЛНЕНИЕ»), что
-- выглядит как ошибка.
--
-- Решение: переписываем notify_client_transaction так, чтобы при
-- `conversion_id IS NOT NULL` триггер пропускал debit-ногу и слал ровно
-- одно сообщение «🔄 КОНВЕРТАЦИЯ» из deposit-ноги.  К этому моменту обе
-- проводки уже записаны и client_balances содержит финальный остаток,
-- поэтому fmt_client_total_balance возвращает правильную сумму.
--
-- Идемпотентно: миграция CREATE OR REPLACE — повторное применение
-- безопасно.  Триггер не пересоздаём (он по имени привязан к функции).
-- ============================================================

CREATE OR REPLACE FUNCTION private.notify_client_transaction()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  -- shared
  v_client       public.clients%ROWTYPE;
  v_user_name    text := 'Сотрудник';
  v_branch_name  text := '';
  v_total_balance text;
  v_text         text;

  -- conversion-only
  v_conv_meta    jsonb;
  v_from_cur     text;
  v_to_cur       text;
  v_from_amount  double precision;
  v_to_amount    double precision;
  v_rate         double precision;
  v_rate_str     text;

  -- regular-only
  v_balance_before double precision;
  v_title        text;
  v_emoji        text;
  v_sign         text;
  v_arrow        text;
BEGIN
  ----------------------------------------------------------------
  -- Skip the debit leg of a conversion: the deposit leg will produce
  -- a single unified message after both legs are inserted.
  ----------------------------------------------------------------
  IF NEW.conversion_id IS NOT NULL AND NEW.type IS DISTINCT FROM 'deposit' THEN
    RETURN NEW;
  END IF;

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

  v_total_balance := private.fmt_client_total_balance(NEW.client_id);

  ----------------------------------------------------------------
  -- Conversion branch: build the unified «🔄 КОНВЕРТАЦИЯ» message
  -- using conversion_meta from the deposit leg.  Falls back to
  -- NEW.currency if any meta field is missing/empty.
  ----------------------------------------------------------------
  IF NEW.conversion_id IS NOT NULL THEN
    v_conv_meta := COALESCE(NEW.conversion_meta, '{}'::jsonb);

    v_from_cur    := COALESCE(NULLIF(v_conv_meta->>'from', ''), NEW.currency);
    v_to_cur      := COALESCE(NULLIF(v_conv_meta->>'to',   ''), NEW.currency);
    v_from_amount := COALESCE((v_conv_meta->>'fromAmount')::double precision, 0);
    v_to_amount   := COALESCE((v_conv_meta->>'toAmount')::double precision, NEW.amount);
    v_rate        := COALESCE((v_conv_meta->>'rate')::double precision, 0);

    -- Format rate with reasonable decimals (4 for sub-10, 2 otherwise).
    -- Buffer is generous (12 leading digits) so very large pairs never
    -- overflow into '########'.
    IF v_rate > 0 THEN
      v_rate_str := CASE
        WHEN v_rate < 10 THEN trim(to_char(v_rate, 'FM999999999990.0000'))
        ELSE                  trim(to_char(v_rate, 'FM999999999990.00'))
      END;
    ELSE
      v_rate_str := '';
    END IF;

    v_text :=
      '🔄 <b>КОНВЕРТАЦИЯ</b>' || E'\n' ||
      '━━━━━━━━━━━━━━━' || E'\n' ||
      '💼 Общий баланс: <b>' || v_total_balance || '</b>' || E'\n' ||
      '─────────────' || E'\n' ||
      '👤 ' || private.html_escape(v_client.name) || E'\n' ||
      '➖ Списано: <b>' || private.fmt_money(v_from_amount, v_from_cur)
        || '</b>' || E'\n' ||
      '➕ Зачислено: <b>' || private.fmt_money(v_to_amount, v_to_cur)
        || '</b>' || E'\n' ||
      (CASE WHEN v_rate_str <> ''
         THEN '📈 Курс: 1 ' || v_from_cur || ' = ' || v_rate_str || ' ' || v_to_cur || E'\n'
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
  END IF;

  ----------------------------------------------------------------
  -- Regular deposit / debit branch (preserved from migration 015).
  ----------------------------------------------------------------
  v_balance_before := coalesce(NEW.balance_after, 0)
    + (CASE WHEN NEW.type = 'deposit' THEN -NEW.amount ELSE NEW.amount END);

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
  -- Уведомления — best-effort: ошибка отправки не должна откатывать
  -- бизнес-транзакцию (саму проводку клиента).
  RAISE WARNING 'tg notify (client_transaction) failed: %', SQLERRM;
  RETURN NEW;
END $$;

COMMENT ON FUNCTION private.notify_client_transaction() IS
  'Telegram-уведомление об операции клиента. Для конвертаций (conversion_id IS NOT NULL) '
  'шлёт одно унифицированное сообщение из deposit-ноги, debit-нога пропускается. '
  'Для обычных deposit/debit — формат с балансом до/после, описанием и кодом операции.';
