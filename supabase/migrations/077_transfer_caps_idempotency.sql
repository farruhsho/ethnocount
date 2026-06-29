-- ============================================================
-- 077: amount sanity-caps + safe idempotency на create_transfer
-- ============================================================
-- Закрывает два пункта форензик-аудита для create_transfer:
--
--   (#16) Sanity-caps на сумму/комиссию.
--         053 добавил защиту от мусорного ввода (NaN, scientific
--         notation вида 1e+61) для КЛИЕНТСКИХ операций
--         (client_transactions.amount: 0 < amount <= 1e12, не NaN).
--         create_transfer такой защиты не имел — проверял только
--         `p_amount <= 0`. Поэтому amount=1e+61 / NaN / Infinity
--         проходили в transfers, ломали баланс и UI (см. шапку 053).
--         Здесь зеркалим тот же диапазон (0 < x <= 1e12, не NaN/Inf)
--         для p_amount и p_commission_value. Потолок 1 трлн выбран
--         эмпирически тем же мотивом, что и в 053 (~3 порядка запаса).
--
--   (#18) Идемпотентный ретрай больше не падает.
--         При коллизии uniq_transfers_idempotency (006) функция
--         раньше делала RAISE 'Duplicate transfer — already exists'.
--         Повторная отправка той же формы (двойной тап, ретрай сети)
--         получала ошибку вместо исходного перевода. Теперь на
--         unique_violation мы НЕ списываем повторно деньги, а находим
--         уже созданный перевод по idempotency_key и возвращаем тот же
--         payload, что и при успешном создании
--         (`{success:true, transferId:…}`) с флагом `duplicate:true`.
--
-- Тело воспроизведено из 044 без изменений логики, кроме блока
-- валидации сумм (после auth-check) и обработчика unique_violation.
-- Сигнатура private.create_transfer та же → публичная обёртка и
-- GRANT из 044 сохраняются (CREATE OR REPLACE). Идемпотентно.
-- ============================================================

BEGIN;

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
  p_commission_mode text DEFAULT 'fromTransfer',
  p_idempotency_key text DEFAULT '',
  p_description text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_sender_phone text DEFAULT NULL,
  p_sender_info text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL,
  p_receiver_phone text DEFAULT NULL,
  p_receiver_info text DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL,
  p_buy_rate double precision DEFAULT NULL,
  p_sell_rate double precision DEFAULT NULL,
  p_base_currency text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_commission double precision;
  v_total_debit double precision;
  v_from_balance double precision;
  v_acc_branch uuid;
  v_code text;
  v_transfer_id uuid;
  v_resolved_to_cur text;
  v_receiver_amount double precision;
  v_converted double precision;
  v_comm_acc_branch uuid;
  v_comm_acc_currency text;
  v_comm_charge double precision;
  v_spread double precision := 0;
  v_base_cur text;
  v_existing transfers%ROWTYPE;   -- 077: для безопасного идемпотентного ретрая
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  -- ── 077 (#16) sanity-caps: зеркало 053 для amount и commission ──
  -- Отсекаем NaN/Infinity (через `x = x` и finite-проверку),
  -- неположительную сумму и абсурдно большой ввод (>1 трлн).
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;
  IF NOT (p_amount = p_amount) THEN
    RAISE EXCEPTION 'Сумма не является числом (NaN)';
  END IF;
  IF p_amount = 'Infinity'::double precision OR p_amount = '-Infinity'::double precision THEN
    RAISE EXCEPTION 'Сумма не является конечным числом';
  END IF;
  IF p_amount > 1e12 THEN
    RAISE EXCEPTION 'Слишком большая сумма (%). Максимум: 1 000 000 000 000.', p_amount;
  END IF;

  -- Комиссия: может быть 0 (валидно), но не отрицательной/NaN/Inf/>1 трлн.
  IF p_commission_value IS NOT NULL THEN
    IF NOT (p_commission_value = p_commission_value) THEN
      RAISE EXCEPTION 'Комиссия не является числом (NaN)';
    END IF;
    IF p_commission_value = 'Infinity'::double precision
       OR p_commission_value = '-Infinity'::double precision THEN
      RAISE EXCEPTION 'Комиссия не является конечным числом';
    END IF;
    IF p_commission_value < 0 THEN
      RAISE EXCEPTION 'Комиссия не может быть отрицательной';
    END IF;
    IF p_commission_value > 1e12 THEN
      RAISE EXCEPTION 'Слишком большая комиссия (%). Максимум: 1 000 000 000 000.', p_commission_value;
    END IF;
  END IF;

  SELECT branch_id INTO v_acc_branch
    FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Source account not found'; END IF;
  IF v_acc_branch <> p_from_branch_id THEN
    RAISE EXCEPTION 'Source account does not belong to source branch';
  END IF;

  v_base_cur := COALESCE(NULLIF(trim(p_base_currency), ''), p_currency);
  IF p_buy_rate IS NOT NULL OR p_sell_rate IS NOT NULL THEN
    IF p_buy_rate IS NULL OR p_sell_rate IS NULL THEN
      RAISE EXCEPTION 'buy_rate и sell_rate должны быть указаны вместе';
    END IF;
    IF p_buy_rate <= 0 OR p_sell_rate <= 0 THEN
      RAISE EXCEPTION 'Курсы должны быть > 0';
    END IF;
    IF v_base_cur = p_currency THEN
      v_spread := 0;
    ELSE
      v_spread := private.calc_spread_profit(p_amount, p_buy_rate, p_sell_rate);
    END IF;
  END IF;

  IF p_commission_mode = 'fromAccount' THEN
    IF p_commission_account_id IS NULL THEN
      RAISE EXCEPTION 'Для режима «комиссия на отдельный счёт» обязательно указание счёта';
    END IF;
    SELECT branch_id, currency
      INTO v_comm_acc_branch, v_comm_acc_currency
      FROM branch_accounts WHERE id = p_commission_account_id;
    IF v_comm_acc_branch IS NULL THEN RAISE EXCEPTION 'Счёт комиссии не найден'; END IF;
    IF v_comm_acc_branch <> p_from_branch_id THEN
      RAISE EXCEPTION 'Счёт комиссии должен принадлежать филиалу-отправителю';
    END IF;
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value, v_comm_acc_currency,
      p_amount, v_comm_acc_currency);
    v_comm_charge := v_commission;
    v_total_debit := p_amount;
  ELSE
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value, p_commission_currency,
      p_amount, p_currency);
    v_comm_charge := 0;
    IF p_commission_mode = 'fromSender' THEN
      v_total_debit := p_amount + v_commission;
    ELSE
      v_total_debit := p_amount;
    END IF;
  END IF;

  SELECT balance INTO v_from_balance
    FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  IF v_from_balance IS NULL THEN v_from_balance := 0; END IF;
  IF v_from_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
      round(v_from_balance::numeric, 2), round(v_total_debit::numeric, 2);
  END IF;

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
      status, created_by, idempotency_key,
      buy_rate, sell_rate, base_currency, spread_profit,
      created_at
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
      'created', v_user_id, p_idempotency_key,
      p_buy_rate, p_sell_rate,
      CASE WHEN p_buy_rate IS NOT NULL THEN v_base_cur ELSE NULL END,
      CASE WHEN p_buy_rate IS NOT NULL THEN v_spread ELSE NULL END,
      now());
  EXCEPTION WHEN unique_violation THEN
    -- 077 (#18): коллизия idempotency_key = повтор той же отправки.
    -- НЕ списываем деньги повторно (мы внутри суб-блока, INSERT
    -- баланса/леджера ещё не выполнялись) — возвращаем исходный
    -- перевод с тем же payload, что и при успехе.
    SELECT * INTO v_existing
      FROM transfers
      WHERE idempotency_key = p_idempotency_key
        AND p_idempotency_key IS NOT NULL
        AND p_idempotency_key <> ''
      LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'transferId', v_existing.id::text,
        'duplicate', true);
    END IF;
    -- Конфликт без находимого ключа (теоретически невозможно при
    -- партиальном uniq-индексе) — сохраняем прежнее поведение.
    RAISE EXCEPTION 'Duplicate transfer — already exists';
  END;

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

  IF p_commission_mode = 'fromAccount' AND v_comm_charge > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_commission_account_id, p_from_branch_id, v_comm_charge, v_comm_acc_currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance + v_comm_charge, updated_at = now();
    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, transaction_code, description, created_by)
    VALUES
      (p_from_branch_id, p_commission_account_id, 'credit', v_comm_charge,
       v_comm_acc_currency, 'commission', v_transfer_id::text, v_code,
       'Доход: комиссия по переводу ' || v_code, v_user_id);
  END IF;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES (
    p_to_branch_id::text,
    'incoming_transfer',
    'Новый перевод ' || v_code,
    'Входящий: ' || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || p_currency,
    jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code));

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;

COMMIT;
