-- ============================================================
-- 028: Credit получателя только в момент «delivered»
-- ============================================================
-- Раньше confirm_transfer (created → toDelivery) сразу зачислял средства
-- на счёт получателя. Это создавало иллюзию, что филиал-получатель уже
-- держит деньги, хотя по факту они «у курьера» / «в пути». В аналитике
-- это давало завышенный баланс на филиале.
--
-- Новая логика:
--   * created    — debit отправителя (как было).
--   * toDelivery — статус + commission record + notify. БЕЗ credit'а.
--   * withCourier — статус + courier_name. БЕЗ credit'а.
--   * delivered  — credit + debit получателя одной операцией (net 0):
--                  деньги «появились и сразу выданы» клиенту.
--                  В ledger остаются обе записи.
--
-- Существующие переводы в toDelivery / withCourier — отыграть назад:
-- снять с account_balances «лишний» credit и убрать соответствующие
-- ledger-строки. issued_amount (частично выданные) учитываем.
-- ============================================================

BEGIN;

-- ── 1. Reverse credit'ов для уже-existing «in-flight» переводов ──
DO $$
DECLARE
  rec RECORD;
  v_remaining double precision;
  v_to_account uuid;
BEGIN
  FOR rec IN
    SELECT id, to_branch_id, to_account_id, converted_amount,
           COALESCE(issued_amount, 0) AS issued_amount,
           COALESCE(to_currency, currency) AS to_cur
      FROM public.transfers
     WHERE status IN ('toDelivery', 'withCourier')
       AND to_account_id IS NOT NULL
       AND to_account_id <> ''
  LOOP
    v_remaining := rec.converted_amount - rec.issued_amount;
    IF v_remaining <= 0 THEN CONTINUE; END IF;

    BEGIN
      v_to_account := rec.to_account_id::uuid;
    EXCEPTION WHEN others THEN
      CONTINUE;
    END;

    UPDATE public.account_balances
       SET balance    = balance - v_remaining,
           updated_at = now()
     WHERE account_id = v_to_account;

    DELETE FROM public.ledger_entries
     WHERE reference_type = 'transfer'
       AND reference_id   = rec.id::text
       AND branch_id      = rec.to_branch_id
       AND account_id     = v_to_account
       AND type           = 'credit';
  END LOOP;
END;
$$;

-- ── 2. confirm_transfer без credit'а ──
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

  v_to_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);

  SELECT currency INTO v_acc_currency
    FROM branch_accounts WHERE id = v_effective_to::uuid;
  IF v_transfer.to_currency IS NOT NULL
     AND v_transfer.to_currency <> ''
     AND v_acc_currency <> v_transfer.to_currency THEN
    RAISE EXCEPTION 'Счёт получателя в валюте %, перевод оформлен в %',
      v_acc_currency, v_transfer.to_currency;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, '');

  UPDATE transfers SET
    status        = 'toDelivery',
    confirmed_by  = v_user_id,
    confirmed_at  = now(),
    to_account_id = CASE
      WHEN to_account_id IS NULL OR to_account_id = '' THEN v_effective_to
      ELSE to_account_id
    END,
    to_currency   = COALESCE(v_to_currency, to_currency)
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
      'Получатель подтвердил приём — деньги в транзите до выдачи клиенту.',
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code
      )
    ),
    (
      v_transfer.to_branch_id::text,
      'transfer_confirmed',
      'Перевод ' || v_code || ' ожидает выдачи',
      'Ожидает выдачи получателю: '
        || to_char(v_transfer.converted_amount::numeric, 'FM999G999G990D00')
        || ' ' || COALESCE(v_transfer.to_currency, v_transfer.currency),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.confirm_transfer(uuid, text) TO authenticated;

-- ── 3. issue_transfer (полная выдача за один шаг) с credit+debit ──
CREATE OR REPLACE FUNCTION private.issue_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_t transfers%ROWTYPE;
  v_code text;
  v_remaining double precision;
  v_to_acc uuid;
  v_acc_currency text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_t.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_t.status;
  END IF;

  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);
  v_remaining := v_t.converted_amount - COALESCE(v_t.issued_amount, 0);
  IF v_remaining < 0 THEN v_remaining := 0; END IF;

  IF v_t.to_account_id IS NOT NULL AND v_t.to_account_id <> '' AND v_remaining > 0 THEN
    v_to_acc := v_t.to_account_id::uuid;
    SELECT currency INTO v_acc_currency
      FROM branch_accounts WHERE id = v_to_acc;

    -- credit (поступление) + debit (выдача клиенту) одной транзакцией.
    -- Net на account_balances = 0, в ledger остаются обе записи.
    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES (
      v_t.to_branch_id, v_to_acc, 'credit', v_remaining,
      COALESCE(v_acc_currency, v_t.to_currency, v_t.currency),
      'transfer', p_transfer_id::text, v_code,
      'Поступление по переводу ' || v_code, v_user_id
    ),
    (
      v_t.to_branch_id, v_to_acc, 'debit', v_remaining,
      COALESCE(v_acc_currency, v_t.to_currency, v_t.currency),
      'transfer_issuance', p_transfer_id::text, v_code,
      'Выдача по переводу ' || v_code, v_user_id
    );
  END IF;

  UPDATE transfers SET
    status        = 'delivered',
    issued_amount = converted_amount,
    issued_by     = v_user_id,
    issued_at     = now()
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_t.from_branch_id::text,
      'transfer_issued',
      'Перевод ' || v_code || ' выдан',
      'Деньги выданы получателю.',
      jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code)
    ),
    (
      v_t.to_branch_id::text,
      'transfer_issued',
      'Перевод ' || v_code || ' закрыт',
      'Выдача завершена.',
      jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code)
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.issue_transfer(uuid) TO authenticated;

-- ── 4. issue_transfer_partial — credit на каждую транш + debit ──
CREATE OR REPLACE FUNCTION private.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL,
  p_from_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_t transfers%ROWTYPE;
  v_remaining double precision;
  v_new_total double precision;
  v_code text;
  v_currency text;
  v_branch_name text;
  v_account_name text;
  v_acc_branch uuid;
  v_payout_account uuid;
  v_payout_currency text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_t.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_t.status;
  END IF;

  v_currency := COALESCE(v_t.to_currency, v_t.currency);
  v_remaining := v_t.converted_amount - COALESCE(v_t.issued_amount, 0);

  IF p_amount > v_remaining + 1e-6 THEN
    RAISE EXCEPTION 'Сумма выдачи (%) превышает остаток к выдаче (%)',
      round(p_amount::numeric, 2), round(v_remaining::numeric, 2);
  END IF;
  IF abs(p_amount - v_remaining) < 1e-6 THEN
    p_amount := v_remaining;
  END IF;

  IF p_from_account_id IS NOT NULL THEN
    v_payout_account := p_from_account_id;
  ELSIF v_t.to_account_id IS NOT NULL AND v_t.to_account_id <> '' THEN
    v_payout_account := v_t.to_account_id::uuid;
  ELSE
    RAISE EXCEPTION 'Не указан счёт выдачи и у перевода нет to_account_id';
  END IF;

  SELECT branch_id, name, currency
    INTO v_acc_branch, v_account_name, v_payout_currency
    FROM branch_accounts WHERE id = v_payout_account;
  IF v_acc_branch IS NULL THEN
    RAISE EXCEPTION 'Счёт выдачи не найден';
  END IF;
  IF v_acc_branch <> v_t.to_branch_id THEN
    RAISE EXCEPTION 'Счёт выдачи должен принадлежать филиалу получателя';
  END IF;
  IF v_payout_currency <> v_currency THEN
    RAISE EXCEPTION 'Валюта счёта выдачи (%) не совпадает с валютой перевода (%)',
      v_payout_currency, v_currency;
  END IF;

  v_new_total := COALESCE(v_t.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), v_payout_account);

  -- credit + debit одной операцией. account_balances не меняем (net 0).
  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES (
    v_acc_branch, v_payout_account, 'credit', p_amount, v_currency,
    'transfer', p_transfer_id::text, v_code,
    'Поступление по переводу ' || v_code, v_user_id
  ),
  (
    v_acc_branch, v_payout_account, 'debit', p_amount, v_currency,
    'transfer_issuance', p_transfer_id::text, v_code,
    'Выдача по переводу ' || v_code
      || COALESCE(' (' || v_account_name || ')', ''),
    v_user_id
  );

  IF v_new_total >= v_t.converted_amount - 1e-6 THEN
    UPDATE transfers SET
      status        = 'delivered',
      issued_amount = v_t.converted_amount,
      issued_by     = v_user_id,
      issued_at     = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_t.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_t.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' выдан',
        'Перевод выдан полностью в ' || COALESCE(v_branch_name, '—'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code
        )
      );

    RETURN jsonb_build_object('success', true, 'fullyIssued', true);
  ELSE
    UPDATE transfers SET issued_amount = v_new_total WHERE id = p_transfer_id;
    RETURN jsonb_build_object('success', true, 'fullyIssued', false);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.issue_transfer_partial(uuid, double precision, text, uuid) TO authenticated;

COMMIT;
