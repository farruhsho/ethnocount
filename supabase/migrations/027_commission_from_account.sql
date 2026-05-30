-- ============================================================
-- 027: Commission from a separate account (CommissionMode.fromAccount)
-- ============================================================
-- Сценарий: списать комиссию не из самой суммы перевода и не из
-- основного счёта-источника, а с произвольного счёта филиала-отправителя.
-- Валюта комиссии всегда равна валюте этого счёта.
--
-- Также этот файл актуализирует create_transfer под новый набор
-- статусов из 022_status_redesign (insert 'created' вместо 'pending').
-- ============================================================

BEGIN;

ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS commission_account_id uuid
    REFERENCES public.branch_accounts(id);

CREATE INDEX IF NOT EXISTS idx_transfers_commission_account
  ON public.transfers (commission_account_id)
  WHERE commission_account_id IS NOT NULL;

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
  p_receiver_info text DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_commission        double precision;
  v_total_debit       double precision;
  v_from_balance      double precision;
  v_acc_branch        uuid;
  v_code              text;
  v_transfer_id       uuid;
  v_resolved_to_cur   text;
  v_receiver_amount   double precision;
  v_converted         double precision;
  v_comm_acc_branch   uuid;
  v_comm_acc_currency text;
  v_comm_acc_balance  double precision;
  v_comm_charge       double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT branch_id INTO v_acc_branch
    FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Source account not found'; END IF;
  IF v_acc_branch <> p_from_branch_id THEN
    RAISE EXCEPTION 'Source account does not belong to source branch';
  END IF;

  -- ── Режим fromAccount: комиссия списывается ОТДЕЛЬНО, со своего счёта,
  --    в валюте этого счёта. Сумма перевода не корректируется.
  IF p_commission_mode = 'fromAccount' THEN
    IF p_commission_account_id IS NULL THEN
      RAISE EXCEPTION 'Для режима «комиссия с другого счёта» обязательно указание счёта';
    END IF;
    SELECT branch_id, currency
      INTO v_comm_acc_branch, v_comm_acc_currency
      FROM branch_accounts WHERE id = p_commission_account_id;
    IF v_comm_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Счёт комиссии не найден';
    END IF;
    IF v_comm_acc_branch <> p_from_branch_id THEN
      RAISE EXCEPTION 'Счёт комиссии должен принадлежать филиалу-отправителю';
    END IF;
    -- Валюту и значение коммисии принудительно подгоняем под этот счёт.
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value, v_comm_acc_currency,
      p_amount, v_comm_acc_currency
    );
    v_comm_charge := v_commission;
    v_total_debit := p_amount;
  ELSE
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value, p_commission_currency,
      p_amount, p_currency
    );
    v_comm_charge := 0;
    IF p_commission_mode = 'fromSender' THEN
      v_total_debit := p_amount + v_commission;
    ELSE
      v_total_debit := p_amount;
    END IF;
  END IF;

  -- Lock and check balance for the main source account.
  SELECT balance INTO v_from_balance
    FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  IF v_from_balance IS NULL THEN v_from_balance := 0; END IF;
  IF v_from_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
      round(v_from_balance::numeric, 2), round(v_total_debit::numeric, 2);
  END IF;

  -- Lock and check balance for commission account, if any.
  IF p_commission_mode = 'fromAccount' AND v_comm_charge > 0 THEN
    SELECT balance INTO v_comm_acc_balance
      FROM account_balances WHERE account_id = p_commission_account_id FOR UPDATE;
    IF v_comm_acc_balance IS NULL THEN v_comm_acc_balance := 0; END IF;
    IF v_comm_acc_balance < v_comm_charge THEN
      RAISE EXCEPTION 'Недостаточно средств на счёте комиссии. Доступно: % %, требуется: %',
        round(v_comm_acc_balance::numeric, 2), v_comm_acc_currency,
        round(v_comm_charge::numeric, 2);
    END IF;
  END IF;

  -- Resolve receiver currency.
  v_resolved_to_cur := p_currency;
  IF p_to_account_id IS NOT NULL AND p_to_account_id <> '' THEN
    SELECT currency INTO v_resolved_to_cur
      FROM branch_accounts WHERE id = p_to_account_id::uuid;
  ELSIF p_to_currency IS NOT NULL THEN
    v_resolved_to_cur := p_to_currency;
  END IF;

  IF p_commission_mode = 'fromTransfer' THEN
    v_receiver_amount := p_amount - v_commission;
  ELSIF p_commission_mode = 'toReceiver' THEN
    v_receiver_amount := p_amount + v_commission;
  ELSE
    -- fromSender / fromAccount — получатель получает всю сумму.
    v_receiver_amount := p_amount;
  END IF;
  v_converted := v_receiver_amount * p_exchange_rate;

  v_code := private.next_transaction_code('ELX', 'transactionCodes');
  v_transfer_id := gen_random_uuid();

  BEGIN
    INSERT INTO transfers (
      id, transaction_code, from_branch_id, to_branch_id,
      from_account_id, to_account_id,
      amount, currency, to_currency, exchange_rate, converted_amount,
      commission, commission_currency, commission_type, commission_value, commission_mode,
      commission_account_id,
      description, client_id,
      sender_name, sender_phone, sender_info,
      receiver_name, receiver_phone, receiver_info,
      status, created_by, idempotency_key, created_at
    ) VALUES (
      v_transfer_id, v_code, p_from_branch_id, p_to_branch_id,
      p_from_account_id, COALESCE(p_to_account_id, ''),
      p_amount, p_currency, v_resolved_to_cur, p_exchange_rate, v_converted,
      v_commission,
      CASE WHEN p_commission_mode = 'fromAccount' THEN v_comm_acc_currency
           ELSE p_commission_currency END,
      p_commission_type, p_commission_value, p_commission_mode,
      CASE WHEN p_commission_mode = 'fromAccount'
           THEN p_commission_account_id ELSE NULL END,
      p_description, p_client_id,
      p_sender_name, p_sender_phone, p_sender_info,
      p_receiver_name, p_receiver_phone, p_receiver_info,
      'created', v_user_id, p_idempotency_key, now()
    );
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate transfer — already exists';
  END;

  -- Debit основной счёт-источник.
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (p_from_account_id, p_from_branch_id, -v_total_debit, p_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - v_total_debit, updated_at = now();

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES
    (p_from_branch_id, p_from_account_id, 'debit', v_total_debit, p_currency,
     'transfer', v_transfer_id::text, v_code,
     'Перевод ' || v_code || ' (ожидает подтверждения)', v_user_id);

  -- Debit счёт комиссии (если режим fromAccount).
  IF p_commission_mode = 'fromAccount' AND v_comm_charge > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_commission_account_id, p_from_branch_id, -v_comm_charge,
            v_comm_acc_currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance - v_comm_charge, updated_at = now();

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES
      (p_from_branch_id, p_commission_account_id, 'debit', v_comm_charge,
       v_comm_acc_currency, 'commission', v_transfer_id::text, v_code,
       'Комиссия по переводу ' || v_code || ' (отдельный счёт)', v_user_id);
  END IF;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES (
    p_to_branch_id::text,
    'incoming_transfer',
    'Новый перевод ' || v_code,
    'Входящий: ' || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || p_currency,
    jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code)
  );

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;

-- public wrapper с новой сигнатурой.
DROP FUNCTION IF EXISTS public.create_transfer(
  uuid, uuid, uuid, text, text, double precision, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text
);

CREATE OR REPLACE FUNCTION public.create_transfer(
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
  p_receiver_info text DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.create_transfer(
    p_from_branch_id, p_to_branch_id, p_from_account_id, p_to_account_id,
    p_to_currency, p_amount, p_currency, p_exchange_rate,
    p_commission_type, p_commission_value, p_commission_currency, p_commission_mode,
    p_idempotency_key, p_description, p_client_id,
    p_sender_name, p_sender_phone, p_sender_info,
    p_receiver_name, p_receiver_phone, p_receiver_info,
    p_commission_account_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.create_transfer(
  uuid, uuid, uuid, text, text, double precision, text, double precision,
  text, double precision, text, text, text, text, text,
  text, text, text, text, text, text, uuid
) TO authenticated;

COMMIT;
