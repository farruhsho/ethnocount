-- ============================================================
-- 069: Выравнивание частичной выдачи к модели net-0 (CRITICAL-1)
-- ============================================================
-- ⚠️ ДРАФТ — НЕ ПРИМЕНЯТЬ без ревью бизнес-модели (см. ниже). Не применён к БД.
--
-- ПРОБЛЕМА (форензик-аудит 06.2026, CRITICAL-1):
--   issue_transfer (полная выдача, 028) пишет на счёт получателя credit+debit
--   одной операцией → net 0 на account_balances (касса не меняется).
--   issue_transfer_partial (064) пишет ТОЛЬКО debit на p_amount → касса
--   уменьшается. Один и тот же перевод, выданный целиком vs траншами, даёт
--   РАЗНЫЙ итоговый баланс кассы получателя. reconcile_branch это не ловит
--   (ledger и кэш согласованы между собой). Экономическое искажение.
--
-- РЕШЕНИЕ (рекомендованное, наименее разрушительное): привести частичную
-- выдачу к той же модели net-0, что и полная (028). Восстанавливает исходный
-- консистентный дизайн: выдача кассонейтральна (приход = расход), счёт
-- получателя не уходит в минус от самой выдачи, а фондирование филиала
-- ведётся отдельно (branch_topup / межфилиальные переводы).
--   • Возвращаем парный credit-leg (как в 028), убираем списание с
--     account_balances и guard 064 (под net-0 касса не двигается — guard
--     становится беспредметным, а не обходится).
--   • Сохраняем добавленные 064 проверки: via_counterparty (выплату делает
--     партнёр), принадлежность счёта филиалу получателя, совпадение валют.
--
-- АЛЬТЕРНАТИВА (если бизнес ведёт филиалы как кассовые float'ы с межфилиальным
-- учётом задолженности — cash-fronting): тогда наоборот, привести
-- issue_transfer (028) к debit-only, как в 064, и оставить guard. Это БОЛЬШЕ
-- изменение (выдача начнёт бросать «недостаточно средств» на нефондированных
-- филиалах) и требует учёта inter-branch settlement. НЕ реализуется здесь.
--
-- РЕШЕНИЕ ПО МОДЕЛИ — за бизнесом. По умолчанию выбран net-0 как менее рискованный.
-- Идемпотентно: CREATE OR REPLACE одной функции с той же сигнатурой.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL::text,
  p_from_account_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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
  v_payout_account uuid;
  v_payout_currency text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;

  -- F1 guard (из 064): перевод через партнёра выдаёт партнёр из своей кассы.
  IF v_transfer.via_counterparty_id IS NOT NULL THEN
    RAISE EXCEPTION 'Перевод привязан к партнёру — выплату делает партнёр. Сначала отвяжите от партнёра (detach).';
  END IF;

  IF v_transfer.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_transfer.status;
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

  IF p_from_account_id IS NOT NULL THEN
    v_payout_account := p_from_account_id;
  ELSIF v_transfer.to_account_id IS NOT NULL AND v_transfer.to_account_id <> '' THEN
    v_payout_account := v_transfer.to_account_id::uuid;
  ELSE
    RAISE EXCEPTION 'Не указан счёт выдачи и у перевода нет to_account_id';
  END IF;

  SELECT branch_id, name, currency
    INTO v_acc_branch, v_account_name, v_payout_currency
    FROM branch_accounts WHERE id = v_payout_account;
  IF v_acc_branch IS NULL THEN
    RAISE EXCEPTION 'Счёт выдачи не найден';
  END IF;
  IF v_acc_branch <> v_transfer.to_branch_id THEN
    RAISE EXCEPTION 'Счёт выдачи должен принадлежать филиалу получателя';
  END IF;
  IF v_payout_currency <> v_currency THEN
    RAISE EXCEPTION 'Валюта счёта выдачи (%) не совпадает с валютой перевода (%)',
      v_payout_currency, v_currency;
  END IF;

  v_new_total := COALESCE(v_transfer.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), v_payout_account);

  -- ── 069: net-0 (как в issue_transfer/028) ──
  -- credit (поступление) + debit (выдача) одной операцией. account_balances
  -- НЕ меняется — касса кассонейтральна, как при полной выдаче. Обе записи
  -- остаются в ledger для полного аудита.
  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES
    (v_acc_branch, v_payout_account, 'credit', p_amount, v_currency,
     'transfer', p_transfer_id::text, v_code,
     'Поступление по переводу ' || v_code, v_user_id),
    (v_acc_branch, v_payout_account, 'debit', p_amount, v_currency,
     'transfer_issuance', p_transfer_id::text, v_code,
     'Выдача по переводу ' || v_code
       || COALESCE(' (' || v_account_name || ')', ''),
     v_user_id);

  IF v_new_total >= v_transfer.converted_amount - 1e-6 THEN
    UPDATE transfers SET
      status        = 'delivered',
      issued_amount = v_transfer.converted_amount,
      issued_by     = v_user_id,
      issued_at     = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_transfer.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
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
$fn$;

GRANT EXECUTE ON FUNCTION private.issue_transfer_partial(uuid, double precision, text, uuid) TO authenticated;

COMMIT;
