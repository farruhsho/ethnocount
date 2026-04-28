-- ============================================================
-- 005: Ledger consistency fixes (F1)
-- ============================================================
-- Fixes:
--   C1: cancelTransfer must refund balance + write compensating ledger credit
--   C2: confirm_transfer must record commission in commissions table
--   C3: reject_transfer must write compensating ledger credit (was only refunding cached balance)
-- Also adds cancelled_by / cancelled_at / cancellation_reason columns on transfers.
-- Idempotent — safe to run multiple times.
-- ============================================================

-- ─── Add cancellation audit columns ───
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS cancelled_by uuid,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancellation_reason text;

-- ─── Ensure commissions table can store the from_branch (was nullable, OK) ───
-- (no schema change needed; columns already exist)

-- ─── Cancel Transfer (atomic, refunds + writes ledger credit) ───
CREATE OR REPLACE FUNCTION private.cancel_transfer(
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
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'pending' THEN
    RAISE EXCEPTION 'Only pending transfers can be cancelled (current: %)', v_transfer.status;
  END IF;

  -- Mirror the debit logic from create_transfer
  IF v_transfer.commission_mode = 'fromSender' THEN
    v_total := v_transfer.amount + v_transfer.commission;
  ELSE
    v_total := v_transfer.amount;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  -- Update status with audit fields
  UPDATE transfers SET
    status = 'cancelled',
    cancelled_by = v_user_id,
    cancelled_at = now(),
    cancellation_reason = NULLIF(trim(p_reason), '')
  WHERE id = p_transfer_id;

  -- Refund balance (UPSERT in case row was deleted/missing)
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_transfer.from_account_id, v_transfer.from_branch_id, v_total, v_transfer.currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance + v_total,
        updated_at = now();

  -- Compensating ledger credit (double-entry consistency)
  INSERT INTO ledger_entries (
    branch_id, account_id, type, amount, currency,
    reference_type, reference_id, transaction_code, description, created_by
  )
  VALUES (
    v_transfer.from_branch_id, v_transfer.from_account_id, 'credit', v_total, v_transfer.currency,
    'transfer', p_transfer_id::text, v_code,
    'Сторно (отменён): ' || v_code ||
      CASE WHEN NULLIF(trim(p_reason), '') IS NOT NULL THEN ' — ' || p_reason ELSE '' END,
    v_user_id
  );

  -- Notifications
  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (v_transfer.from_branch_id::text, 'transfer_cancelled', 'Перевод отменён',
     'Перевод ' || v_code || ' отменён.',
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason)),
    (v_transfer.to_branch_id::text, 'transfer_cancelled', 'Перевод отменён',
     'Перевод ' || v_code || ' отменён отправителем.',
     jsonb_build_object('transferId', p_transfer_id::text, 'reason', p_reason));

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─── Reject Transfer (refund + compensating ledger credit) ───
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
  v_code text;
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

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET
    status = 'rejected',
    rejected_by = v_user_id,
    rejection_reason = p_reason,
    rejected_at = now()
  WHERE id = p_transfer_id;

  -- Refund (UPSERT-safe)
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_transfer.from_account_id, v_transfer.from_branch_id, v_total, v_transfer.currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance + v_total,
        updated_at = now();

  -- Compensating ledger credit (was missing — caused ledger/balance divergence)
  INSERT INTO ledger_entries (
    branch_id, account_id, type, amount, currency,
    reference_type, reference_id, transaction_code, description, created_by
  )
  VALUES (
    v_transfer.from_branch_id, v_transfer.from_account_id, 'credit', v_total, v_transfer.currency,
    'transfer', p_transfer_id::text, v_code,
    'Сторно (отклонён): ' || v_code ||
      CASE WHEN NULLIF(trim(p_reason), '') IS NOT NULL THEN ' — ' || p_reason ELSE '' END,
    v_user_id
  );

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

-- ─── Confirm Transfer (now records commission row + uses entry id, not ctid) ───
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

  SELECT currency INTO v_acc_currency FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_transfer.to_currency IS NOT NULL AND v_transfer.to_currency != '' AND v_acc_currency != v_transfer.to_currency THEN
    RAISE EXCEPTION 'Счёт получателя в валюте %, перевод оформлен в %', v_acc_currency, v_transfer.to_currency;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

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
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance + v_transfer.converted_amount,
        updated_at = now();

  -- Ledger credit for receiver
  INSERT INTO ledger_entries (branch_id, account_id, type, amount, currency, reference_type, reference_id, transaction_code, description, created_by)
  VALUES (v_transfer.to_branch_id, v_effective_to::uuid, 'credit', v_transfer.converted_amount, COALESCE(v_acc_currency, v_to_currency),
          'transfer', p_transfer_id::text, v_code, 'Перевод ' || v_code || ' (подтверждён)', v_user_id);

  -- Update ALL pending sender ledger descriptions for this transfer (safer than ctid+LIMIT 1)
  UPDATE ledger_entries SET description = 'Перевод ' || v_code || ' (подтверждён)'
  WHERE reference_type = 'transfer'
    AND reference_id = p_transfer_id::text
    AND branch_id = v_transfer.from_branch_id
    AND type = 'debit';

  -- Record commission for reporting (M19 + C2)
  IF v_transfer.commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (p_transfer_id, v_transfer.from_branch_id, v_transfer.commission,
            COALESCE(NULLIF(v_transfer.commission_currency, ''), v_transfer.currency),
            COALESCE(v_transfer.commission_type, 'fixed'), now());
  END IF;

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
