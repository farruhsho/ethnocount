-- ============================================================
-- 064: Guard от отрицательной кассы при частичной выдаче — Этап 1.1
-- ============================================================
-- Продолжение форензик-аудита F1. После F1 почти все списания кассы
-- уже защищены проверкой достаточности средств:
--   • create_transfer (044)            — RAISE «Insufficient funds»
--   • attach_transfer_to_partner/offset(056) — RAISE «Недостаточно средств…»
--   • record_counterparty_op / settle  (058) — RAISE «Недостаточно средств…»
--   • issue_transfer (полная выдача,028) — cash-neutral (приход+расход = 0)
--
-- Незащищённой оставалась ровно одна точка — issue_transfer_partial:
-- она списывает со счёта выдачи p_amount и пишет только расход (без
-- прихода), поэтому счёт мог уйти в минус (выдали больше наличных, чем
-- физически было). Это денежная ошибка: касса в минусе маскирует
-- недостачу.
--
-- Решение (подтверждено): жёсткий guard перед списанием — как в соседних
-- RPC. Тело функции воспроизведено из 056 без изменений; добавлены
-- только переменная v_acc_balance и блок проверки достаточности средств.
-- Партнёрское сальдо в минус остаётся легальным (это долг) и здесь не
-- затрагивается — guard только на кассу (account_balances).
--
-- НЕ ставим голый CHECK(balance >= 0) на колонку: это сломало бы легальные
-- сценарии корректировок. Проверяем в бизнес-логике RPC перед UPDATE.
-- Идемпотентно: CREATE OR REPLACE одной функции с той же сигнатурой
-- (привилегии и публичная обёртка сохраняются).
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
  v_acc_balance double precision;   -- 064: для guard достаточности кассы
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;

  -- F1 guard: перевод через партнёра выдаёт партнёр из своей кассы.
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

  -- ── 064 GUARD: нельзя выдать наличными больше, чем есть на счёте ──
  -- Зеркалит проверку из create_transfer/offset/settle. Блокирует уход
  -- кассы в минус (физически нельзя выплатить отсутствующие деньги).
  SELECT balance INTO v_acc_balance
    FROM account_balances WHERE account_id = v_payout_account FOR UPDATE;
  v_acc_balance := COALESCE(v_acc_balance, 0);
  IF v_acc_balance < p_amount THEN
    RAISE EXCEPTION
      'Недостаточно средств на счёте выдачи «%». Доступно: %, требуется: %',
      COALESCE(v_account_name, v_payout_account::text),
      round(v_acc_balance::numeric, 2), round(p_amount::numeric, 2);
  END IF;

  v_new_total := COALESCE(v_transfer.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), v_payout_account);

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_payout_account, v_acc_branch, -p_amount, v_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - p_amount,
        updated_at = now();

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES
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
