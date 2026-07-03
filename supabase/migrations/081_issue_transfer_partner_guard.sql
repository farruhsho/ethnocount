-- ============================================================
-- 081: Партнёрский guard в полной выдаче issue_transfer (CRITICAL)
-- ============================================================
-- ПРОБЛЕМА (ре-аудит 07.2026, CRITICAL): частичная выдача
-- issue_transfer_partial (064/069) блокирует перевод, привязанный к
-- партнёру (`via_counterparty_id IS NOT NULL`) — выплату делает партнёр
-- из своей кассы, а наша касса под F1-моделью (056) не двигается. Но
-- ПОЛНАЯ выдача private.issue_transfer (последняя редакция — 028) такого
-- guard'а НЕ имеет и никогда не переопределялась после 028.
--
-- Сценарий двойной выплаты:
--   1) создать перевод → confirm (status='toDelivery');
--   2) attach_transfer_to_partner (042 разрешает привязку в любом статусе)
--      → via_counterparty_id проставлен, дебет кассы откачен через
--        partner_offset, saldo партнёра выросло;
--   3) перевод всё ещё toDelivery и виден в списке «к выдаче»;
--   4) полный issue_transfer выдаёт остаток из НАШЕЙ кассы (net-0 leg),
--      хотя партнёр тоже платит → двойная выплата.
-- Это ровно класс инцидента ELX-2026-000019, ради которого писалась
-- миграция 063 (ручное разрешение конфликтных партнёрских переводов).
--
-- РЕШЕНИЕ: добавить в issue_transfer тот же F1-guard, что в 069, плюс
-- (для паритета с 069) проверку принадлежности счёта выдачи филиалу
-- получателя и совпадения валют. Остальная логика net-0 из 028 —
-- без изменений.
--
-- Идемпотентно: CREATE OR REPLACE той же сигнатуры. Re-GRANT.
-- ============================================================

BEGIN;

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
  v_acc_branch uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;

  -- ── 081: F1 guard (как в issue_transfer_partial/069) ──
  -- Перевод через партнёра выплачивает партнёр из своей кассы; наша касса
  -- под F1-моделью (056) не двигается. Полная выдача из нашей кассы =
  -- двойная выплата. Сначала отвязать от партнёра (detach).
  IF v_t.via_counterparty_id IS NOT NULL THEN
    RAISE EXCEPTION 'Перевод привязан к партнёру — выплату делает партнёр. Сначала отвяжите от партнёра (detach).';
  END IF;

  IF v_t.status NOT IN ('toDelivery', 'withCourier') THEN
    RAISE EXCEPTION 'Выдача возможна только из «к выдаче» или «у курьера» (текущий: %)', v_t.status;
  END IF;

  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);
  v_remaining := v_t.converted_amount - COALESCE(v_t.issued_amount, 0);
  IF v_remaining < 0 THEN v_remaining := 0; END IF;

  IF v_t.to_account_id IS NOT NULL AND v_t.to_account_id <> '' AND v_remaining > 0 THEN
    v_to_acc := v_t.to_account_id::uuid;
    SELECT branch_id, currency INTO v_acc_branch, v_acc_currency
      FROM branch_accounts WHERE id = v_to_acc;

    -- ── 081: проверки счёта выдачи (паритет с issue_transfer_partial/069) ──
    -- confirm_transfer (072) уже валидирует счёт/валюту при приёме, но
    -- дублируем на выдаче как защиту от дрейфа (счёт мог быть архивирован /
    -- переоформлен между confirm и issue).
    IF v_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Счёт выдачи не найден';
    END IF;
    IF v_acc_branch <> v_t.to_branch_id THEN
      RAISE EXCEPTION 'Счёт выдачи должен принадлежать филиалу получателя';
    END IF;
    IF v_acc_currency IS NOT NULL
       AND v_acc_currency <> COALESCE(v_t.to_currency, v_t.currency) THEN
      RAISE EXCEPTION 'Валюта счёта выдачи (%) не совпадает с валютой перевода (%)',
        v_acc_currency, COALESCE(v_t.to_currency, v_t.currency);
    END IF;

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

COMMIT;
