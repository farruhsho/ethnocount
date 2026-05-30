-- ============================================================
-- 047: partner saldo always in transfer's own currency
-- ============================================================
-- В 041/042 при дилерской модели (buy_rate + base_currency != transfer
-- currency) saldo партнёра обновлялось в base_currency — `v_t.amount /
-- p_buy_rate` единиц base. Это сворачивало RUB / UZS / USD-переводы
-- в одну «USD-кучу» saldo (если base всегда USD), и операторы видели
-- «без разницы какой валютой я платил — всё уходит в одно сальдо».
--
-- Новая семантика (модель B — per-currency tracking):
--   • saldo всегда в валюте перевода (v_t.currency)
--   • spread_profit (курсовая прибыль дилер-режима) — отдельное поле
--     на transfers, остаётся как было
--   • partner-settle делается в той же валюте, в которой проходил
--     перевод; cross-currency расчёт партнёра — через RecordOpDialog
--     с `p_close_currency` (миграция 040, уже работает).
--
-- Detach зеркально откатывает saldo по валютам, которые реально
-- были записаны в counterparty_transactions, — поэтому он не требует
-- изменений.
--
-- Идемпотентно. CREATE OR REPLACE.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.attach_transfer_to_partner(
  p_transfer_id      uuid,
  p_counterparty_id  uuid,
  p_payout_method    text DEFAULT 'cash',
  p_buy_rate         double precision DEFAULT NULL,
  p_sell_rate        double precision DEFAULT NULL,
  p_base_currency    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
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
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  SELECT * INTO v_cp FROM counterparties WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Партнёр архивирован'; END IF;

  -- ── Права (accountant — только свой филиал) ─────────────
  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно прикреплять только переводы из своего филиала';
    END IF;
    -- home_branch_id check (миграция 046)
    IF v_cp.home_branch_id IS NOT NULL
       AND v_cp.home_branch_id <> v_t.from_branch_id THEN
      RAISE EXCEPTION 'Партнёр привязан к другому филиалу. Только Creator/Director может прикреплять через него.';
    END IF;
  END IF;

  IF v_t.via_counterparty_id IS NOT NULL THEN
    IF v_t.via_counterparty_id <> p_counterparty_id THEN
      RAISE EXCEPTION 'Перевод уже привязан к другому партнёру. Сначала detach.';
    END IF;
    v_already_attached := true;
  END IF;

  -- ── Spread (курсовая прибыль) считаем как было ──────────
  IF p_buy_rate IS NOT NULL AND p_sell_rate IS NOT NULL THEN
    IF p_buy_rate <= 0 OR p_sell_rate <= 0 THEN
      RAISE EXCEPTION 'Курсы должны быть > 0';
    END IF;
    IF p_base_currency IS NULL OR length(trim(p_base_currency)) = 0 THEN
      RAISE EXCEPTION 'Для дилерской модели нужна base_currency';
    END IF;
    IF trim(p_base_currency) = v_t.currency THEN
      v_new_spread := 0;
    ELSE
      v_new_spread := private.calc_spread_profit(
        v_t.amount, p_buy_rate, p_sell_rate);
    END IF;
  END IF;

  UPDATE transfers SET
    via_counterparty_id = p_counterparty_id,
    buy_rate       = COALESCE(p_buy_rate, buy_rate),
    sell_rate      = COALESCE(p_sell_rate, sell_rate),
    base_currency  = COALESCE(NULLIF(trim(p_base_currency), ''), base_currency),
    spread_profit  = COALESCE(v_new_spread, spread_profit),
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at',     now(),
          'userId', v_uid::text,
          'kind',   'attach_to_partner',
          'changes', jsonb_build_object(
            'counterparty_id', p_counterparty_id::text,
            'partner_name',    v_cp.name,
            'buy_rate',        p_buy_rate,
            'sell_rate',       p_sell_rate,
            'base_currency',   p_base_currency,
            'spread_profit',   v_new_spread,
            'status_at_attach', v_t.status::text
          )
        )
      )
  WHERE id = p_transfer_id;

  IF v_already_attached THEN
    RETURN jsonb_build_object(
      'success', true,
      'reattached', true,
      'newSpread', v_new_spread
    );
  END IF;

  -- ── KEY CHANGE: saldo всегда в валюте перевода ─────────
  -- Раньше при buy_rate + cross-currency base saldo шёл в base
  -- (1M RUB → 10870 USD). Теперь всегда v_t.amount в v_t.currency.
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
    p_exchange_rate   := p_buy_rate  -- сохраняем для отчётности, но не используем для saldo
  );

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'counterpartyId', p_counterparty_id::text,
    'partnerName', v_cp.name,
    'owesAmount', v_owes_amount,
    'owesCurrency', v_owes_currency,
    'spreadProfit', COALESCE(v_new_spread, 0)
  );
END;
$$;

-- ─── create_partner_transfer: тот же фикс (saldo в валюте перевода) ──
-- В 036 функция тоже сворачивала saldo в base_currency при дилер-режиме.
-- Перезаписываем с идентичной сигнатурой; меняется ТОЛЬКО блок выбора
-- v_partner_owes_currency (теперь всегда p_currency).
CREATE OR REPLACE FUNCTION private.create_partner_transfer(
  p_from_branch_id        uuid,
  p_from_account_id       uuid,
  p_counterparty_id       uuid,
  p_amount                double precision,
  p_currency              text DEFAULT 'USD',
  p_payout_method         text DEFAULT 'cash',
  p_commission_type       text DEFAULT 'fixed',
  p_commission_value      double precision DEFAULT 0,
  p_commission_currency   text DEFAULT NULL,
  p_commission_mode       text DEFAULT 'fromTransfer',
  p_commission_account_id uuid DEFAULT NULL,
  p_idempotency_key       text DEFAULT '',
  p_description           text DEFAULT NULL,
  p_client_id             text DEFAULT NULL,
  p_sender_name           text DEFAULT NULL,
  p_sender_phone          text DEFAULT NULL,
  p_sender_info           text DEFAULT NULL,
  p_receiver_name         text DEFAULT NULL,
  p_receiver_phone        text DEFAULT NULL,
  p_receiver_info         text DEFAULT NULL,
  p_to_currency           text DEFAULT NULL,
  p_exchange_rate         double precision DEFAULT 1,
  p_buy_rate              double precision DEFAULT NULL,
  p_sell_rate             double precision DEFAULT NULL,
  p_base_currency         text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_cp counterparties%ROWTYPE;
  v_acc_branch uuid;
  v_commission double precision := 0;
  v_total_debit double precision;
  v_balance double precision;
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

  SELECT * INTO v_cp FROM counterparties WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN
    RAISE EXCEPTION 'Партнёр архивирован — операции запрещены. Разархивируйте его, чтобы продолжить.';
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
    v_total_debit := p_amount;
  ELSE
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value,
      COALESCE(NULLIF(p_commission_currency, ''), p_currency),
      p_amount, p_currency);
    IF p_commission_mode = 'fromSender' THEN
      v_total_debit := p_amount + v_commission;
    ELSE
      v_total_debit := p_amount;
    END IF;
  END IF;

  SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  IF v_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
      round(v_balance::numeric, 2), round(v_total_debit::numeric, 2);
  END IF;

  v_code := private.next_transaction_code('PTN', 'transactionCodes');
  v_transfer_id := gen_random_uuid();
  v_converted := p_amount * v_rate;

  -- ── KEY CHANGE: saldo всегда в валюте перевода ─────────
  -- Было: при buy_rate + cross-currency base saldo шёл в base
  -- (1M RUB → 10870 USD), все валюты сворачивались в base.
  -- Стало: saldo per-currency — каждая валюта учитывается отдельно.
  -- Spread (дилер-прибыль) по-прежнему хранится в transfers.spread_profit.
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

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (p_from_account_id, p_from_branch_id, -v_total_debit, p_currency, now())
  ON CONFLICT (account_id) DO UPDATE
    SET balance = account_balances.balance - v_total_debit, updated_at = now();

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency,
     reference_type, reference_id, transaction_code, description, created_by)
  VALUES (
    p_from_branch_id, p_from_account_id, 'debit', v_total_debit, p_currency,
    'transfer', v_transfer_id::text, v_code,
    'Партнёрский перевод ' || v_code || ' через ' || v_cp.name, v_user_id);

  IF p_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_commission_account_id, p_from_branch_id, v_commission,
            v_comm_acc_currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance + v_commission, updated_at = now();

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
$$;

COMMIT;
