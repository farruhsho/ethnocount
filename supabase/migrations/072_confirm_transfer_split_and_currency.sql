-- ============================================================
-- 072: confirm_transfer — свежий курс при смене валюты (#8)
--       + поддержка раздачи на несколько счетов (#5 split)
-- ============================================================
-- Базируется на 049_confirm_transfer_flexible_currency.sql.
--
-- ── #8 (валюта) ──────────────────────────────────────────────
--   Раньше: если валюта выбранного счёта отличалась от to_currency,
--   функция переписывала to_currency и пересчитывала
--   converted_amount = amount * exchange_rate, где exchange_rate —
--   СТАРЫЙ курс с момента создания (049:74-88). Это «прилипший»
--   курс — за время до приёма он мог устареть.
--   Теперь: при расхождении валют берём СВЕЖИЙ курс из таблицы
--   exchange_rates для пары (currency → валюта счёта). Если актуальной
--   строки курса для пары нет — RAISE EXCEPTION (не молчим, не
--   переиспользуем устаревший курс). Случай «валюта счёта = валюта
--   отправителя» — это без конвертации: rate=1, converted=amount.
--
-- ── #5 (split) ───────────────────────────────────────────────
--   Новый необязательный параметр p_to_account_splits jsonb — массив
--   объектов {"account_id":"<uuid>","amount":<numeric>}. КОНТРАКТ
--   синхронизирован с Dart (transfer_remote_ds.dart:310-318).
--   Когда p_to_account_splits IS NOT NULL:
--     (a) SUM(amount) == converted_amount в пределах 0.01, иначе RAISE;
--     (b) каждый account_id принадлежит принимающему филиалу
--         (to_branch_id) и в валюте выплаты, иначе RAISE;
--     затем раскладываем аллокации по счетам (loop) — сохраняем в
--     transfer_parts, первичный счёт пишем в to_account_id.
--   Когда p_to_account_splits IS NULL — поведение ровно как раньше
--   (один счёт через p_to_account_id).
--
-- Сигнатуру меняем (добавляется параметр) → DROP старой
-- private.confirm_transfer(uuid, text), затем CREATE новой,
-- затем GRANT. Публичную обёртку из 010 тоже пересоздаём под новую
-- сигнатуру (DROP + CREATE), т.к. Dart вызывает public.confirm_transfer
-- с тремя именованными параметрами.
--
-- ⚠ Идемпотентно в пределах BEGIN/COMMIT.
-- ============================================================

BEGIN;

-- ── приватная функция: пересоздаём под новую сигнатуру ──
DROP FUNCTION IF EXISTS private.confirm_transfer(uuid, text);

CREATE OR REPLACE FUNCTION private.confirm_transfer(
  p_transfer_id uuid,
  p_to_account_id text DEFAULT NULL,
  p_to_account_splits jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_effective_to text;
  v_to_currency text;
  v_acc_currency text;
  v_code text;
  v_rate double precision;
  v_new_converted double precision;
  v_currency_changed boolean := false;
  v_is_split boolean := (p_to_account_splits IS NOT NULL
                         AND jsonb_typeof(p_to_account_splits) = 'array'
                         AND jsonb_array_length(p_to_account_splits) > 0);
  v_split_sum double precision := 0;
  v_split_count int := 0;
  v_split jsonb;
  v_split_acc uuid;
  v_split_amt double precision;
  v_split_curr text;
  v_split_branch uuid;
  v_first_acc text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'created' THEN
    RAISE EXCEPTION 'Transfer not in created state (current: %)', v_transfer.status;
  END IF;

  v_to_currency := COALESCE(NULLIF(v_transfer.to_currency, ''), v_transfer.currency);
  v_rate := COALESCE(v_transfer.exchange_rate, 1);

  -- ── Выбор счёта(-ов) приёма ──
  IF v_is_split THEN
    -- Раздача на несколько счетов: account_id из p_to_account_splits.
    -- to_account_id уже зафиксированный при создании (если был) НЕ
    -- переопределяет split — оператор осознанно выбрал несколько счетов.
    SELECT (elem->>'account_id')
      INTO v_first_acc
      FROM jsonb_array_elements(p_to_account_splits) AS elem
      LIMIT 1;
    IF v_first_acc IS NULL OR v_first_acc = '' THEN
      RAISE EXCEPTION 'Split: первый счёт получателя не указан';
    END IF;
    v_effective_to := v_first_acc;
  ELSE
    v_effective_to := CASE
      WHEN v_transfer.to_account_id IS NOT NULL AND v_transfer.to_account_id <> ''
        THEN v_transfer.to_account_id
      ELSE COALESCE(p_to_account_id, '')
    END;
  END IF;

  IF v_effective_to = '' THEN
    RAISE EXCEPTION 'Счёт получателя не указан';
  END IF;

  SELECT currency INTO v_acc_currency
    FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_acc_currency IS NULL THEN
    RAISE EXCEPTION 'Счёт получателя не найден';
  END IF;

  -- ── #8: свежий курс при расхождении валют ──
  -- Если выбранный счёт в другой валюте, чем to_currency перевода,
  -- мягко выравниваем to_currency и пересчитываем converted_amount,
  -- но курс берём СВЕЖИЙ из exchange_rates, а не прилипший create-time.
  IF v_acc_currency <> v_to_currency THEN
    v_currency_changed := true;
    IF v_acc_currency = v_transfer.currency THEN
      -- Без конвертации: валюта счёта = валюта отправителя.
      v_rate := 1;
      v_new_converted := v_transfer.amount;
    ELSE
      -- Свежий курс для пары (валюта отправителя → валюта счёта).
      -- Никакого inverse-fallback: нужна явная актуальная строка курса.
      SELECT rate INTO v_rate
        FROM exchange_rates
        WHERE from_currency = v_transfer.currency
          AND to_currency = v_acc_currency
        ORDER BY effective_at DESC
        LIMIT 1;
      IF v_rate IS NULL OR v_rate <= 0 THEN
        RAISE EXCEPTION 'Нет актуального курса для пары % → % — приём невозможен без свежего курса',
          v_transfer.currency, v_acc_currency;
      END IF;
      v_new_converted := v_transfer.amount * v_rate;
    END IF;
    v_to_currency := v_acc_currency;
  ELSE
    v_new_converted := v_transfer.converted_amount;
  END IF;

  -- ── #5: валидация split-аллокаций ──
  IF v_is_split THEN
    FOR v_split IN SELECT * FROM jsonb_array_elements(p_to_account_splits)
    LOOP
      v_split_acc := (v_split->>'account_id')::uuid;
      v_split_amt := (v_split->>'amount')::double precision;
      IF v_split_acc IS NULL THEN
        RAISE EXCEPTION 'Split: пустой account_id в аллокации';
      END IF;
      IF v_split_amt IS NULL OR v_split_amt <= 0 THEN
        RAISE EXCEPTION 'Split: некорректная сумма для счёта %', v_split_acc;
      END IF;

      SELECT currency, branch_id INTO v_split_curr, v_split_branch
        FROM branch_accounts WHERE id = v_split_acc;
      IF v_split_curr IS NULL THEN
        RAISE EXCEPTION 'Split: счёт % не найден', v_split_acc;
      END IF;
      -- (b) счёт принадлежит принимающему филиалу и в валюте выплаты.
      IF v_split_branch <> v_transfer.to_branch_id THEN
        RAISE EXCEPTION 'Split: счёт % не принадлежит принимающему филиалу', v_split_acc;
      END IF;
      IF v_split_curr <> v_to_currency THEN
        RAISE EXCEPTION 'Split: валюта счёта % (%) ≠ валюта выплаты %',
          v_split_acc, v_split_curr, v_to_currency;
      END IF;

      v_split_sum := v_split_sum + v_split_amt;
      v_split_count := v_split_count + 1;
    END LOOP;

    -- (a) сумма аллокаций == converted_amount в пределах 0.01.
    IF abs(v_split_sum - v_new_converted) > 0.01 THEN
      RAISE EXCEPTION 'Split: сумма аллокаций % ≠ сумма выплаты % (разница вне допуска 0.01)',
        v_split_sum, v_new_converted;
    END IF;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

  UPDATE transfers SET
    status        = 'toDelivery',
    confirmed_by  = v_user_id,
    confirmed_at  = now(),
    to_account_id = v_effective_to,
    to_currency   = v_to_currency,
    exchange_rate = v_rate,
    converted_amount = v_new_converted,
    -- Раскладка по счетам (split) сохраняется в transfer_parts, чтобы
    -- этап выдачи (issuance) знал per-account аллокации. Для одиночного
    -- счёта остаётся NULL — поведение как раньше.
    transfer_parts = CASE
      WHEN v_is_split THEN p_to_account_splits
      ELSE transfer_parts
    END,
    amendment_history = CASE
      WHEN v_currency_changed OR v_is_split THEN
        COALESCE(amendment_history, '[]'::jsonb) ||
        jsonb_build_array(jsonb_build_object(
          'at',     now(),
          'userId', v_user_id::text,
          'kind',   CASE
                      WHEN v_currency_changed AND v_is_split THEN 'currency_aligned_and_split_on_confirm'
                      WHEN v_currency_changed THEN 'currency_aligned_on_confirm'
                      ELSE 'split_on_confirm'
                    END,
          'changes', jsonb_build_object(
            'fromToCurrency', COALESCE(NULLIF(v_transfer.to_currency, ''), v_transfer.currency),
            'toToCurrency',   v_to_currency,
            'rate',           v_rate,
            'newConverted',   v_new_converted,
            'accountId',      v_effective_to,
            'splits',         CASE WHEN v_is_split THEN p_to_account_splits ELSE NULL END
          )
        ))
      ELSE amendment_history
    END
  WHERE id = p_transfer_id;

  -- Sync pending sender ledger description — отражает приёмку, без денег.
  UPDATE ledger_entries
     SET description = 'Перевод ' || v_code || ' принят (в пути)'
   WHERE reference_type = 'transfer'
     AND reference_id = p_transfer_id::text
     AND branch_id = v_transfer.from_branch_id
     AND type = 'debit';

  IF v_transfer.commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (p_transfer_id, v_transfer.from_branch_id, v_transfer.commission,
            COALESCE(NULLIF(v_transfer.commission_currency, ''), v_transfer.currency),
            COALESCE(v_transfer.commission_type, 'fixed'), now());
  END IF;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_transfer.from_branch_id::text,
      'transfer_confirmed',
      'Перевод ' || v_code || ' принят',
      'Получатель подтвердил приём — деньги в транзите до выдачи клиенту.'
        || CASE WHEN v_currency_changed
                THEN ' Валюта получения изменена на ' || v_to_currency || '.'
                ELSE '' END
        || CASE WHEN v_is_split
                THEN ' Раздача на ' || v_split_count || ' счетов.'
                ELSE '' END,
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'currencyChanged', v_currency_changed,
        'split', v_is_split
      )
    ),
    (
      v_transfer.to_branch_id::text,
      'transfer_confirmed',
      'Перевод ' || v_code || ' ожидает выдачи',
      'Ожидает выдачи получателю: '
        || to_char(v_new_converted::numeric, 'FM999G999G990D00')
        || ' ' || v_to_currency,
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code
      )
    );

  RETURN jsonb_build_object(
    'success', true,
    'currencyChanged', v_currency_changed,
    'toCurrency', v_to_currency,
    'convertedAmount', v_new_converted,
    'split', v_is_split,
    'splitCount', v_split_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION private.confirm_transfer(uuid, text, jsonb) TO authenticated;

-- ── публичная обёртка: пересоздаём под новую сигнатуру ──
DROP FUNCTION IF EXISTS public.confirm_transfer(uuid, text);

CREATE OR REPLACE FUNCTION public.confirm_transfer(
  p_transfer_id uuid,
  p_to_account_id text DEFAULT NULL,
  p_to_account_splits jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.confirm_transfer(p_transfer_id, p_to_account_id, p_to_account_splits) $$;

REVOKE ALL ON FUNCTION public.confirm_transfer(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_transfer(uuid, text, jsonb) TO authenticated;

COMMIT;
