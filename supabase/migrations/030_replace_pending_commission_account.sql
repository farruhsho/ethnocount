-- ============================================================
-- 030: replace_pending_transfer + commission_account_id
-- ============================================================
-- 024 переписывает pending-перевод (refund старый debit + новый debit),
-- но ничего не знает про commission_account_id из 027. Если оператор
-- редактирует pending-перевод, где комиссия списана со второго счёта,
-- или меняет режим — commission_charge на старом счёте остаётся «висеть».
--
-- Здесь:
--   * принимаем p_commission_account_id (может быть NULL);
--   * если старый режим был fromAccount — возвращаем v_old_commission
--     обратно на старый commission_account_id;
--   * если новый режим fromAccount — резервируем commission на (новом)
--     commission_account_id, проверяя баланс и валюту.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.replace_pending_transfer(
  p_transfer_id        uuid,
  p_from_account_id    uuid    DEFAULT NULL,
  p_amount             double precision DEFAULT NULL,
  p_currency           text    DEFAULT NULL,
  p_to_currency        text    DEFAULT NULL,
  p_exchange_rate      double precision DEFAULT NULL,
  p_commission_type    text    DEFAULT NULL,
  p_commission_value   double precision DEFAULT NULL,
  p_commission_currency text   DEFAULT NULL,
  p_commission_mode    text    DEFAULT NULL,
  p_to_account_id      text    DEFAULT NULL,
  p_description        text    DEFAULT NULL,
  p_client_id          text    DEFAULT NULL,
  p_sender_name        text    DEFAULT NULL,
  p_sender_phone       text    DEFAULT NULL,
  p_sender_info        text    DEFAULT NULL,
  p_receiver_name      text    DEFAULT NULL,
  p_receiver_phone     text    DEFAULT NULL,
  p_receiver_info      text    DEFAULT NULL,
  p_amendment_note     text    DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_t         transfers%ROWTYPE;
  v_new_from  uuid;
  v_old_total double precision;
  v_amount    double precision;
  v_currency  text;
  v_commission         double precision;
  v_commission_value   double precision;
  v_commission_type    text;
  v_commission_currency text;
  v_commission_mode    text;
  v_new_total double precision;
  v_balance   double precision;
  v_to_cur    text;
  v_rate      double precision;
  v_receiver  double precision;
  v_converted double precision;
  v_code      text;
  v_to_acc_branch uuid;
  v_changes   jsonb := '{}'::jsonb;
  v_now       timestamptz := now();
  -- Commission-account refactor:
  v_old_commission_acc uuid;
  v_new_commission_acc uuid;
  v_comm_acc_branch    uuid;
  v_comm_acc_currency  text;
  v_comm_acc_balance   double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  IF v_t.status <> 'created' THEN
    RAISE EXCEPTION 'Полное редактирование возможно только для статуса «создан» (текущий: %)', v_t.status;
  END IF;

  v_amount             := COALESCE(p_amount, v_t.amount);
  v_currency           := COALESCE(NULLIF(p_currency, ''), v_t.currency);
  v_to_cur             := COALESCE(NULLIF(p_to_currency, ''), v_t.to_currency, v_currency);
  v_rate               := COALESCE(p_exchange_rate, v_t.exchange_rate);
  v_commission_type    := COALESCE(NULLIF(p_commission_type, ''), v_t.commission_type);
  v_commission_value   := COALESCE(p_commission_value, v_t.commission_value);
  v_commission_currency:= COALESCE(NULLIF(p_commission_currency, ''),
                                   NULLIF(v_t.commission_currency, ''),
                                   v_currency);
  v_commission_mode    := COALESCE(NULLIF(p_commission_mode, ''), v_t.commission_mode);
  v_new_from           := COALESCE(p_from_account_id, v_t.from_account_id);
  v_old_commission_acc := v_t.commission_account_id;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  IF v_new_from <> v_t.from_account_id THEN
    PERFORM 1 FROM branch_accounts
      WHERE id = v_new_from AND branch_id = v_t.from_branch_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Новый счёт-источник не относится к филиалу отправителя';
    END IF;
  END IF;

  IF p_to_account_id IS NOT NULL AND p_to_account_id <> '' AND p_to_account_id <> v_t.to_account_id THEN
    SELECT branch_id INTO v_to_acc_branch
      FROM branch_accounts WHERE id = p_to_account_id::uuid;
    IF v_to_acc_branch IS NULL OR v_to_acc_branch <> v_t.to_branch_id THEN
      RAISE EXCEPTION 'Счёт получателя не принадлежит филиалу получателя';
    END IF;
  END IF;

  -- ── Резолвим новый commission_account_id (если режим fromAccount) ──
  IF v_commission_mode = 'fromAccount' THEN
    v_new_commission_acc := COALESCE(p_commission_account_id, v_old_commission_acc);
    IF v_new_commission_acc IS NULL THEN
      RAISE EXCEPTION 'Для режима «комиссия с другого счёта» обязательно указание счёта';
    END IF;
    SELECT branch_id, currency
      INTO v_comm_acc_branch, v_comm_acc_currency
      FROM branch_accounts WHERE id = v_new_commission_acc;
    IF v_comm_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Счёт комиссии не найден';
    END IF;
    IF v_comm_acc_branch <> v_t.from_branch_id THEN
      RAISE EXCEPTION 'Счёт комиссии должен принадлежать филиалу-отправителю';
    END IF;
    -- Валюту комиссии принудительно подгоняем под валюту этого счёта.
    v_commission_currency := v_comm_acc_currency;
  ELSE
    v_new_commission_acc := NULL;
  END IF;

  -- Commission в валюте перевода (для отображения).
  v_commission := private.normalize_commission(
    v_commission_type, v_commission_value, v_commission_currency,
    v_amount, v_currency
  );

  -- ── Old / new total debit (основной счёт) ──
  IF v_t.commission_mode = 'fromSender' THEN
    v_old_total := v_t.amount + v_t.commission;
  ELSE
    v_old_total := v_t.amount;
  END IF;

  IF v_commission_mode = 'fromSender' THEN
    v_new_total := v_amount + v_commission;
  ELSE
    v_new_total := v_amount;
  END IF;

  -- ── Refund старого debit на старый основной счёт ──
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_t.from_account_id, v_t.from_branch_id, v_old_total, v_t.currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance + v_old_total,
        updated_at = v_now;

  -- ── Refund старой commission, если она была списана с отдельного счёта ──
  IF v_t.commission_mode = 'fromAccount'
     AND v_old_commission_acc IS NOT NULL
     AND v_t.commission > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_old_commission_acc, v_t.from_branch_id, v_t.commission,
            COALESCE(NULLIF(v_t.commission_currency, ''), v_t.currency), v_now)
    ON CONFLICT (account_id) DO UPDATE
      SET balance    = account_balances.balance + v_t.commission,
          updated_at = v_now;

    DELETE FROM ledger_entries
     WHERE reference_type = 'commission'
       AND reference_id   = p_transfer_id::text
       AND account_id     = v_old_commission_acc
       AND type           = 'debit';
  END IF;

  -- ── Снять новый debit с НОВОГО основного счёта ──
  SELECT balance INTO v_balance
    FROM account_balances
   WHERE account_id = v_new_from FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  IF v_balance < v_new_total THEN
    -- Откатываем рефанд старого основного debit.
    UPDATE account_balances
       SET balance    = balance - v_old_total,
           updated_at = v_now
     WHERE account_id = v_t.from_account_id;
    -- И рефанд старой commission, если делали.
    IF v_t.commission_mode = 'fromAccount'
       AND v_old_commission_acc IS NOT NULL
       AND v_t.commission > 0 THEN
      UPDATE account_balances
         SET balance    = balance - v_t.commission,
             updated_at = v_now
       WHERE account_id = v_old_commission_acc;
    END IF;
    RAISE EXCEPTION 'Недостаточно средств на счёте. Доступно: %, требуется: %',
      round(v_balance::numeric, 2), round(v_new_total::numeric, 2);
  END IF;

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_new_from, v_t.from_branch_id, -v_new_total, v_currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance - v_new_total,
        updated_at = v_now;

  -- ── Снять новую commission с нового commission_account_id, если режим fromAccount ──
  IF v_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    SELECT balance INTO v_comm_acc_balance
      FROM account_balances WHERE account_id = v_new_commission_acc FOR UPDATE;
    v_comm_acc_balance := COALESCE(v_comm_acc_balance, 0);
    IF v_comm_acc_balance < v_commission THEN
      RAISE EXCEPTION 'Недостаточно средств на счёте комиссии. Доступно: % %, требуется: %',
        round(v_comm_acc_balance::numeric, 2), v_commission_currency,
        round(v_commission::numeric, 2);
    END IF;

    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_new_commission_acc, v_t.from_branch_id, -v_commission,
            v_commission_currency, v_now)
    ON CONFLICT (account_id) DO UPDATE
      SET balance    = account_balances.balance - v_commission,
          updated_at = v_now;
  END IF;

  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  -- ── Обновить ledger: удалить старые pending-debit и записать новые ──
  DELETE FROM ledger_entries
   WHERE reference_type = 'transfer'
     AND reference_id   = p_transfer_id::text
     AND branch_id      = v_t.from_branch_id
     AND type           = 'debit';

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency, reference_type,
     reference_id, transaction_code, description, created_by)
  VALUES
    (v_t.from_branch_id, v_new_from, 'debit', v_new_total, v_currency,
     'transfer', p_transfer_id::text, v_code,
     'Перевод ' || v_code || ' (отредактирован, ожидает приёма)', v_user_id);

  IF v_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency, reference_type,
       reference_id, transaction_code, description, created_by)
    VALUES
      (v_t.from_branch_id, v_new_commission_acc, 'debit', v_commission,
       v_commission_currency, 'commission', p_transfer_id::text, v_code,
       'Комиссия по переводу ' || v_code || ' (отдельный счёт, отредактировано)',
       v_user_id);
  END IF;

  -- ── Новый converted_amount ──
  IF v_commission_mode = 'fromTransfer' THEN
    v_receiver := v_amount - v_commission;
  ELSIF v_commission_mode = 'toReceiver' THEN
    v_receiver := v_amount + v_commission;
  ELSE
    v_receiver := v_amount;
  END IF;
  v_converted := v_receiver * v_rate;

  -- ── Diff в amendment_history ──
  IF v_t.amount <> v_amount THEN
    v_changes := jsonb_set(v_changes, '{amount}',
      jsonb_build_object('from', v_t.amount, 'to', v_amount));
  END IF;
  IF v_t.currency <> v_currency THEN
    v_changes := jsonb_set(v_changes, '{currency}',
      jsonb_build_object('from', v_t.currency, 'to', v_currency));
  END IF;
  IF COALESCE(v_t.to_currency, '') <> COALESCE(v_to_cur, '') THEN
    v_changes := jsonb_set(v_changes, '{to_currency}',
      jsonb_build_object('from', v_t.to_currency, 'to', v_to_cur));
  END IF;
  IF v_t.exchange_rate <> v_rate THEN
    v_changes := jsonb_set(v_changes, '{exchange_rate}',
      jsonb_build_object('from', v_t.exchange_rate, 'to', v_rate));
  END IF;
  IF v_t.commission_value <> v_commission_value
     OR v_t.commission_type <> v_commission_type
     OR v_t.commission_mode <> v_commission_mode
     OR COALESCE(v_t.commission_currency, '') <> COALESCE(v_commission_currency, '')
     OR COALESCE(v_t.commission_account_id::text, '') <> COALESCE(v_new_commission_acc::text, '') THEN
    v_changes := jsonb_set(v_changes, '{commission}',
      jsonb_build_object(
        'from', jsonb_build_object('type', v_t.commission_type,
                                   'value', v_t.commission_value,
                                   'currency', v_t.commission_currency,
                                   'mode', v_t.commission_mode,
                                   'accountId', v_t.commission_account_id),
        'to',   jsonb_build_object('type', v_commission_type,
                                   'value', v_commission_value,
                                   'currency', v_commission_currency,
                                   'mode', v_commission_mode,
                                   'accountId', v_new_commission_acc)));
  END IF;
  IF v_t.from_account_id <> v_new_from THEN
    v_changes := jsonb_set(v_changes, '{from_account_id}',
      jsonb_build_object('from', v_t.from_account_id::text, 'to', v_new_from::text));
  END IF;

  -- ── UPDATE transfer ──
  UPDATE transfers SET
    from_account_id    = v_new_from,
    amount             = v_amount,
    currency           = v_currency,
    to_currency        = v_to_cur,
    exchange_rate      = v_rate,
    converted_amount   = v_converted,
    commission         = v_commission,
    commission_type    = v_commission_type,
    commission_value   = v_commission_value,
    commission_currency= v_commission_currency,
    commission_mode    = v_commission_mode,
    commission_account_id = v_new_commission_acc,
    to_account_id      = CASE
      WHEN p_to_account_id IS NULL THEN to_account_id
      WHEN p_to_account_id = ''    THEN ''
      ELSE p_to_account_id
    END,
    description        = COALESCE(p_description, description),
    client_id          = COALESCE(p_client_id, client_id),
    sender_name        = COALESCE(p_sender_name, sender_name),
    sender_phone       = COALESCE(p_sender_phone, sender_phone),
    sender_info        = COALESCE(p_sender_info, sender_info),
    receiver_name      = COALESCE(p_receiver_name, receiver_name),
    receiver_phone     = COALESCE(p_receiver_phone, receiver_phone),
    receiver_info      = COALESCE(p_receiver_info, receiver_info),
    amendment_history  = COALESCE(amendment_history, '[]'::jsonb) || jsonb_build_array(
        jsonb_build_object(
          'at',      v_now,
          'userId',  v_user_id::text,
          'note',    NULLIF(trim(coalesce(p_amendment_note,'')), ''),
          'changes', v_changes
        )
      )
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'changes', v_changes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION private.replace_pending_transfer(
  uuid, uuid, double precision, text, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text, text, uuid
) TO authenticated;

DROP FUNCTION IF EXISTS public.replace_pending_transfer(
  uuid, uuid, double precision, text, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text, text
);

CREATE OR REPLACE FUNCTION public.replace_pending_transfer(
  p_transfer_id        uuid,
  p_from_account_id    uuid    DEFAULT NULL,
  p_amount             double precision DEFAULT NULL,
  p_currency           text    DEFAULT NULL,
  p_to_currency        text    DEFAULT NULL,
  p_exchange_rate      double precision DEFAULT NULL,
  p_commission_type    text    DEFAULT NULL,
  p_commission_value   double precision DEFAULT NULL,
  p_commission_currency text   DEFAULT NULL,
  p_commission_mode    text    DEFAULT NULL,
  p_to_account_id      text    DEFAULT NULL,
  p_description        text    DEFAULT NULL,
  p_client_id          text    DEFAULT NULL,
  p_sender_name        text    DEFAULT NULL,
  p_sender_phone       text    DEFAULT NULL,
  p_sender_info        text    DEFAULT NULL,
  p_receiver_name      text    DEFAULT NULL,
  p_receiver_phone     text    DEFAULT NULL,
  p_receiver_info      text    DEFAULT NULL,
  p_amendment_note     text    DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT private.replace_pending_transfer(
    p_transfer_id, p_from_account_id, p_amount, p_currency, p_to_currency,
    p_exchange_rate, p_commission_type, p_commission_value, p_commission_currency,
    p_commission_mode, p_to_account_id, p_description, p_client_id,
    p_sender_name, p_sender_phone, p_sender_info,
    p_receiver_name, p_receiver_phone, p_receiver_info,
    p_amendment_note, p_commission_account_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.replace_pending_transfer(
  uuid, uuid, double precision, text, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text, text, uuid
) TO authenticated;

COMMIT;
