-- ============================================================
-- 056: F1 (откат дебета кассы при привязке к партнёру)
--      + F2 (округление saldo в JSONB)
-- ============================================================
-- Проблема F1:
--   create_transfer дебетует счёт-источник на сумму перевода
--   (модель «платим мы»). Когда перевод привязывают к партнёру
--   (attach), платит ПАРТНЁР из своей кассы, а мы лишь копим долг
--   (saldo). Старый attach НЕ откатывал дебет источника -> касса
--   уходила дважды: при оформлении и при расчёте с партнёром.
--
-- Решение (выбор пользователя «Откатывать при привязке»):
--   • attach  -> кредит-возврат на счёт-источник (откат дебета),
--                деньги уходят только при settle_from_us.
--   • detach  -> повторный дебет (снова «платим мы»).
--   • guard   -> нельзя привязать перевод, по которому уже была
--                выдача (issue), и наоборот (зеркальный guard в
--                issue_transfer_partial).
--   • create_partner_transfer (all-in-one) больше не дебетует
--     счёт на тело перевода — только saldo (как в attach-модели).
--
-- Маркер отката: ledger_entries.reference_type = 'partner_offset'
--   credit при attach, debit при detach. Чистый остаток
--   (sum credit - sum debit) > 0 означает «откат активен».
--   Это даёт идемпотентность и точный возврат суммы.
--
-- Проблема F2 (JSONB saldo):
--   numeric-колонки (миграция 055) округляют сами, но saldo_by_currency
--   хранится в JSONB -> округляем round(...,4) перед каждой записью.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- record_counterparty_op: округление saldo и settlement_profit (F2)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL::text,
  p_cash_account_id uuid DEFAULT NULL::uuid,
  p_transfer_id uuid DEFAULT NULL::uuid,
  p_payout_method text DEFAULT NULL::text,
  p_exchange_rate double precision DEFAULT NULL::double precision,
  p_close_amount double precision DEFAULT NULL::double precision,
  p_close_currency text DEFAULT NULL::text,
  p_expected_rate double precision DEFAULT NULL::double precision)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_cp counterparties%ROWTYPE;
  v_cash_cur text;
  v_saldo_cur text;
  v_curr_saldo double precision;
  v_saldo_delta double precision;
  v_new_saldo double precision;
  v_acc branch_accounts%ROWTYPE;
  v_cash_delta double precision;
  v_acc_balance double precision;
  v_role text;
  v_close_amount double precision;
  v_settlement_profit double precision := 0;
  v_actual_rate double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Партнёр деактивирован'; END IF;

  v_cash_cur := upper(trim(p_currency));
  IF v_cash_cur = '' THEN RAISE EXCEPTION 'Валюта обязательна'; END IF;

  v_saldo_cur := upper(COALESCE(NULLIF(trim(p_close_currency), ''), v_cash_cur));
  v_close_amount := COALESCE(p_close_amount, p_amount);
  IF v_close_amount <= 0 THEN
    RAISE EXCEPTION 'closes_amount должен быть > 0';
  END IF;

  v_saldo_delta := CASE p_kind
    WHEN 'paid_for_us'      THEN -v_close_amount
    WHEN 'we_paid_for_them' THEN  v_close_amount
    WHEN 'settle_to_us'     THEN -v_close_amount
    WHEN 'settle_from_us'   THEN  v_close_amount
    ELSE NULL
  END;
  IF v_saldo_delta IS NULL THEN
    RAISE EXCEPTION 'Неизвестный тип операции: %', p_kind;
  END IF;

  IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
    IF p_cash_account_id IS NULL THEN
      RAISE EXCEPTION
        'Для расчёта (settle) обязательно укажите кеш-счёт нашего филиала';
    END IF;
    SELECT * INTO v_acc FROM branch_accounts WHERE id = p_cash_account_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Кеш-счёт не найден'; END IF;
    IF upper(v_acc.currency) <> v_cash_cur THEN
      RAISE EXCEPTION
        'Валюта расчёта (%) не совпадает с валютой выбранного счёта (%)',
        v_cash_cur, v_acc.currency;
    END IF;

    v_cash_delta := CASE p_kind
      WHEN 'settle_to_us'   THEN  p_amount
      WHEN 'settle_from_us' THEN -p_amount
    END;

    IF v_cash_delta < 0 THEN
      SELECT balance INTO v_acc_balance
        FROM account_balances WHERE account_id = p_cash_account_id FOR UPDATE;
      v_acc_balance := COALESCE(v_acc_balance, 0);
      IF v_acc_balance + v_cash_delta < 0 THEN
        RAISE EXCEPTION
          'Недостаточно средств на счёте для расчёта. Доступно: %, требуется: %',
          round(v_acc_balance::numeric, 2), round(p_amount::numeric, 2);
      END IF;
    END IF;

    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_cash_account_id, v_acc.branch_id, round(v_cash_delta::numeric, 4), v_acc.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = round((account_balances.balance + v_cash_delta)::numeric, 4),
          updated_at = now();

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, description, created_by)
    VALUES (
      v_acc.branch_id, p_cash_account_id,
      CASE WHEN v_cash_delta >= 0 THEN 'credit' ELSE 'debit' END,
      p_amount, v_acc.currency,
      'adjustment',
      'cp:' || p_counterparty_id::text,
      CASE WHEN p_kind = 'settle_to_us'
           THEN 'Расчёт от партнёра ' || v_cp.name
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
           ELSE 'Расчёт партнёру ' || v_cp.name
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
      END,
      v_uid
    );

    IF v_saldo_cur <> v_cash_cur AND p_expected_rate IS NOT NULL
       AND p_expected_rate > 0 AND v_close_amount > 0 THEN
      v_actual_rate := p_amount / v_close_amount;
      v_settlement_profit := CASE p_kind
        WHEN 'settle_from_us' THEN (p_expected_rate - v_actual_rate) * v_close_amount
        WHEN 'settle_to_us'   THEN (v_actual_rate - p_expected_rate) * v_close_amount
        ELSE 0
      END;
    END IF;
  END IF;

  -- F2: округляем профит расчёта до 4 знаков
  v_settlement_profit := round(COALESCE(v_settlement_profit, 0)::numeric, 4);

  -- ── Двигаем saldo партнёра (F2: round перед записью в JSONB) ──
  v_curr_saldo := round(COALESCE(
    (v_cp.saldo_by_currency->>v_saldo_cur)::double precision, 0)::numeric, 4);
  v_new_saldo := round((v_curr_saldo + v_saldo_delta)::numeric, 4);

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_saldo_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

  INSERT INTO counterparty_transactions
    (counterparty_id, kind, amount, currency, description, created_by,
     transfer_id, cash_account_id, payout_method, exchange_rate,
     closes_amount, closes_currency, expected_rate,
     settlement_profit, settlement_profit_currency)
  VALUES
    (p_counterparty_id, p_kind, p_amount, v_cash_cur,
     NULLIF(trim(p_description), ''), v_uid,
     p_transfer_id, p_cash_account_id,
     NULLIF(trim(p_payout_method), ''), p_exchange_rate,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_close_amount ELSE NULL END,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_saldo_cur ELSE NULL END,
     p_expected_rate,
     NULLIF(v_settlement_profit, 0),
     CASE WHEN v_settlement_profit <> 0 THEN v_cash_cur ELSE NULL END);

  RETURN jsonb_build_object(
    'success', true,
    'newSaldo', v_new_saldo,
    'saldoCurrency', v_saldo_cur,
    'settlementProfit', v_settlement_profit,
    'settlementProfitCurrency', v_cash_cur
  );
END;
$fn$;

-- ────────────────────────────────────────────────────────────
-- attach_transfer_to_partner: откат дебета + guard на выдачу (F1)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.attach_transfer_to_partner(
  p_transfer_id uuid,
  p_counterparty_id uuid,
  p_payout_method text DEFAULT 'cash'::text,
  p_buy_rate double precision DEFAULT NULL::double precision,
  p_sell_rate double precision DEFAULT NULL::double precision,
  p_base_currency text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_cp counterparties%ROWTYPE;
  v_new_spread double precision;
  v_owes_amount double precision;
  v_owes_currency text;
  v_already_attached boolean := false;
  v_offset double precision;
  v_offset_outstanding double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text, assigned_branch_ids INTO v_role, v_assigned FROM public.users WHERE id = v_uid;
  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  SELECT * INTO v_cp FROM counterparties WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Партнёр архивирован'; END IF;

  -- F1 guard: нельзя привязать к партнёру перевод, по которому уже была выдача
  -- из нашей кассы (иначе двойная выплата: и мы, и партнёр).
  IF COALESCE(v_t.issued_amount, 0) > 0
     OR EXISTS (SELECT 1 FROM transfer_issuances WHERE transfer_id = p_transfer_id) THEN
    RAISE EXCEPTION 'Нельзя привязать к партнёру перевод с выдачей. Сначала отмените выдачу.';
  END IF;

  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно прикреплять только переводы из своего филиала';
    END IF;
    IF v_cp.home_branch_id IS NOT NULL AND v_cp.home_branch_id <> v_t.from_branch_id THEN
      RAISE EXCEPTION 'Партнёр привязан к другому филиалу. Только Creator/Director может прикреплять через него.';
    END IF;
  END IF;

  IF v_t.via_counterparty_id IS NOT NULL THEN
    IF v_t.via_counterparty_id <> p_counterparty_id THEN
      RAISE EXCEPTION 'Перевод уже привязан к другому партнёру. Сначала detach.';
    END IF;
    v_already_attached := true;
  END IF;

  IF p_buy_rate IS NOT NULL AND p_sell_rate IS NOT NULL THEN
    IF p_buy_rate <= 0 OR p_sell_rate <= 0 THEN RAISE EXCEPTION 'Курсы должны быть > 0'; END IF;
    IF p_base_currency IS NULL OR length(trim(p_base_currency)) = 0 THEN
      RAISE EXCEPTION 'Для дилерской модели нужна base_currency';
    END IF;
    IF trim(p_base_currency) = v_t.currency THEN v_new_spread := 0;
    ELSE v_new_spread := private.calc_spread_profit(v_t.amount, p_buy_rate, p_sell_rate);
    END IF;
  END IF;

  UPDATE transfers SET
    via_counterparty_id = p_counterparty_id,
    buy_rate       = COALESCE(p_buy_rate, buy_rate),
    sell_rate      = COALESCE(p_sell_rate, sell_rate),
    base_currency  = COALESCE(NULLIF(trim(p_base_currency), ''), base_currency),
    spread_profit  = COALESCE(v_new_spread, spread_profit),
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(jsonb_build_object(
        'at', now(), 'userId', v_uid::text, 'kind', 'attach_to_partner',
        'changes', jsonb_build_object(
          'counterparty_id', p_counterparty_id::text,
          'partner_name', v_cp.name,
          'buy_rate', p_buy_rate, 'sell_rate', p_sell_rate,
          'base_currency', p_base_currency, 'spread_profit', v_new_spread,
          'status_at_attach', v_t.status::text)))
  WHERE id = p_transfer_id;

  IF v_already_attached THEN
    RETURN jsonb_build_object('success', true, 'reattached', true, 'newSpread', v_new_spread);
  END IF;

  -- ── F1: откат дебета счёта-источника ──
  -- Оплату теперь покрывает партнёр -> возвращаем на счёт деньги,
  -- списанные при оформлении (amount + комиссия в режиме fromSender).
  -- Реальный отток произойдёт только при расчёте с партнёром (settle_from_us).
  v_offset := round((v_t.amount
    + CASE WHEN v_t.commission_mode = 'fromSender' THEN COALESCE(v_t.commission, 0) ELSE 0 END
    )::numeric, 4);

  SELECT COALESCE(SUM(CASE WHEN type = 'credit' THEN amount ELSE -amount END), 0)
    INTO v_offset_outstanding
    FROM ledger_entries
    WHERE reference_type = 'partner_offset' AND reference_id = p_transfer_id::text;

  IF v_offset > 0 AND v_offset_outstanding = 0 AND v_t.from_account_id IS NOT NULL THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_t.from_account_id, v_t.from_branch_id, v_offset, v_t.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = round((account_balances.balance + v_offset)::numeric, 4),
          updated_at = now();

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES
      (v_t.from_branch_id, v_t.from_account_id, 'credit', v_offset, v_t.currency,
       'partner_offset', p_transfer_id::text, v_t.transaction_code,
       'Привязка к партнёру: оплату покрывает партнёр (откат дебета)', v_uid);
  END IF;

  -- saldo всегда в валюте перевода
  v_owes_amount := v_t.amount;
  v_owes_currency := v_t.currency;

  PERFORM private.record_counterparty_op(
    p_counterparty_id := p_counterparty_id,
    p_kind            := 'paid_for_us',
    p_amount          := v_owes_amount,
    p_currency        := v_owes_currency,
    p_description     := 'Прикреплено: ' || COALESCE(v_t.transaction_code, p_transfer_id::text)
                         || COALESCE(' получатель ' || v_t.receiver_name, '')
                         || ' (статус: ' || v_t.status || ')',
    p_cash_account_id := NULL,
    p_transfer_id     := p_transfer_id,
    p_payout_method   := COALESCE(NULLIF(trim(p_payout_method), ''), 'cash'),
    p_exchange_rate   := p_buy_rate);

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'counterpartyId', p_counterparty_id::text,
    'partnerName', v_cp.name,
    'owesAmount', v_owes_amount,
    'owesCurrency', v_owes_currency,
    'spreadProfit', COALESCE(v_new_spread, 0));
END;
$fn$;

-- ────────────────────────────────────────────────────────────
-- detach_transfer_from_partner: пере-дебет (F1) + round saldo (F2)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.detach_transfer_from_partner(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_op_amount double precision;
  v_op_currency text;
  v_curr_saldo double precision;
  v_offset_outstanding double precision;
  v_acc_balance double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text, assigned_branch_ids INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  IF v_t.via_counterparty_id IS NULL THEN
    RAISE EXCEPTION 'Перевод не привязан к партнёру';
  END IF;

  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Чужой филиал';
    END IF;
  END IF;

  -- Возврат saldo (F2: round перед записью в JSONB)
  FOR v_op_amount, v_op_currency IN
    SELECT amount, currency FROM counterparty_transactions
     WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us'
  LOOP
    v_curr_saldo := round(COALESCE(
      ((SELECT saldo_by_currency->>v_op_currency
          FROM counterparties WHERE id = v_t.via_counterparty_id)::double precision),
      0)::numeric, 4);
    UPDATE counterparties
       SET saldo_by_currency = saldo_by_currency
           || jsonb_build_object(v_op_currency, round((v_curr_saldo + v_op_amount)::numeric, 4))
     WHERE id = v_t.via_counterparty_id;
  END LOOP;

  DELETE FROM counterparty_transactions
   WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us';

  -- ── F1: снова «платим мы» -> пере-дебетуем счёт-источник на сумму отката ──
  SELECT COALESCE(SUM(CASE WHEN type = 'credit' THEN amount ELSE -amount END), 0)
    INTO v_offset_outstanding
    FROM ledger_entries
    WHERE reference_type = 'partner_offset' AND reference_id = p_transfer_id::text;

  IF v_offset_outstanding > 0 AND v_t.from_account_id IS NOT NULL THEN
    SELECT balance INTO v_acc_balance
      FROM account_balances WHERE account_id = v_t.from_account_id FOR UPDATE;
    v_acc_balance := COALESCE(v_acc_balance, 0);
    IF v_acc_balance < v_offset_outstanding THEN
      RAISE EXCEPTION
        'Недостаточно средств для возврата перевода на свой счёт. Доступно: %, требуется: %',
        round(v_acc_balance::numeric, 2), round(v_offset_outstanding::numeric, 2);
    END IF;

    UPDATE account_balances
       SET balance = round((balance - v_offset_outstanding)::numeric, 4),
           updated_at = now()
     WHERE account_id = v_t.from_account_id;

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES
      (v_t.from_branch_id, v_t.from_account_id, 'debit', v_offset_outstanding, v_t.currency,
       'partner_offset', p_transfer_id::text, v_t.transaction_code,
       'Отвязка от партнёра: оплату снова покрываем мы', v_uid);
  END IF;

  UPDATE transfers SET
    via_counterparty_id = NULL,
    spread_profit = NULL,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at', now(),
          'userId', v_uid::text,
          'kind', 'detach_from_partner',
          'changes', jsonb_build_object(
            'status_at_detach', v_t.status::text
          )
        ))
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true);
END;
$fn$;

-- ────────────────────────────────────────────────────────────
-- issue_transfer_partial: зеркальный guard (F1)
-- нельзя выдавать из своей кассы перевод, привязанный к партнёру
-- (платит партнёр). Тело функции без изменений, только guard.
-- ────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────
-- create_partner_transfer (all-in-one): больше не дебетует кассу
-- на тело перевода — оплату покрывает партнёр (saldo). Комиссия
-- (fromAccount) по-прежнему учитывается как доход. (F1)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.create_partner_transfer(
  p_from_branch_id uuid,
  p_from_account_id uuid,
  p_counterparty_id uuid,
  p_amount double precision,
  p_currency text DEFAULT 'USD'::text,
  p_payout_method text DEFAULT 'cash'::text,
  p_commission_type text DEFAULT 'fixed'::text,
  p_commission_value double precision DEFAULT 0,
  p_commission_currency text DEFAULT NULL::text,
  p_commission_mode text DEFAULT 'fromTransfer'::text,
  p_commission_account_id uuid DEFAULT NULL::uuid,
  p_idempotency_key text DEFAULT ''::text,
  p_description text DEFAULT NULL::text,
  p_client_id text DEFAULT NULL::text,
  p_sender_name text DEFAULT NULL::text,
  p_sender_phone text DEFAULT NULL::text,
  p_sender_info text DEFAULT NULL::text,
  p_receiver_name text DEFAULT NULL::text,
  p_receiver_phone text DEFAULT NULL::text,
  p_receiver_info text DEFAULT NULL::text,
  p_to_currency text DEFAULT NULL::text,
  p_exchange_rate double precision DEFAULT 1,
  p_buy_rate double precision DEFAULT NULL::double precision,
  p_sell_rate double precision DEFAULT NULL::double precision,
  p_base_currency text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_cp counterparties%ROWTYPE;
  v_acc_branch uuid;
  v_commission double precision := 0;
  v_code text;
  v_transfer_id uuid;
  v_comm_acc_currency text;
  v_comm_acc_branch uuid;
  v_payout_method text;
  v_to_currency text;
  v_rate double precision;
  v_converted double precision;
  v_buy double precision;
  v_sell double precision;
  v_base_cur text;
  v_spread double precision;
  v_partner_owes_amount double precision;
  v_partner_owes_currency text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_user_id;

  SELECT * INTO v_cp FROM counterparties WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN
    RAISE EXCEPTION 'Партнёр архивирован — операции запрещены. Разархивируйте его, чтобы продолжить.';
  END IF;

  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL OR NOT (p_from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно создавать переводы только из своего филиала';
    END IF;
    IF v_cp.home_branch_id IS NOT NULL
       AND v_cp.home_branch_id <> p_from_branch_id THEN
      RAISE EXCEPTION 'Партнёр привязан к другому филиалу. Только Creator/Director может создавать перевод через этого партнёра.';
    END IF;
  END IF;

  v_payout_method := COALESCE(NULLIF(trim(p_payout_method), ''), 'cash');
  IF v_payout_method NOT IN ('cash', 'card', 'transfer', 'other') THEN
    RAISE EXCEPTION 'Неизвестный способ выплаты: %', v_payout_method;
  END IF;

  v_to_currency := COALESCE(NULLIF(trim(p_to_currency), ''), p_currency);
  v_rate := COALESCE(p_exchange_rate, 1);
  IF v_rate <= 0 THEN
    RAISE EXCEPTION 'Курс обмена должен быть больше нуля (получен: %)', v_rate;
  END IF;
  IF v_to_currency = p_currency AND v_rate <> 1 THEN
    v_rate := 1;
  END IF;

  v_buy := p_buy_rate;
  v_sell := p_sell_rate;
  v_base_cur := COALESCE(NULLIF(trim(p_base_currency), ''), p_currency);

  IF v_buy IS NOT NULL OR v_sell IS NOT NULL THEN
    IF v_buy IS NULL OR v_sell IS NULL THEN
      RAISE EXCEPTION 'buy_rate и sell_rate должны быть указаны вместе';
    END IF;
    IF v_buy <= 0 OR v_sell <= 0 THEN
      RAISE EXCEPTION 'Курсы должны быть больше нуля';
    END IF;
    IF v_base_cur IS NULL OR length(trim(v_base_cur)) = 0 THEN
      RAISE EXCEPTION 'Для дилерской модели нужна base_currency';
    END IF;
    IF v_base_cur = p_currency THEN
      v_spread := 0;
    ELSE
      v_spread := private.calc_spread_profit(p_amount, v_buy, v_sell);
    END IF;
  ELSE
    v_spread := 0;
  END IF;

  SELECT branch_id INTO v_acc_branch
    FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Счёт-источник не найден'; END IF;
  IF v_acc_branch <> p_from_branch_id THEN
    RAISE EXCEPTION 'Счёт-источник не относится к указанному филиалу';
  END IF;

  -- Комиссия. Тело перевода кассу НЕ дебетует (платит партнёр).
  IF p_commission_mode = 'fromAccount' THEN
    IF p_commission_account_id IS NULL THEN
      RAISE EXCEPTION 'Для режима «комиссия на отдельный счёт» обязательно указание счёта';
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
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value, v_comm_acc_currency,
      p_amount, v_comm_acc_currency);
  ELSE
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value,
      COALESCE(NULLIF(p_commission_currency, ''), p_currency),
      p_amount, p_currency);
  END IF;

  v_code := private.next_transaction_code('PTN', 'transactionCodes');
  v_transfer_id := gen_random_uuid();
  v_converted := p_amount * v_rate;

  v_partner_owes_amount := p_amount;
  v_partner_owes_currency := p_currency;

  BEGIN
    INSERT INTO transfers (
      id, transaction_code,
      from_branch_id, to_branch_id,
      from_account_id, to_account_id,
      amount, currency, to_currency, exchange_rate, converted_amount,
      commission,
      commission_currency, commission_type, commission_value, commission_mode,
      commission_account_id,
      description, client_id,
      sender_name, sender_phone, sender_info,
      receiver_name, receiver_phone, receiver_info,
      status, created_by, idempotency_key,
      via_counterparty_id, issued_by, issued_at,
      buy_rate, sell_rate, base_currency, spread_profit,
      created_at
    ) VALUES (
      v_transfer_id, v_code,
      p_from_branch_id, p_from_branch_id,
      p_from_account_id, '',
      p_amount, p_currency, v_to_currency, v_rate, v_converted,
      v_commission,
      CASE WHEN p_commission_mode = 'fromAccount' THEN v_comm_acc_currency
           ELSE COALESCE(NULLIF(p_commission_currency, ''), p_currency) END,
      p_commission_type, p_commission_value, p_commission_mode,
      CASE WHEN p_commission_mode = 'fromAccount'
           THEN p_commission_account_id ELSE NULL END,
      p_description, p_client_id,
      p_sender_name, p_sender_phone, p_sender_info,
      p_receiver_name, p_receiver_phone, p_receiver_info,
      'delivered', v_user_id, p_idempotency_key,
      p_counterparty_id, v_user_id, now(),
      v_buy, v_sell, v_base_cur, v_spread,
      now());
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate partner transfer';
  END;

  -- Комиссия как доход на отдельный счёт (fromAccount) — это НАШ доход,
  -- независимо от того, что выплату делает партнёр.
  IF p_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_commission_account_id, p_from_branch_id, v_commission,
            v_comm_acc_currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = round((account_balances.balance + v_commission)::numeric, 4),
          updated_at = now();

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES (
      p_from_branch_id, p_commission_account_id, 'credit', v_commission,
      v_comm_acc_currency, 'commission', v_transfer_id::text, v_code,
      'Доход: комиссия по партнёрскому переводу ' || v_code, v_user_id);
  END IF;

  IF v_commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (
      v_transfer_id, p_from_branch_id, v_commission,
      CASE WHEN p_commission_mode = 'fromAccount' THEN v_comm_acc_currency
           ELSE COALESCE(NULLIF(p_commission_currency, ''), p_currency) END,
      COALESCE(p_commission_type, 'fixed'), now());
  END IF;

  PERFORM private.record_counterparty_op(
    p_counterparty_id := p_counterparty_id,
    p_kind            := 'paid_for_us',
    p_amount          := v_partner_owes_amount,
    p_currency        := v_partner_owes_currency,
    p_description     := 'Выплата по переводу ' || v_code
                          || COALESCE(' получателю ' || p_receiver_name, ''),
    p_cash_account_id := NULL,
    p_transfer_id     := v_transfer_id,
    p_payout_method   := v_payout_method,
    p_exchange_rate   := CASE WHEN v_buy IS NULL THEN NULL ELSE v_buy END);

  RETURN jsonb_build_object(
    'success', true,
    'transferId', v_transfer_id::text,
    'transactionCode', v_code,
    'partnerId', p_counterparty_id::text,
    'convertedAmount', v_converted,
    'toCurrency', v_to_currency,
    'spreadProfit', v_spread,
    'spreadProfitCurrency', p_currency,
    'baseAmount', v_partner_owes_amount,
    'baseCurrency', v_partner_owes_currency);
END;
$fn$;

COMMIT;
