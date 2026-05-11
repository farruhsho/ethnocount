-- ============================================================
-- 020: issue_transfer_partial debits the payout account
-- ============================================================
-- Контекст: жалоба пользователя — при выдаче (issue) деньги физически
-- покидают кассу/карту получающего филиала, но `account_balances`
-- остаётся прежним.  В результате баланс кассы Москвы выглядит как +1000
-- даже после того, как кассир уже отдал клиенту 1000 наличными.
--
-- Текущая бухгалтерия:
--   create_transfer  → DEBIT  sender (Ташкент): -(amount + commission)
--   confirm_transfer → CREDIT receiver to_account (Москва main): +converted
--   issue_transfer*  → ничего к балансам не делает (только trans_issuances)
--
-- Что должно быть:
--   issue_transfer_partial → DEBIT  payout-account (Москва drawer): -amount
--                            + соответствующий ledger_entry 'debit'.
--
--   Если кассир выбрал тот же счёт, что и to_account_id, то confirm
--   (+amount) и issue (-amount) полностью гасятся — Москва-филиал
--   остаётся при своих, что и есть правильно: они «прокачали» транзит.
--   Если кассир выбрал другой счёт (например, выдал из «Кассы», а
--   confirm пришёл на «Карту Сбер»), баланс перетечёт между двумя
--   реальными счётами одного филиала — это можно потом выровнять
--   внутренним переводом.
--
-- Резерв `p_from_account_id` IS NULL → берём `transfer.to_account_id`
-- (default behaviour: списываем с того же счёта, куда зачислил confirm).
--
-- Идемпотентно: CREATE OR REPLACE.  Ленивая миграция — все ранее выданные
-- (status='issued') переводы НЕ ретроактивно пересчитываются, иначе мы
-- бы дважды списали те случаи, когда оператор уже поправил баланс
-- вручную.  Если нужна ретро-сверка — отдельный скрипт под надзором.
-- ============================================================

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

  -- Resolve payout account: explicit param wins, fallback = transfer.to_account_id.
  -- Если to_account_id строкой пуст (старые pending без счёта) — потребуем явный.
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

  -- 1. Запись в журнал выдач.
  INSERT INTO transfer_issuances
    (transfer_id, amount, currency, issued_by, note, from_account_id)
  VALUES
    (p_transfer_id, p_amount, v_currency, v_user_id,
     NULLIF(trim(p_note), ''), v_payout_account);

  -- 2. КРИТИЧНО: списываем сумму с физического счёта-источника.
  --    Раньше этого UPDATE не было, поэтому баланс кассы оставался
  --    неизменным после фактической выдачи денег клиенту.
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_payout_account, v_acc_branch, -p_amount, v_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - p_amount,
        updated_at = now();

  -- 3. Лежер-проводка: 'debit' с привязкой к транзакции.
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
      status = 'issued',
      issued_amount = v_transfer.converted_amount,
      issued_by = v_user_id,
      issued_at = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_transfer.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text, 'transfer_issued',
        'Перевод ' || v_code || ' выдан',
        'Перевод ' || to_char(v_transfer.amount::numeric, 'FM999G999G990D00')
          || ' ' || v_transfer.currency
          || ' полностью выдан получателю в ' || COALESCE(v_branch_name, '—')
          || COALESCE(' (счёт: ' || v_account_name || ')', ''),
        jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code,
          'amount', v_transfer.amount, 'currency', v_transfer.currency,
          'fromAccountId', v_payout_account, 'fromAccountName', v_account_name)
      ),
      (
        v_transfer.to_branch_id::text, 'transfer_issued',
        'Перевод ' || v_code || ' закрыт',
        'Финальная выдача ' || to_char(p_amount::numeric, 'FM999G999G990D00')
          || ' ' || v_currency || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || '. Перевод полностью передан.',
        jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code,
          'amount', p_amount, 'currency', v_currency, 'finalTranche', true,
          'fromAccountId', v_payout_account, 'fromAccountName', v_account_name)
      );

    RETURN jsonb_build_object('success', true, 'fullyIssued', true,
      'remaining', 0, 'amount', p_amount, 'fromAccountId', v_payout_account);
  ELSE
    UPDATE transfers SET issued_amount = v_new_total WHERE id = p_transfer_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text, 'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано ' || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || ' из ' || to_char(v_transfer.converted_amount::numeric, 'FM999G999G990D00')
          || '. Остаток: ' || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code,
          'amount', p_amount, 'currency', v_currency, 'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total,
          'fromAccountId', v_payout_account, 'fromAccountName', v_account_name)
      ),
      (
        v_transfer.to_branch_id::text, 'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано ' || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || COALESCE(' (счёт: ' || v_account_name || ')', '')
          || ' получателю. Остаток к выдаче: '
          || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object('transferId', p_transfer_id::text, 'transactionCode', v_code,
          'amount', p_amount, 'currency', v_currency, 'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total,
          'fromAccountId', v_payout_account, 'fromAccountName', v_account_name)
      );

    RETURN jsonb_build_object('success', true, 'fullyIssued', false,
      'remaining', v_transfer.converted_amount - v_new_total,
      'amount', p_amount, 'fromAccountId', v_payout_account);
  END IF;
END;
$$;
