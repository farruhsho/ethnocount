-- ============================================================
-- 007: Cross-currency math correctness (F3)
-- ============================================================
-- Fixes:
--   C7: Commission can be entered in a different currency than the transfer.
--       Previously, `amount + commission` mixed units silently. Now we
--       convert fixed-mode commission to transfer currency via exchange_rates
--       BEFORE storing/using it. Stored `commission` is always in transfer currency.
--   H13: create_purchase now validates that the sum of payment lines equals
--        total_amount within tolerance (after converting cross-currency lines via FX).
-- Idempotent — safe to re-run.
-- ============================================================

-- ─── fx_rate: latest exchange rate from→to (raises if missing) ───
CREATE OR REPLACE FUNCTION private.fx_rate(p_from text, p_to text)
RETURNS double precision
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate double precision;
  v_inverse double precision;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from = '' OR p_to = '' OR p_from = p_to THEN
    RETURN 1;
  END IF;

  SELECT rate INTO v_rate
  FROM exchange_rates
  WHERE from_currency = p_from AND to_currency = p_to
  ORDER BY effective_at DESC
  LIMIT 1;

  IF v_rate IS NOT NULL AND v_rate > 0 THEN RETURN v_rate; END IF;

  -- Try inverse pair
  SELECT rate INTO v_inverse
  FROM exchange_rates
  WHERE from_currency = p_to AND to_currency = p_from
  ORDER BY effective_at DESC
  LIMIT 1;

  IF v_inverse IS NOT NULL AND v_inverse > 0 THEN RETURN 1.0 / v_inverse; END IF;

  RAISE EXCEPTION 'No exchange rate available between % and %', p_from, p_to;
END;
$$;

-- ─── Helper: convert commission to transfer currency ───
CREATE OR REPLACE FUNCTION private.normalize_commission(
  p_commission_type text,
  p_commission_value double precision,
  p_commission_currency text,
  p_amount double precision,
  p_transfer_currency text
)
RETURNS double precision
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw double precision;
BEGIN
  IF p_commission_type = 'percentage' THEN
    -- Percentage of amount; same currency as transfer by definition
    RETURN p_amount * p_commission_value / 100;
  END IF;

  -- Fixed mode
  v_raw := p_commission_value;
  IF p_commission_currency IS NULL OR p_commission_currency = '' OR p_commission_currency = p_transfer_currency THEN
    RETURN v_raw;
  END IF;

  RETURN v_raw * private.fx_rate(p_commission_currency, p_transfer_currency);
END;
$$;

-- ─── Patch create_transfer to use FX-normalized commission ───
CREATE OR REPLACE FUNCTION private.create_transfer(
  p_from_branch_id uuid,
  p_to_branch_id uuid,
  p_from_account_id uuid,
  p_to_account_id text DEFAULT '',
  p_to_currency text DEFAULT NULL,
  p_amount double precision DEFAULT 0,
  p_currency text DEFAULT 'USD',
  p_exchange_rate double precision DEFAULT 1,
  p_commission_type text DEFAULT 'fixed',
  p_commission_value double precision DEFAULT 0,
  p_commission_currency text DEFAULT 'USD',
  p_commission_mode text DEFAULT 'fromSender',
  p_idempotency_key text DEFAULT '',
  p_description text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_sender_phone text DEFAULT NULL,
  p_sender_info text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL,
  p_receiver_phone text DEFAULT NULL,
  p_receiver_info text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_commission double precision;
  v_total_debit double precision;
  v_from_balance double precision;
  v_acc_branch uuid;
  v_code text;
  v_transfer_id uuid;
  v_resolved_to_currency text;
  v_receiver_amount double precision;
  v_converted double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  -- Verify the source account belongs to the source branch (H12 hardening)
  SELECT branch_id INTO v_acc_branch FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Source account not found'; END IF;
  IF v_acc_branch != p_from_branch_id THEN
    RAISE EXCEPTION 'Source account does not belong to source branch';
  END IF;

  -- Compute commission in TRANSFER currency (FX-normalized)
  v_commission := private.normalize_commission(
    p_commission_type, p_commission_value, p_commission_currency, p_amount, p_currency
  );

  IF p_commission_mode = 'fromSender' THEN
    v_total_debit := p_amount + v_commission;
  ELSE
    v_total_debit := p_amount;
  END IF;

  -- Lock and check balance
  SELECT balance INTO v_from_balance FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  IF v_from_balance IS NULL THEN v_from_balance := 0; END IF;
  IF v_from_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
      round(v_from_balance::numeric, 2), round(v_total_debit::numeric, 2);
  END IF;

  -- Resolve receiver currency
  v_resolved_to_currency := p_currency;
  IF p_to_account_id IS NOT NULL AND p_to_account_id != '' THEN
    SELECT currency INTO v_resolved_to_currency FROM branch_accounts WHERE id = p_to_account_id::uuid;
  ELSIF p_to_currency IS NOT NULL THEN
    v_resolved_to_currency := p_to_currency;
  END IF;

  -- Receiver amount in TRANSFER currency, then converted via FX
  IF p_commission_mode = 'fromTransfer' THEN
    v_receiver_amount := p_amount - v_commission;
  ELSIF p_commission_mode = 'toReceiver' THEN
    v_receiver_amount := p_amount + v_commission;
  ELSE
    v_receiver_amount := p_amount;
  END IF;
  v_converted := v_receiver_amount * p_exchange_rate;

  v_code := private.next_transaction_code('ELX', 'transactionCodes');
  v_transfer_id := gen_random_uuid();

  -- Insert transfer with idempotency safety (relies on uniq_transfers_idempotency)
  BEGIN
    INSERT INTO transfers (
      id, transaction_code, from_branch_id, to_branch_id, from_account_id, to_account_id,
      amount, currency, to_currency, exchange_rate, converted_amount,
      commission, commission_currency, commission_type, commission_value, commission_mode,
      description, client_id,
      sender_name, sender_phone, sender_info,
      receiver_name, receiver_phone, receiver_info,
      status, created_by, idempotency_key, created_at
    ) VALUES (
      v_transfer_id, v_code, p_from_branch_id, p_to_branch_id, p_from_account_id, COALESCE(p_to_account_id, ''),
      p_amount, p_currency, v_resolved_to_currency, p_exchange_rate, v_converted,
      v_commission, p_commission_currency, p_commission_type, p_commission_value, p_commission_mode,
      p_description, p_client_id,
      p_sender_name, p_sender_phone, p_sender_info,
      p_receiver_name, p_receiver_phone, p_receiver_info,
      'pending', v_user_id, p_idempotency_key, now()
    );
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate transfer — already exists';
  END;

  -- Debit sender (UPSERT-safe)
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (p_from_account_id, p_from_branch_id, -v_total_debit, p_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - v_total_debit, updated_at = now();

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (p_from_branch_id, p_from_account_id, 'debit', v_total_debit, p_currency, 'transfer', v_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (ожидает подтверждения)', v_user_id);

  INSERT INTO notifications (target_branch_id, type, title, body, data)
  VALUES (p_to_branch_id::text, 'incoming_transfer', 'Новый входящий перевод',
          'Перевод ' || v_code || ': ' || p_amount || ' ' || p_currency || ' ожидает подтверждения.',
          jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code));

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;

-- ─── Patch update_transfer_amount to FX-normalize commission consistently ───
CREATE OR REPLACE FUNCTION private.update_transfer_amount(
  p_transfer_id uuid,
  p_new_amount double precision,
  p_new_exchange_rate double precision DEFAULT NULL,
  p_amendment_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_t transfers%ROWTYPE;
  v_old_total double precision;
  v_new_commission double precision;
  v_new_total double precision;
  v_eff_rate double precision;
  v_receiver double precision;
  v_balance double precision;
  v_delta double precision;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_new_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_t.status != 'pending' THEN
    RAISE EXCEPTION 'Only pending transfers can be amended (current: %)', v_t.status;
  END IF;

  v_old_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN v_t.amount + v_t.commission
                      ELSE v_t.amount END;

  -- Re-normalize commission in transfer currency
  v_new_commission := private.normalize_commission(
    v_t.commission_type, v_t.commission_value, v_t.commission_currency, p_new_amount, v_t.currency
  );

  v_new_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN p_new_amount + v_new_commission
                      ELSE p_new_amount END;

  v_eff_rate := COALESCE(p_new_exchange_rate, v_t.exchange_rate);
  v_receiver := CASE v_t.commission_mode
    WHEN 'fromTransfer' THEN p_new_amount - v_new_commission
    WHEN 'toReceiver'   THEN p_new_amount + v_new_commission
    ELSE p_new_amount
  END;

  v_delta := v_old_total - v_new_total;
  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  SELECT balance INTO v_balance FROM account_balances WHERE account_id = v_t.from_account_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_t.from_account_id, v_t.from_branch_id, v_delta, v_t.currency, now());
  ELSE
    IF v_balance + v_delta < 0 THEN
      RAISE EXCEPTION 'Недостаточно средств на счёте отправителя';
    END IF;
    UPDATE account_balances
      SET balance = balance + v_delta, updated_at = now()
      WHERE account_id = v_t.from_account_id;
  END IF;

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'credit', v_old_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code, 'Сторно (изменён): ' || v_code, v_user_id);

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'debit', v_new_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (изменён, ожидает подтверждения)', v_user_id);

  UPDATE transfers SET
    amount = p_new_amount,
    commission = v_new_commission,
    exchange_rate = v_eff_rate,
    converted_amount = v_receiver * v_eff_rate,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object(
        'at', now(),
        'userId', v_user_id::text,
        'note', p_amendment_note,
        'changes', jsonb_build_object(
          'amount', jsonb_build_object('from', v_t.amount, 'to', p_new_amount),
          'commission', jsonb_build_object('from', v_t.commission, 'to', v_new_commission),
          'exchangeRate', jsonb_build_object('from', v_t.exchange_rate, 'to', v_eff_rate)
        )
      )
    )
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Patch create_purchase: validate sum(payments) ≈ total_amount (cross-currency aware) ───
CREATE OR REPLACE FUNCTION private.create_purchase(
  p_branch_id uuid,
  p_description text,
  p_total_amount double precision,
  p_currency text,
  p_payments jsonb,
  p_client_id text DEFAULT NULL,
  p_client_name text DEFAULT NULL,
  p_category text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text;
  v_purchase_id uuid;
  v_payment jsonb;
  v_account_id uuid;
  v_amount double precision;
  v_pay_currency text;
  v_cur_balance double precision;
  v_acc_currency text;
  v_acc_branch uuid;
  v_sum_in_currency double precision := 0;
  v_normalized double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_total_amount <= 0 THEN RAISE EXCEPTION 'total_amount must be positive'; END IF;
  IF jsonb_array_length(COALESCE(p_payments, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'At least one payment line required';
  END IF;

  -- H13: validate sum(payments) ≈ total_amount in p_currency
  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    v_amount := (v_payment->>'amount')::double precision;
    v_pay_currency := COALESCE(v_payment->>'currency', p_currency);
    IF v_pay_currency = p_currency THEN
      v_normalized := v_amount;
    ELSE
      v_normalized := v_amount * private.fx_rate(v_pay_currency, p_currency);
    END IF;
    v_sum_in_currency := v_sum_in_currency + v_normalized;
  END LOOP;

  IF abs(v_sum_in_currency - p_total_amount) > 0.01 THEN
    RAISE EXCEPTION 'Payment sum (% %) does not match total_amount (% %)',
      round(v_sum_in_currency::numeric, 2), p_currency,
      round(p_total_amount::numeric, 2), p_currency;
  END IF;

  v_code := private.next_transaction_code('ETH-TX', 'transactionCodes');
  v_purchase_id := gen_random_uuid();

  INSERT INTO purchases (id, transaction_code, branch_id, client_id, client_name, description, category, total_amount, currency, payments, created_by)
  VALUES (v_purchase_id, v_code, p_branch_id, p_client_id, p_client_name, p_description, p_category, p_total_amount, p_currency, p_payments, v_user_id);

  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    v_account_id := (v_payment->>'accountId')::uuid;
    v_amount := (v_payment->>'amount')::double precision;

    SELECT branch_id, currency INTO v_acc_branch, v_acc_currency FROM branch_accounts WHERE id = v_account_id;
    IF v_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Account % not found', v_account_id;
    END IF;
    IF v_acc_branch != p_branch_id THEN
      RAISE EXCEPTION 'Account % does not belong to branch %', v_account_id, p_branch_id;
    END IF;

    SELECT balance INTO v_cur_balance FROM account_balances WHERE account_id = v_account_id FOR UPDATE;
    IF v_cur_balance IS NULL THEN v_cur_balance := 0; END IF;
    IF v_cur_balance < v_amount THEN
      RAISE EXCEPTION 'Insufficient balance in account %', v_payment->>'accountName';
    END IF;

    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_account_id, COALESCE(v_acc_branch, p_branch_id), -v_amount, COALESCE(v_acc_currency, p_currency), now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance - v_amount, updated_at = now();

    INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
    VALUES (COALESCE(v_acc_branch, p_branch_id), v_account_id, 'debit', v_amount, COALESCE(v_acc_currency, p_currency),
            'purchase', v_purchase_id::text, v_code, 'Покупка ' || v_code || ': ' || p_description, v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'purchaseId', v_purchase_id::text);
END;
$$;
