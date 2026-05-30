-- ============================================================
-- 024: Full edit of a pending (created) transfer
-- ============================================================
-- До приёма получателем перевод можно полностью перевыставить:
--   * сменить from_account (счёт-источник) — переоформить debit
--   * сменить валюту, exchange_rate, amount
--   * сменить commission (type / value / currency / mode)
--   * сменить to_account / to_currency и контактные/реквизитные поля
--
-- Гарантии:
--   * Только status='created'.
--   * Атомарно: refund старого debit + новый debit с новыми параметрами.
--   * Если новых средств не хватает на новом счёте — RAISE EXCEPTION.
--   * История правок пишется в amendment_history.
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
  p_amendment_note     text    DEFAULT NULL
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
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  IF v_t.status <> 'created' THEN
    RAISE EXCEPTION 'Полное редактирование возможно только для статуса «создан» (текущий: %)', v_t.status;
  END IF;

  -- ── Resolve new values (NULL = оставить как было) ──
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

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  -- Sanity: новый from_account должен принадлежать тому же from_branch.
  IF v_new_from <> v_t.from_account_id THEN
    PERFORM 1 FROM branch_accounts
      WHERE id = v_new_from AND branch_id = v_t.from_branch_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Новый счёт-источник не относится к филиалу отправителя';
    END IF;
  END IF;

  -- Если меняется to_account_id, проверим что он у получающего филиала.
  IF p_to_account_id IS NOT NULL AND p_to_account_id <> '' AND p_to_account_id <> v_t.to_account_id THEN
    SELECT branch_id INTO v_to_acc_branch
      FROM branch_accounts WHERE id = p_to_account_id::uuid;
    IF v_to_acc_branch IS NULL OR v_to_acc_branch <> v_t.to_branch_id THEN
      RAISE EXCEPTION 'Счёт получателя не принадлежит филиалу получателя';
    END IF;
  END IF;

  -- ── Commission в валюте перевода ──
  v_commission := private.normalize_commission(
    v_commission_type, v_commission_value, v_commission_currency,
    v_amount, v_currency
  );

  -- ── Old / new total debit ──
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

  -- ── Refund старого debit на старый счёт ──
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_t.from_account_id, v_t.from_branch_id, v_old_total, v_t.currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance + v_old_total,
        updated_at = v_now;

  -- ── Снять новый debit с НОВОГО счёта ──
  SELECT balance INTO v_balance
    FROM account_balances
   WHERE account_id = v_new_from FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  IF v_balance < v_new_total THEN
    -- Откат refund (вернём состояние как было)
    UPDATE account_balances
       SET balance    = balance - v_old_total,
           updated_at = v_now
     WHERE account_id = v_t.from_account_id;
    RAISE EXCEPTION 'Недостаточно средств на счёте. Доступно: %, требуется: %',
      round(v_balance::numeric, 2), round(v_new_total::numeric, 2);
  END IF;

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_new_from, v_t.from_branch_id, -v_new_total, v_currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance - v_new_total,
        updated_at = v_now;

  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  -- ── Обновить ledger: удалить старые pending-debit и записать новый ──
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

  -- ── Новый converted_amount ──
  IF v_commission_mode = 'fromTransfer' THEN
    v_receiver := v_amount - v_commission;
  ELSIF v_commission_mode = 'toReceiver' THEN
    v_receiver := v_amount + v_commission;
  ELSE
    v_receiver := v_amount;
  END IF;
  v_converted := v_receiver * v_rate;

  -- ── Сбор diff для amendment_history ──
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
     OR COALESCE(v_t.commission_currency, '') <> COALESCE(v_commission_currency, '') THEN
    v_changes := jsonb_set(v_changes, '{commission}',
      jsonb_build_object(
        'from', jsonb_build_object('type', v_t.commission_type,
                                   'value', v_t.commission_value,
                                   'currency', v_t.commission_currency,
                                   'mode', v_t.commission_mode),
        'to',   jsonb_build_object('type', v_commission_type,
                                   'value', v_commission_value,
                                   'currency', v_commission_currency,
                                   'mode', v_commission_mode)));
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
  text, text, text, text, text, text, text
) TO authenticated;

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
  p_amendment_note     text    DEFAULT NULL
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
    p_amendment_note
  );
$$;

GRANT EXECUTE ON FUNCTION public.replace_pending_transfer(
  uuid, uuid, double precision, text, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text, text
) TO authenticated;

COMMIT;
