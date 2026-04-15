-- ============================================================
-- PART 3: RPC Functions + Realtime
-- Run this THIRD (after Part 1 and Part 2)
-- ============================================================

-- ─── Create Transfer (atomic) ───
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
  v_code text;
  v_transfer_id uuid;
  v_resolved_to_currency text;
  v_receiver_amount double precision;
  v_converted double precision;
  v_dup_count int;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User must be authenticated';
  END IF;

  -- Check duplicate
  SELECT count(*) INTO v_dup_count FROM transfers WHERE idempotency_key = p_idempotency_key;
  IF v_dup_count > 0 THEN
    RAISE EXCEPTION 'Duplicate transfer — already exists';
  END IF;

  -- Compute commission
  IF p_commission_type = 'percentage' THEN
    v_commission := p_amount * p_commission_value / 100;
  ELSE
    v_commission := p_commission_value;
  END IF;

  IF p_commission_mode = 'fromSender' THEN
    v_total_debit := p_amount + v_commission;
  ELSE
    v_total_debit := p_amount;
  END IF;

  -- Check balance
  SELECT balance INTO v_from_balance FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  IF v_from_balance IS NULL THEN v_from_balance := 0; END IF;
  IF v_from_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %', round(v_from_balance::numeric, 0), round(v_total_debit::numeric, 0);
  END IF;

  -- Resolve to_currency
  v_resolved_to_currency := p_currency;
  IF p_to_account_id IS NOT NULL AND p_to_account_id != '' THEN
    SELECT currency INTO v_resolved_to_currency FROM branch_accounts WHERE id = p_to_account_id::uuid;
  ELSIF p_to_currency IS NOT NULL THEN
    v_resolved_to_currency := p_to_currency;
  END IF;

  -- Compute receiver amount
  IF p_commission_mode = 'fromTransfer' THEN
    v_receiver_amount := p_amount - v_commission;
  ELSIF p_commission_mode = 'toReceiver' THEN
    v_receiver_amount := p_amount + v_commission;
  ELSE
    v_receiver_amount := p_amount;
  END IF;
  v_converted := v_receiver_amount * p_exchange_rate;

  -- Generate code
  v_code := private.next_transaction_code('ELX', 'transactionCodes');

  -- Insert transfer
  v_transfer_id := gen_random_uuid();
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

  -- Debit sender
  UPDATE account_balances SET balance = balance - v_total_debit, updated_at = now()
  WHERE account_id = p_from_account_id;

  -- Ledger debit
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (p_from_branch_id, p_from_account_id, 'debit', v_total_debit, p_currency, 'transfer', v_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (ожидает подтверждения)', v_user_id);

  -- Notification
  INSERT INTO notifications (target_branch_id, type, title, body, data)
  VALUES (p_to_branch_id::text, 'incoming_transfer', 'Новый входящий перевод',
          'Перевод ' || v_code || ': ' || p_amount || ' ' || p_currency || ' ожидает подтверждения.',
          jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code));

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;

-- ─── Confirm Transfer ───
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
  v_current_balance double precision;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'pending' THEN RAISE EXCEPTION 'Transfer not in pending state'; END IF;

  v_effective_to := CASE
    WHEN v_transfer.to_account_id != '' THEN v_transfer.to_account_id
    ELSE COALESCE(p_to_account_id, '')
  END;
  IF v_effective_to = '' THEN
    RAISE EXCEPTION 'Счёт получателя не указан';
  END IF;

  v_to_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);

  -- Validate account currency
  SELECT currency INTO v_acc_currency FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_transfer.to_currency IS NOT NULL AND v_transfer.to_currency != '' AND v_acc_currency != v_transfer.to_currency THEN
    RAISE EXCEPTION 'Счёт получателя в валюте %, перевод оформлен в %', v_acc_currency, v_transfer.to_currency;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

  -- Update transfer
  UPDATE transfers SET
    status = 'confirmed',
    confirmed_by = v_user_id,
    confirmed_at = now(),
    to_account_id = CASE WHEN to_account_id = '' THEN v_effective_to ELSE to_account_id END,
    to_currency = COALESCE(v_to_currency, to_currency)
  WHERE id = p_transfer_id;

  -- Credit receiver
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_effective_to::uuid, v_transfer.to_branch_id, v_transfer.converted_amount, COALESCE(v_acc_currency, v_to_currency), now())
  ON CONFLICT (account_id) DO UPDATE SET balance = account_balances.balance + v_transfer.converted_amount, updated_at = now();

  -- Ledger credit
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_transfer.to_branch_id, v_effective_to::uuid, 'credit', v_transfer.converted_amount, COALESCE(v_acc_currency, v_to_currency),
          'transfer', p_transfer_id::text, v_code, 'Перевод ' || v_code || ' (подтверждён)', v_user_id);

  -- Update sender ledger description
  UPDATE ledger_entries SET description = 'Перевод ' || v_code || ' (подтверждён)'
  WHERE ctid = (
    SELECT ctid FROM ledger_entries
    WHERE reference_type = 'transfer' AND reference_id = p_transfer_id::text
      AND branch_id = v_transfer.from_branch_id
    LIMIT 1
  );

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_confirmed', 'Перевод подтверждён',
     'Ваш перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' подтверждён.',
     jsonb_build_object('transferId', p_transfer_id::text)),
    (v_transfer.to_branch_id::text, 'transfer_confirmed', 'Перевод подтверждён',
     'Перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' подтверждён.',
     jsonb_build_object('transferId', p_transfer_id::text));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Reject Transfer ───
CREATE OR REPLACE FUNCTION private.reject_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_total double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'pending' THEN RAISE EXCEPTION 'Transfer not in pending state'; END IF;

  IF v_transfer.commission_mode = 'fromSender' THEN
    v_total := v_transfer.amount + v_transfer.commission;
  ELSE
    v_total := v_transfer.amount;
  END IF;

  -- Update status
  UPDATE transfers SET status = 'rejected', rejected_by = v_user_id, rejection_reason = p_reason, rejected_at = now()
  WHERE id = p_transfer_id;

  -- Refund
  UPDATE account_balances SET balance = balance + v_total, updated_at = now()
  WHERE account_id = v_transfer.from_account_id;

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_rejected', 'Перевод отклонён',
     'Ваш перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' отклонён. Причина: ' || p_reason,
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason)),
    (v_transfer.to_branch_id::text, 'transfer_rejected', 'Перевод отклонён',
     'Перевод ' || v_transfer.amount || ' ' || v_transfer.currency || ' отклонён.',
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Issue Transfer ───
CREATE OR REPLACE FUNCTION private.issue_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'confirmed' THEN RAISE EXCEPTION 'Transfer must be confirmed first'; END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET status = 'issued', issued_by = v_user_id, issued_at = now()
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_issued', 'Перевод выдан',
     'Перевод ' || v_code || ' (' || v_transfer.amount || ' ' || v_transfer.currency || ') выдан получателю.',
     jsonb_build_object('transferId', p_transfer_id::text)),
    (v_transfer.to_branch_id::text, 'transfer_issued', 'Перевод выдан',
     'Перевод ' || v_code || ' (' || v_transfer.amount || ' ' || v_transfer.currency || ') выдан получателю.',
     jsonb_build_object('transferId', p_transfer_id::text));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Create Purchase (atomic) ───
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
  v_cur_balance double precision;
  v_acc_currency text;
  v_acc_branch uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_code := private.next_transaction_code('ETH-TX', 'transactionCodes');
  v_purchase_id := gen_random_uuid();

  INSERT INTO purchases (id, transaction_code, branch_id, client_id, client_name, description, category, total_amount, currency, payments, created_by)
  VALUES (v_purchase_id, v_code, p_branch_id, p_client_id, p_client_name, p_description, p_category, p_total_amount, p_currency, p_payments, v_user_id);

  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    v_account_id := (v_payment->>'accountId')::uuid;
    v_amount := (v_payment->>'amount')::double precision;

    SELECT balance INTO v_cur_balance FROM account_balances WHERE account_id = v_account_id FOR UPDATE;
    IF v_cur_balance IS NULL THEN v_cur_balance := 0; END IF;
    IF v_cur_balance < v_amount THEN
      RAISE EXCEPTION 'Insufficient balance in account %', v_payment->>'accountName';
    END IF;

    SELECT currency, branch_id INTO v_acc_currency, v_acc_branch FROM branch_accounts WHERE id = v_account_id;

    UPDATE account_balances SET balance = balance - v_amount, updated_at = now() WHERE account_id = v_account_id;

    INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
    VALUES (COALESCE(v_acc_branch, p_branch_id), v_account_id, 'debit', v_amount, COALESCE(v_acc_currency, p_currency),
            'purchase', v_purchase_id::text, v_code, 'Покупка ' || v_code || ': ' || p_description, v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'purchaseId', v_purchase_id::text);
END;
$$;

-- ─── Create Client ───
CREATE OR REPLACE FUNCTION private.create_client(
  p_name text,
  p_phone text,
  p_country text,
  p_currency text,
  p_branch_id text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_code text;
  v_client_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_code := private.next_transaction_code('CL', 'clientCodes');
  v_client_id := gen_random_uuid();

  INSERT INTO clients (id, client_code, name, phone, country, currency, branch_id, wallet_currencies, is_active, created_by)
  VALUES (v_client_id, v_code, trim(p_name), trim(p_phone), COALESCE(trim(p_country), ''), trim(p_currency), trim(p_branch_id), ARRAY[trim(p_currency)], true, v_user_id);

  INSERT INTO client_balances (client_id, balances, balance, currency)
  VALUES (v_client_id, jsonb_build_object(trim(p_currency), 0), 0, trim(p_currency));

  RETURN jsonb_build_object('success', true, 'clientId', v_client_id::text);
END;
$$;

-- ─── Deposit Client ───
CREATE OR REPLACE FUNCTION private.deposit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Пополнение счёта',
  p_currency text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client clients%ROWTYPE;
  v_target_cur text;
  v_balances jsonb;
  v_cur_bal double precision;
  v_primary_bal double precision;
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Client not found'; END IF;
  IF NOT v_client.is_active THEN RAISE EXCEPTION 'Client account is inactive'; END IF;

  v_target_cur := COALESCE(NULLIF(trim(p_currency), ''), v_client.currency);

  SELECT balances INTO v_balances FROM client_balances WHERE client_id = p_client_id FOR UPDATE;
  IF v_balances IS NULL THEN v_balances := '{}'::jsonb; END IF;

  v_cur_bal := COALESCE((v_balances->>v_target_cur)::double precision, 0);
  v_balances := v_balances || jsonb_build_object(v_target_cur, round((v_cur_bal + p_amount)::numeric, 2));
  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  v_code := private.next_transaction_code('ETH-TX', 'transactionCodes');

  UPDATE client_balances SET balances = v_balances, balance = round(v_primary_bal::numeric, 2), currency = v_client.currency, updated_at = now()
  WHERE client_id = p_client_id;

  UPDATE clients SET wallet_currencies = array_append(wallet_currencies, v_target_cur) WHERE id = p_client_id AND NOT (v_target_cur = ANY(wallet_currencies));

  INSERT INTO client_transactions (client_id, transaction_code, type, amount, currency, balance_after, description, created_by)
  VALUES (p_client_id, v_code, 'deposit', round(p_amount::numeric, 2), v_target_cur, round((v_cur_bal + p_amount)::numeric, 2),
          COALESCE(NULLIF(trim(p_description), ''), 'Пополнение счёта'), v_user_id);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Debit Client ───
CREATE OR REPLACE FUNCTION private.debit_client(
  p_client_id uuid,
  p_amount double precision,
  p_description text DEFAULT 'Списание со счёта',
  p_currency text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client clients%ROWTYPE;
  v_target_cur text;
  v_balances jsonb;
  v_cur_bal double precision;
  v_primary_bal double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Client not found'; END IF;
  IF NOT v_client.is_active THEN RAISE EXCEPTION 'Client account is inactive'; END IF;

  v_target_cur := COALESCE(NULLIF(trim(p_currency), ''), v_client.currency);

  SELECT balances INTO v_balances FROM client_balances WHERE client_id = p_client_id FOR UPDATE;
  IF v_balances IS NULL THEN v_balances := '{}'::jsonb; END IF;

  v_cur_bal := COALESCE((v_balances->>v_target_cur)::double precision, 0);
  IF v_cur_bal < p_amount THEN RAISE EXCEPTION 'Insufficient client balance'; END IF;

  v_balances := v_balances || jsonb_build_object(v_target_cur, round((v_cur_bal - p_amount)::numeric, 2));
  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  UPDATE client_balances SET balances = v_balances, balance = round(v_primary_bal::numeric, 2), updated_at = now()
  WHERE client_id = p_client_id;

  INSERT INTO client_transactions (client_id, type, amount, currency, balance_after, description, created_by)
  VALUES (p_client_id, 'debit', round(p_amount::numeric, 2), v_target_cur, round((v_cur_bal - p_amount)::numeric, 2),
          COALESCE(NULLIF(trim(p_description), ''), 'Списание со счёта'), v_user_id);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Set Exchange Rate ───
CREATE OR REPLACE FUNCTION private.set_exchange_rate(
  p_from_currency text,
  p_to_currency text,
  p_rate double precision
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_rate_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  v_rate_id := gen_random_uuid();
  INSERT INTO exchange_rates (id, from_currency, to_currency, rate, set_by, effective_at)
  VALUES (v_rate_id, p_from_currency, p_to_currency, p_rate, v_user_id, now());

  INSERT INTO audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('set_exchange_rate', 'exchangeRate', v_rate_id::text, v_user_id,
          jsonb_build_object('fromCurrency', p_from_currency, 'toCurrency', p_to_currency, 'rate', p_rate));

  RETURN jsonb_build_object('success', true);
END;
$$;


-- ============================================================
-- Enable Realtime for key tables (idempotent)
-- ============================================================
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'transfers','branches','branch_accounts','account_balances',
    'ledger_entries','notifications','clients','exchange_rates','purchases'
  ]
  LOOP
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    EXCEPTION WHEN duplicate_object THEN
      NULL; -- already added, skip
    END;
  END LOOP;
END;
$$;
