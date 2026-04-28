-- ============================================================
-- 006: Atomic RPCs replacing client-side balance writes (F2)
-- ============================================================
-- Fixes:
--   C9: UNIQUE constraint on transfers.idempotency_key (closes race window)
--   C4: update_transfer_amount RPC (replaces client-side read-compute-write)
--   C5: update_purchase + delete_purchase RPCs (atomic reverse+reapply)
--   C6: adjust_balance + import_bank_transactions RPCs
--   M19/M22 hardening: balance writes now happen only via SECURITY DEFINER funcs
-- Idempotent — safe to re-run.
-- ============================================================

-- ─── C9: idempotency uniqueness (partial — ignores legacy empty strings) ───
DROP INDEX IF EXISTS public.idx_transfers_idempotency;
CREATE UNIQUE INDEX IF NOT EXISTS uniq_transfers_idempotency
  ON public.transfers (idempotency_key)
  WHERE idempotency_key IS NOT NULL AND idempotency_key <> '';

-- ─── adjust_balance: atomic single-row balance change + ledger entry ───
CREATE OR REPLACE FUNCTION private.adjust_balance(
  p_branch_id uuid,
  p_account_id uuid,
  p_amount double precision,
  p_currency text,
  p_type text,                 -- 'debit' or 'credit'
  p_reference_type text,
  p_reference_id text DEFAULT '',
  p_transaction_code text DEFAULT NULL,
  p_description text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_delta double precision;
  v_balance double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_type NOT IN ('debit', 'credit') THEN RAISE EXCEPTION 'p_type must be debit or credit'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  v_delta := CASE WHEN p_type = 'credit' THEN p_amount ELSE -p_amount END;

  -- Lock the balance row (or create it)
  SELECT balance INTO v_balance FROM account_balances WHERE account_id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_account_id, p_branch_id, v_delta, p_currency, now());
  ELSE
    IF p_type = 'debit' AND v_balance + v_delta < 0 THEN
      RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
        round(v_balance::numeric, 2), round(p_amount::numeric, 2);
    END IF;
    UPDATE account_balances
      SET balance = balance + v_delta, updated_at = now()
      WHERE account_id = p_account_id;
  END IF;

  INSERT INTO ledger_entries (
    branch_id, account_id, type, amount, currency,
    reference_type, reference_id, transaction_code, description, created_by
  )
  VALUES (
    p_branch_id, p_account_id, p_type, p_amount, p_currency,
    p_reference_type, COALESCE(p_reference_id, ''), p_transaction_code,
    COALESCE(p_description, ''), v_user_id
  );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── import_bank_transactions: bulk atomic ───
-- p_entries jsonb array of {amount, currency, type, description}
CREATE OR REPLACE FUNCTION private.import_bank_transactions(
  p_branch_id uuid,
  p_account_id uuid,
  p_entries jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_entry jsonb;
  v_amount double precision;
  v_currency text;
  v_type text;
  v_desc text;
  v_delta double precision;
  v_balance double precision;
  v_count int := 0;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  -- Lock the balance row once for the whole batch
  SELECT balance INTO v_balance FROM account_balances WHERE account_id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    v_balance := 0;
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_account_id, p_branch_id, 0,
            COALESCE((p_entries->0->>'currency'), 'USD'), now());
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_entries)
  LOOP
    v_amount := (v_entry->>'amount')::double precision;
    v_currency := COALESCE(v_entry->>'currency', 'USD');
    v_type := v_entry->>'type';
    v_desc := COALESCE(v_entry->>'description', '');

    IF v_type NOT IN ('debit', 'credit') THEN
      RAISE EXCEPTION 'entry type must be debit or credit (got %)', v_type;
    END IF;
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'entry amount must be positive';
    END IF;

    v_delta := CASE WHEN v_type = 'credit' THEN v_amount ELSE -v_amount END;
    v_balance := v_balance + v_delta;

    INSERT INTO ledger_entries (
      branch_id, account_id, type, amount, currency,
      reference_type, reference_id, description, created_by
    )
    VALUES (p_branch_id, p_account_id, v_type, v_amount, v_currency,
            'bankImport', '', v_desc, v_user_id);
    v_count := v_count + 1;
  END LOOP;

  UPDATE account_balances
    SET balance = v_balance, updated_at = now()
    WHERE account_id = p_account_id;

  RETURN jsonb_build_object('success', true, 'count', v_count);
END;
$$;

-- ─── update_transfer_amount: atomic amend (replaces client read-compute-write) ───
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
  IF v_t.status NOT IN ('pending') THEN
    RAISE EXCEPTION 'Only pending transfers can be amended (current: %)', v_t.status;
  END IF;

  v_old_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN v_t.amount + v_t.commission
                      ELSE v_t.amount END;

  v_new_commission := CASE
    WHEN v_t.commission_type = 'percentage' THEN p_new_amount * v_t.commission_value / 100
    ELSE v_t.commission_value
  END;

  v_new_total := CASE WHEN v_t.commission_mode = 'fromSender'
                      THEN p_new_amount + v_new_commission
                      ELSE p_new_amount END;

  v_eff_rate := COALESCE(p_new_exchange_rate, v_t.exchange_rate);
  v_receiver := CASE v_t.commission_mode
    WHEN 'fromTransfer' THEN p_new_amount - v_new_commission
    WHEN 'toReceiver'   THEN p_new_amount + v_new_commission
    ELSE p_new_amount
  END;

  v_delta := v_old_total - v_new_total;  -- positive = refund excess; negative = additional debit
  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  -- Lock balance row + apply delta
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

  -- Reversal + new debit ledger entries (full audit trail)
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'credit', v_old_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code, 'Сторно (изменён): ' || v_code, v_user_id);

  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency,
                              reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_t.from_branch_id, v_t.from_account_id, 'debit', v_new_total, v_t.currency,
          'transfer', p_transfer_id::text, v_code,
          'Перевод ' || v_code || ' (изменён, ожидает подтверждения)', v_user_id);

  -- Update transfer row, append amendment history
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

-- ─── update_purchase: atomic reverse-and-reapply ───
CREATE OR REPLACE FUNCTION private.update_purchase(
  p_purchase_id uuid,
  p_total_amount double precision DEFAULT NULL,
  p_payments jsonb DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_category text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_p purchases%ROWTYPE;
  v_old_payments jsonb;
  v_new_payments jsonb;
  v_payment jsonb;
  v_account_id uuid;
  v_amount double precision;
  v_acc_branch uuid;
  v_acc_currency text;
  v_balance double precision;
  v_desc text;
  v_changed boolean;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_p FROM purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

  v_old_payments := COALESCE(v_p.payments, '[]'::jsonb);
  v_new_payments := COALESCE(p_payments, v_old_payments);
  v_changed := (p_total_amount IS NOT NULL AND p_total_amount != v_p.total_amount)
            OR (p_payments IS NOT NULL);
  v_desc := COALESCE(p_description, v_p.description);

  IF v_changed THEN
    -- Reverse old: refund + ledger credit
    FOR v_payment IN SELECT * FROM jsonb_array_elements(v_old_payments)
    LOOP
      v_account_id := (v_payment->>'accountId')::uuid;
      v_amount := (v_payment->>'amount')::double precision;
      IF v_account_id IS NULL OR v_amount = 0 THEN CONTINUE; END IF;

      SELECT branch_id, currency INTO v_acc_branch, v_acc_currency FROM branch_accounts WHERE id = v_account_id;

      INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
      VALUES (v_account_id, COALESCE(v_acc_branch, v_p.branch_id), v_amount,
              COALESCE(v_payment->>'currency', v_acc_currency, v_p.currency), now())
      ON CONFLICT (account_id) DO UPDATE
        SET balance = account_balances.balance + v_amount, updated_at = now();

      INSERT INTO ledger_entries (
        branch_id, account_id, type, amount, currency,
        reference_type, reference_id, transaction_code, description, created_by
      )
      VALUES (COALESCE(v_acc_branch, v_p.branch_id), v_account_id, 'credit', v_amount,
              COALESCE(v_payment->>'currency', v_acc_currency, v_p.currency),
              'purchase', p_purchase_id::text, v_p.transaction_code,
              'Сторно (изменена): ' || v_p.transaction_code, v_user_id);
    END LOOP;

    -- Apply new: validate funds + debit + ledger debit
    FOR v_payment IN SELECT * FROM jsonb_array_elements(v_new_payments)
    LOOP
      v_account_id := (v_payment->>'accountId')::uuid;
      v_amount := (v_payment->>'amount')::double precision;
      IF v_account_id IS NULL OR v_amount = 0 THEN CONTINUE; END IF;

      SELECT branch_id, currency INTO v_acc_branch, v_acc_currency FROM branch_accounts WHERE id = v_account_id;

      SELECT balance INTO v_balance FROM account_balances WHERE account_id = v_account_id FOR UPDATE;
      IF v_balance IS NULL THEN v_balance := 0; END IF;
      IF v_balance < v_amount THEN
        RAISE EXCEPTION 'Insufficient balance in account %', v_payment->>'accountName';
      END IF;

      UPDATE account_balances
        SET balance = balance - v_amount, updated_at = now()
        WHERE account_id = v_account_id;

      INSERT INTO ledger_entries (
        branch_id, account_id, type, amount, currency,
        reference_type, reference_id, transaction_code, description, created_by
      )
      VALUES (COALESCE(v_acc_branch, v_p.branch_id), v_account_id, 'debit', v_amount,
              COALESCE(v_payment->>'currency', v_acc_currency, v_p.currency),
              'purchase', p_purchase_id::text, v_p.transaction_code,
              'Покупка ' || v_p.transaction_code || ': ' || v_desc, v_user_id);
    END LOOP;
  END IF;

  UPDATE purchases SET
    total_amount = COALESCE(p_total_amount, total_amount),
    payments = COALESCE(p_payments, payments),
    description = COALESCE(p_description, description),
    category = CASE WHEN p_category IS NULL THEN category
                    WHEN trim(p_category) = '' THEN NULL
                    ELSE trim(p_category) END
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── delete_purchase: atomic reversal + soft-delete ───
CREATE OR REPLACE FUNCTION private.delete_purchase(
  p_purchase_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_p purchases%ROWTYPE;
  v_payment jsonb;
  v_account_id uuid;
  v_amount double precision;
  v_acc_branch uuid;
  v_acc_currency text;
  v_deleted_by_name text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_p FROM purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;

  SELECT display_name INTO v_deleted_by_name FROM users WHERE id = v_user_id;

  -- Save snapshot
  INSERT INTO deleted_purchases (
    original_purchase_id, transaction_code, branch_id, client_id, client_name,
    description, category, total_amount, currency, payments,
    created_by_user_id, original_created_at,
    deleted_by_user_id, deleted_by_user_name, reason, original_data
  )
  VALUES (
    p_purchase_id::text, v_p.transaction_code, v_p.branch_id, v_p.client_id, v_p.client_name,
    v_p.description, v_p.category, v_p.total_amount, v_p.currency, v_p.payments,
    v_p.created_by, v_p.created_at,
    v_user_id, v_deleted_by_name, p_reason, to_jsonb(v_p)
  );

  -- Refund every payment
  FOR v_payment IN SELECT * FROM jsonb_array_elements(COALESCE(v_p.payments, '[]'::jsonb))
  LOOP
    v_account_id := (v_payment->>'accountId')::uuid;
    v_amount := (v_payment->>'amount')::double precision;
    IF v_account_id IS NULL OR v_amount = 0 THEN CONTINUE; END IF;

    SELECT branch_id, currency INTO v_acc_branch, v_acc_currency FROM branch_accounts WHERE id = v_account_id;

    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_account_id, COALESCE(v_acc_branch, v_p.branch_id), v_amount,
            COALESCE(v_payment->>'currency', v_acc_currency, v_p.currency), now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance + v_amount, updated_at = now();

    INSERT INTO ledger_entries (
      branch_id, account_id, type, amount, currency,
      reference_type, reference_id, transaction_code, description, created_by
    )
    VALUES (COALESCE(v_acc_branch, v_p.branch_id), v_account_id, 'credit', v_amount,
            COALESCE(v_payment->>'currency', v_acc_currency, v_p.currency),
            'purchase', p_purchase_id::text, v_p.transaction_code,
            'Сторно (удаление): ' || v_p.transaction_code ||
              CASE WHEN NULLIF(trim(p_reason), '') IS NOT NULL THEN ' — ' || p_reason ELSE '' END,
            v_user_id);
  END LOOP;

  DELETE FROM purchases WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true);
END;
$$;
