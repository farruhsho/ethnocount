-- ============================================================
-- 049: relax currency check on confirm_transfer
-- ============================================================
-- Сценарий: перевод оформлен в UZS (currency='UZS'), у получающего
-- филиала нет UZS-счёта, только RUB. При accept бухгалтер выбирает
-- RUB-счёт и получает: «Счёт получателя в валюте RUB, перевод
-- оформлен в UZS» (P0001).
--
-- Что меняется:
--   • Жёсткая проверка `v_acc_currency <> v_transfer.to_currency`
--     убрана. Бухгалтер может принять перевод на счёт ЛЮБОЙ валюты
--     в своём филиале.
--   • Если валюта счёта отличается от `to_currency`, то функция:
--     1) обновляет `to_currency = v_acc_currency`,
--     2) пересчитывает `converted_amount = amount * exchange_rate`
--        (rate уже установлен при создании, оператор отвечает за
--        корректность).
--   • Аудит-запись в `amendment_history` фиксирует изменение, чтобы
--     директор видел: «бухгалтер сменил валюту получения при приёме».
--
-- Идемпотентно. CREATE OR REPLACE.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.confirm_transfer(
  p_transfer_id uuid,
  p_to_account_id text DEFAULT NULL
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
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'created' THEN
    RAISE EXCEPTION 'Transfer not in created state (current: %)', v_transfer.status;
  END IF;

  v_effective_to := CASE
    WHEN v_transfer.to_account_id IS NOT NULL AND v_transfer.to_account_id <> ''
      THEN v_transfer.to_account_id
    ELSE COALESCE(p_to_account_id, '')
  END;
  IF v_effective_to = '' THEN
    RAISE EXCEPTION 'Счёт получателя не указан';
  END IF;

  SELECT currency INTO v_acc_currency
    FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_acc_currency IS NULL THEN
    RAISE EXCEPTION 'Счёт получателя не найден';
  END IF;

  v_to_currency := COALESCE(NULLIF(v_transfer.to_currency, ''), v_transfer.currency);
  v_rate := COALESCE(v_transfer.exchange_rate, 1);

  -- KEY CHANGE: вместо строгой проверки — мягкое выравнивание.
  -- Если выбранный счёт в другой валюте, обновляем to_currency
  -- и пересчитываем converted_amount по существующему курсу.
  IF v_acc_currency <> v_to_currency THEN
    v_currency_changed := true;
    -- Если account_currency совпадает с currency (отправителя), то
    -- это «без конвертации»: rate=1, converted = amount. Иначе курс
    -- остаётся прежним (оператор уже выставил его при создании).
    IF v_acc_currency = v_transfer.currency THEN
      v_rate := 1;
      v_new_converted := v_transfer.amount;
    ELSE
      v_new_converted := v_transfer.amount * v_rate;
    END IF;
    v_to_currency := v_acc_currency;
  ELSE
    v_new_converted := v_transfer.converted_amount;
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
    amendment_history = CASE
      WHEN v_currency_changed THEN
        COALESCE(amendment_history, '[]'::jsonb) ||
        jsonb_build_array(jsonb_build_object(
          'at',     now(),
          'userId', v_user_id::text,
          'kind',   'currency_aligned_on_confirm',
          'changes', jsonb_build_object(
            'fromToCurrency', COALESCE(NULLIF(v_transfer.to_currency, ''), v_transfer.currency),
            'toToCurrency',   v_to_currency,
            'rate',           v_rate,
            'newConverted',   v_new_converted,
            'accountId',      v_effective_to
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
                ELSE '' END,
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'currencyChanged', v_currency_changed
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
    'convertedAmount', v_new_converted
  );
END;
$$;

GRANT EXECUTE ON FUNCTION private.confirm_transfer(uuid, text) TO authenticated;

COMMIT;
