-- ============================================================
-- 014: Track issuance card, notify on amend, director sees notifications
-- ============================================================
-- Changes:
--   1. transfer_issuances.from_account_id — какая карта/счёт использовалась
--      для выдачи. Добавляется как nullable, чтобы старые записи остались.
--   2. issue_transfer_partial(p_from_account_id) — принимает счёт-источник.
--   3. update_transfer_amount теперь создаёт уведомления (transferAmended)
--      на оба филиала, чтобы второй бухгалтер увидел правку.
--   4. RLS на public.notifications: директор тоже видит все уведомления
--      (раньше — только creator, target_user, ассайн на филиал).
-- Idempotent.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. transfer_issuances.from_account_id
-- ─────────────────────────────────────────────────────────────

ALTER TABLE public.transfer_issuances
  ADD COLUMN IF NOT EXISTS from_account_id uuid
    REFERENCES public.branch_accounts(id);

CREATE INDEX IF NOT EXISTS idx_transfer_issuances_from_account
  ON public.transfer_issuances (from_account_id);

-- ─────────────────────────────────────────────────────────────
-- 2. issue_transfer_partial: новый параметр p_from_account_id
-- ─────────────────────────────────────────────────────────────
-- Старая сигнатура (uuid, double precision, text) остаётся —
-- внутри она просто делегирует с NULL-счётом.

CREATE OR REPLACE FUNCTION private.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL,
  p_from_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_remaining double precision;
  v_new_total double precision;
  v_code text;
  v_currency text;
  v_branch_name text;
  v_account_name text;
  v_acc_branch uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status NOT IN ('confirmed') THEN
    RAISE EXCEPTION 'Выдача возможна только для подтверждённых переводов (текущий статус: %)', v_transfer.status;
  END IF;

  v_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);
  v_remaining := v_transfer.converted_amount - COALESCE(v_transfer.issued_amount, 0);

  IF p_amount > v_remaining + 1e-6 THEN
    RAISE EXCEPTION 'Сумма выдачи (%) превышает остаток к выдаче (%)',
      round(p_amount::numeric, 2), round(v_remaining::numeric, 2);
  END IF;
  IF abs(p_amount - v_remaining) < 1e-6 THEN
    p_amount := v_remaining;
  END IF;

  -- Если указан счёт — он должен принадлежать получающему филиалу
  IF p_from_account_id IS NOT NULL THEN
    SELECT branch_id, name INTO v_acc_branch, v_account_name
      FROM branch_accounts WHERE id = p_from_account_id;
    IF v_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Счёт выдачи не найден';
    END IF;
    IF v_acc_branch <> v_transfer.to_branch_id THEN
      RAISE EXCEPTION 'Счёт выдачи должен принадлежать филиалу получателя';
    END IF;
  END IF;

  v_new_total := COALESCE(v_transfer.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), p_from_account_id);

  IF v_new_total >= v_transfer.converted_amount - 1e-6 THEN
    UPDATE transfers SET
      status = 'issued',
      issued_amount = v_transfer.converted_amount,
      issued_by = v_user_id,
      issued_at = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_transfer.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' выдан',
        'Перевод ' || to_char(v_transfer.amount::numeric, 'FM999G999G990D00')
          || ' ' || v_transfer.currency
          || ' полностью выдан получателю в ' || COALESCE(v_branch_name, '—')
          || COALESCE(' (счёт: ' || v_account_name || ')', ''),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', v_transfer.amount,
          'currency', v_transfer.currency,
          'fromAccountId', p_from_account_id,
          'fromAccountName', v_account_name
        )
      ),
      (
        v_transfer.to_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' закрыт',
        'Финальная выдача '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || '. Перевод полностью передан.',
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', true,
          'fromAccountId', p_from_account_id,
          'fromAccountName', v_account_name
        )
      );

    RETURN jsonb_build_object(
      'success', true,
      'fullyIssued', true,
      'remaining', 0,
      'amount', p_amount,
      'fromAccountId', p_from_account_id
    );
  ELSE
    UPDATE transfers SET issued_amount = v_new_total WHERE id = p_transfer_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || ' из ' || to_char(v_transfer.converted_amount::numeric, 'FM999G999G990D00')
          || '. Остаток: ' || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total,
          'fromAccountId', p_from_account_id,
          'fromAccountName', v_account_name
        )
      ),
      (
        v_transfer.to_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || ' получателю. Остаток к выдаче: '
          || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total,
          'fromAccountId', p_from_account_id,
          'fromAccountName', v_account_name
        )
      );

    RETURN jsonb_build_object(
      'success', true,
      'fullyIssued', false,
      'remaining', v_transfer.converted_amount - v_new_total,
      'amount', p_amount,
      'fromAccountId', p_from_account_id
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION
  private.issue_transfer_partial(uuid, double precision, text, uuid)
  TO authenticated;

-- Public-обёртка с новой сигнатурой
CREATE OR REPLACE FUNCTION public.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL,
  p_from_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT private.issue_transfer_partial(p_transfer_id, p_amount, p_note, p_from_account_id);
$$;

GRANT EXECUTE ON FUNCTION
  public.issue_transfer_partial(uuid, double precision, text, uuid)
  TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 3. update_transfer_amount: уведомлять второго бухгалтера
-- ─────────────────────────────────────────────────────────────

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
  v_actor_name text;
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

  -- ─── Уведомления — второму бухгалтеру (другой филиал) и принимающему. ───
  SELECT display_name INTO v_actor_name FROM users WHERE id = v_user_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_t.to_branch_id::text,
      'transfer_amended',
      'Перевод ' || v_code || ' изменён',
      COALESCE(v_actor_name, 'Бухгалтер')
        || ' изменил сумму перевода: '
        || to_char(v_t.amount::numeric, 'FM999G999G990D00') || ' → '
        || to_char(p_new_amount::numeric, 'FM999G999G990D00') || ' ' || v_t.currency
        || COALESCE('. Заметка: ' || NULLIF(trim(p_amendment_note), ''), ''),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'oldAmount', v_t.amount,
        'newAmount', p_new_amount,
        'currency', v_t.currency,
        'amendedBy', v_user_id::text,
        'note', p_amendment_note
      )
    ),
    -- Также уведомление для самого отправляющего филиала — чтобы второй
    -- бухгалтер этого же филиала, если он есть, тоже увидел правку.
    (
      v_t.from_branch_id::text,
      'transfer_amended',
      'Перевод ' || v_code || ' изменён',
      'Сумма перевода обновлена: '
        || to_char(v_t.amount::numeric, 'FM999G999G990D00') || ' → '
        || to_char(p_new_amount::numeric, 'FM999G999G990D00') || ' ' || v_t.currency,
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'oldAmount', v_t.amount,
        'newAmount', p_new_amount,
        'currency', v_t.currency,
        'amendedBy', v_user_id::text,
        'note', p_amendment_note
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 4. RLS на notifications: директор видит все уведомления
-- ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "notif_select" ON public.notifications;
CREATE POLICY "notif_select" ON public.notifications FOR SELECT TO authenticated
  USING (
    private.is_creator()
    OR private.is_director()
    OR target_user_id = auth.uid()
    OR target_branch_id = '' OR target_branch_id IS NULL
    OR target_branch_id = ANY(private.user_branches())
  );

DROP POLICY IF EXISTS "notif_update" ON public.notifications;
CREATE POLICY "notif_update" ON public.notifications FOR UPDATE TO authenticated
  USING (
    private.is_creator()
    OR private.is_director()
    OR target_user_id = auth.uid()
    OR target_branch_id = ANY(private.user_branches())
  );
