-- ============================================================
-- 042: relax status check for attach_transfer_to_partner
-- ============================================================
-- В 041 бухгалтеру разрешали прикреплять только status='created'.
-- Это бессмысленно: attach НЕ двигает балансы и ledger — только
-- via_counterparty_id + saldo партнёра + counterparty_transactions.
-- Если бухгалтер сам создал и confirm-нул перевод (toDelivery), он
-- по-прежнему должен иметь право пометить его как партнёрский.
--
-- Новая логика прав:
--   • creator/director — всегда
--   • accountant       — любой статус, но только из своего филиала
--   • cancelled/rejected статусов нет (миграция 022) → не учитываем
--
-- Detach аналогично — accountant может откатить из любого статуса
-- своего филиала.
--
-- Идемпотентно — CREATE OR REPLACE.
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

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN
    RAISE EXCEPTION 'Партнёр архивирован';
  END IF;

  -- ── Права (relaxed): accountant — только свой филиал, статус любой
  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно прикреплять только переводы из своего филиала';
    END IF;
  END IF;

  IF v_t.via_counterparty_id IS NOT NULL THEN
    IF v_t.via_counterparty_id <> p_counterparty_id THEN
      RAISE EXCEPTION 'Перевод уже привязан к другому партнёру. Сначала detach.';
    END IF;
    v_already_attached := true;
  END IF;

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

  -- Saldo в base-валюте если есть buy_rate + cross-currency, иначе в currency.
  IF p_buy_rate IS NOT NULL AND p_buy_rate > 0
     AND p_base_currency IS NOT NULL
     AND trim(p_base_currency) <> v_t.currency THEN
    v_owes_amount := v_t.amount / p_buy_rate;
    v_owes_currency := upper(trim(p_base_currency));
  ELSE
    v_owes_amount := v_t.amount;
    v_owes_currency := v_t.currency;
  END IF;

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
    p_exchange_rate   := p_buy_rate
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


-- ─── Detach: тоже снимаем status-ограничение ─────────────────
CREATE OR REPLACE FUNCTION private.detach_transfer_from_partner(
  p_transfer_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_op_amount double precision;
  v_op_currency text;
  v_curr_saldo double precision;
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

  FOR v_op_amount, v_op_currency IN
    SELECT amount, currency FROM counterparty_transactions
     WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us'
  LOOP
    v_curr_saldo := COALESCE(
      ((SELECT saldo_by_currency->>v_op_currency
          FROM counterparties WHERE id = v_t.via_counterparty_id)::double precision),
      0);
    UPDATE counterparties
       SET saldo_by_currency = saldo_by_currency
           || jsonb_build_object(v_op_currency, v_curr_saldo + v_op_amount)
     WHERE id = v_t.via_counterparty_id;
  END LOOP;

  DELETE FROM counterparty_transactions
   WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us';

  UPDATE transfers SET
    via_counterparty_id = NULL,
    spread_profit = NULL,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at', now(),
          'userId', v_uid::text,
          'kind', 'detach_from_partner'
        ))
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMIT;
