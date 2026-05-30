-- ============================================================
-- 032: Commission "fromAccount" is INCOME (credit), not expense (debit)
-- ============================================================
-- Изменение бизнес-логики по запросу:
--   • Режим «Комиссия с другого счёта» (CommissionMode.fromAccount)
--     теперь означает: «комиссия — ДОХОД на этот счёт».
--     То есть commission_account_id — это касса/счёт, КУДА мы кладём
--     заработанную комиссию. Раньше с него СПИСЫВАЛИ, что было неинтуитивно
--     («зачем мне отдельный счёт, чтобы платить с него комиссию?»).
--
-- Что изменилось vs 027 / 030:
--   • в create_transfer: при fromAccount commission_account_id теперь
--     CREDIT (balance + commission), ledger_entries type='credit',
--     reference_type='commission'. Проверка баланса этого счёта удалена
--     (мы кладём ДЕНЬГИ на него, минимум не нужен).
--   • в replace_pending_transfer: при правке pending-перевода старая
--     comm-CREDIT откатывается дебитом (balance - commission), новая
--     комиссия добавляется кредитом.
--
-- Что НЕ менялось:
--   • получатель получает p_amount * exchange_rate (без вычета комиссии).
--   • основной счёт-источник debit на p_amount (без +commission).
--   • в режиме fromTransfer всё как раньше — комиссия вычитается из
--     суммы перевода, получатель получает (amount - commission) * rate.
--   • table commissions заполняется на confirm — это история сборов,
--     не трогаем.
--
-- Также добавлены вспомогательные функции для аудита:
--   • private.commission_summary(p_branch_id, p_start, p_end)
--   • public.admin_commission_summary(...)
--
-- Идемпотентно — CREATE OR REPLACE.
-- ============================================================

BEGIN;

-- ─── 1. create_transfer: fromAccount = CREDIT commission account ─────
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

  -- ── Режим fromAccount: комиссия — ДОХОД на счёт. Не списываем.
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
      p_amount, v_comm_acc_currency
    );
    v_comm_charge := v_commission;
    v_total_debit := p_amount; -- основной счёт = только сумма перевода
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
  -- ⚠️ Для fromAccount баланс commission_account_id НЕ проверяем — мы
  --    кладём деньги на него, а не снимаем.

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
    -- fromSender / fromAccount — получатель получает полную сумму.
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

  -- ── CREDIT счёт комиссии: это ДОХОД, не расход ───────────────
  IF p_commission_mode = 'fromAccount' AND v_comm_charge > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_commission_account_id, p_from_branch_id, v_comm_charge,
            v_comm_acc_currency, now())
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
    jsonb_build_object('transferId', v_transfer_id::text, 'transactionCode', v_code)
  );

  RETURN jsonb_build_object('success', true, 'transferId', v_transfer_id::text);
END;
$$;


-- ─── 2. replace_pending_transfer: refund — это DEBIT (был credit) ───
CREATE OR REPLACE FUNCTION private.replace_pending_transfer(
  p_transfer_id        uuid,
  p_from_account_id    uuid    DEFAULT NULL,
  p_amount             double precision DEFAULT NULL,
  p_currency           text    DEFAULT NULL,
  p_to_currency        text    DEFAULT NULL,
  p_exchange_rate      double precision DEFAULT NULL,
  p_commission_type    text    DEFAULT NULL,
  p_commission_value   double precision DEFAULT NULL,
  p_commission_currency text   DEFAULT NULL,
  p_commission_mode    text    DEFAULT NULL,
  p_to_account_id      text    DEFAULT NULL,
  p_description        text    DEFAULT NULL,
  p_client_id          text    DEFAULT NULL,
  p_sender_name        text    DEFAULT NULL,
  p_sender_phone       text    DEFAULT NULL,
  p_sender_info        text    DEFAULT NULL,
  p_receiver_name      text    DEFAULT NULL,
  p_receiver_phone     text    DEFAULT NULL,
  p_receiver_info      text    DEFAULT NULL,
  p_amendment_note     text    DEFAULT NULL,
  p_commission_account_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_t         transfers%ROWTYPE;
  v_new_from  uuid;
  v_old_total double precision;
  v_amount    double precision;
  v_currency  text;
  v_commission         double precision;
  v_commission_value   double precision;
  v_commission_type    text;
  v_commission_currency text;
  v_commission_mode    text;
  v_new_total double precision;
  v_balance   double precision;
  v_to_cur    text;
  v_rate      double precision;
  v_receiver  double precision;
  v_converted double precision;
  v_code      text;
  v_to_acc_branch uuid;
  v_changes   jsonb := '{}'::jsonb;
  v_now       timestamptz := now();
  v_old_commission_acc uuid;
  v_new_commission_acc uuid;
  v_comm_acc_branch    uuid;
  v_comm_acc_currency  text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_t FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  IF v_t.status <> 'created' THEN
    RAISE EXCEPTION 'Полное редактирование возможно только для статуса «создан» (текущий: %)', v_t.status;
  END IF;

  v_amount             := COALESCE(p_amount, v_t.amount);
  v_currency           := COALESCE(NULLIF(p_currency, ''), v_t.currency);
  v_to_cur             := COALESCE(NULLIF(p_to_currency, ''), v_t.to_currency, v_currency);
  v_rate               := COALESCE(p_exchange_rate, v_t.exchange_rate);
  v_commission_type    := COALESCE(NULLIF(p_commission_type, ''), v_t.commission_type);
  v_commission_value   := COALESCE(p_commission_value, v_t.commission_value);
  v_commission_currency:= COALESCE(NULLIF(p_commission_currency, ''),
                                   NULLIF(v_t.commission_currency, ''),
                                   v_currency);
  v_commission_mode    := COALESCE(NULLIF(p_commission_mode, ''), v_t.commission_mode);
  v_new_from           := COALESCE(p_from_account_id, v_t.from_account_id);
  v_old_commission_acc := v_t.commission_account_id;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  IF v_new_from <> v_t.from_account_id THEN
    PERFORM 1 FROM branch_accounts
      WHERE id = v_new_from AND branch_id = v_t.from_branch_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Новый счёт-источник не относится к филиалу отправителя';
    END IF;
  END IF;

  IF p_to_account_id IS NOT NULL AND p_to_account_id <> '' AND p_to_account_id <> v_t.to_account_id THEN
    SELECT branch_id INTO v_to_acc_branch
      FROM branch_accounts WHERE id = p_to_account_id::uuid;
    IF v_to_acc_branch IS NULL OR v_to_acc_branch <> v_t.to_branch_id THEN
      RAISE EXCEPTION 'Счёт получателя не принадлежит филиалу получателя';
    END IF;
  END IF;

  -- Резолвим новый commission_account_id.
  IF v_commission_mode = 'fromAccount' THEN
    v_new_commission_acc := COALESCE(p_commission_account_id, v_old_commission_acc);
    IF v_new_commission_acc IS NULL THEN
      RAISE EXCEPTION 'Для режима «комиссия на отдельный счёт» обязательно указание счёта';
    END IF;
    SELECT branch_id, currency
      INTO v_comm_acc_branch, v_comm_acc_currency
      FROM branch_accounts WHERE id = v_new_commission_acc;
    IF v_comm_acc_branch IS NULL THEN
      RAISE EXCEPTION 'Счёт комиссии не найден';
    END IF;
    IF v_comm_acc_branch <> v_t.from_branch_id THEN
      RAISE EXCEPTION 'Счёт комиссии должен принадлежать филиалу-отправителю';
    END IF;
    v_commission_currency := v_comm_acc_currency;
  ELSE
    v_new_commission_acc := NULL;
  END IF;

  v_commission := private.normalize_commission(
    v_commission_type, v_commission_value, v_commission_currency,
    v_amount, v_currency
  );

  -- Old / new total debit (основной счёт).
  IF v_t.commission_mode = 'fromSender' THEN
    v_old_total := v_t.amount + v_t.commission;
  ELSE
    v_old_total := v_t.amount;
  END IF;

  IF v_commission_mode = 'fromSender' THEN
    v_new_total := v_amount + v_commission;
  ELSE
    v_new_total := v_amount;
  END IF;

  -- Refund старого debit (основной).
  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_t.from_account_id, v_t.from_branch_id, v_old_total, v_t.currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance + v_old_total,
        updated_at = v_now;

  -- ── REVERSE старой commission-CREDIT, если она была:
  --    раньше она ДОБАВИЛА деньги на счёт, теперь надо ВЫЧЕСТЬ обратно.
  IF v_t.commission_mode = 'fromAccount'
     AND v_old_commission_acc IS NOT NULL
     AND v_t.commission > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_old_commission_acc, v_t.from_branch_id, -v_t.commission,
            COALESCE(NULLIF(v_t.commission_currency, ''), v_t.currency), v_now)
    ON CONFLICT (account_id) DO UPDATE
      SET balance    = account_balances.balance - v_t.commission,
          updated_at = v_now;

    -- Удаляем старую credit-проводку, она будет переписана.
    DELETE FROM ledger_entries
     WHERE reference_type = 'commission'
       AND reference_id   = p_transfer_id::text
       AND account_id     = v_old_commission_acc
       AND type IN ('credit', 'debit');
  END IF;

  -- Снять новый debit с НОВОГО основного счёта.
  SELECT balance INTO v_balance
    FROM account_balances
   WHERE account_id = v_new_from FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  IF v_balance < v_new_total THEN
    UPDATE account_balances
       SET balance    = balance - v_old_total,
           updated_at = v_now
     WHERE account_id = v_t.from_account_id;
    IF v_t.commission_mode = 'fromAccount'
       AND v_old_commission_acc IS NOT NULL
       AND v_t.commission > 0 THEN
      UPDATE account_balances
         SET balance    = balance + v_t.commission,
             updated_at = v_now
       WHERE account_id = v_old_commission_acc;
    END IF;
    RAISE EXCEPTION 'Недостаточно средств на счёте. Доступно: %, требуется: %',
      round(v_balance::numeric, 2), round(v_new_total::numeric, 2);
  END IF;

  INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_new_from, v_t.from_branch_id, -v_new_total, v_currency, v_now)
  ON CONFLICT (account_id) DO UPDATE
    SET balance    = account_balances.balance - v_new_total,
        updated_at = v_now;

  -- ── CREDIT новую commission на новый commission_account_id ─────
  IF v_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (v_new_commission_acc, v_t.from_branch_id, v_commission,
            v_commission_currency, v_now)
    ON CONFLICT (account_id) DO UPDATE
      SET balance    = account_balances.balance + v_commission,
          updated_at = v_now;
  END IF;

  v_code := COALESCE(v_t.transaction_code, p_transfer_id::text);

  DELETE FROM ledger_entries
   WHERE reference_type = 'transfer'
     AND reference_id   = p_transfer_id::text
     AND branch_id      = v_t.from_branch_id
     AND type           = 'debit';

  INSERT INTO ledger_entries
    (branch_id, account_id, type, amount, currency, reference_type,
     reference_id, transaction_code, description, created_by)
  VALUES
    (v_t.from_branch_id, v_new_from, 'debit', v_new_total, v_currency,
     'transfer', p_transfer_id::text, v_code,
     'Перевод ' || v_code || ' (отредактирован, ожидает приёма)', v_user_id);

  IF v_commission_mode = 'fromAccount' AND v_commission > 0 THEN
    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency, reference_type,
       reference_id, transaction_code, description, created_by)
    VALUES
      (v_t.from_branch_id, v_new_commission_acc, 'credit', v_commission,
       v_commission_currency, 'commission', p_transfer_id::text, v_code,
       'Доход: комиссия по переводу ' || v_code || ' (отредактировано)',
       v_user_id);
  END IF;

  IF v_commission_mode = 'fromTransfer' THEN
    v_receiver := v_amount - v_commission;
  ELSIF v_commission_mode = 'toReceiver' THEN
    v_receiver := v_amount + v_commission;
  ELSE
    v_receiver := v_amount;
  END IF;
  v_converted := v_receiver * v_rate;

  IF v_t.amount <> v_amount THEN
    v_changes := jsonb_set(v_changes, '{amount}',
      jsonb_build_object('from', v_t.amount, 'to', v_amount));
  END IF;
  IF v_t.currency <> v_currency THEN
    v_changes := jsonb_set(v_changes, '{currency}',
      jsonb_build_object('from', v_t.currency, 'to', v_currency));
  END IF;
  IF COALESCE(v_t.to_currency, '') <> COALESCE(v_to_cur, '') THEN
    v_changes := jsonb_set(v_changes, '{to_currency}',
      jsonb_build_object('from', v_t.to_currency, 'to', v_to_cur));
  END IF;
  IF v_t.exchange_rate <> v_rate THEN
    v_changes := jsonb_set(v_changes, '{exchange_rate}',
      jsonb_build_object('from', v_t.exchange_rate, 'to', v_rate));
  END IF;
  IF v_t.commission_value <> v_commission_value
     OR v_t.commission_type <> v_commission_type
     OR v_t.commission_mode <> v_commission_mode
     OR COALESCE(v_t.commission_currency, '') <> COALESCE(v_commission_currency, '')
     OR COALESCE(v_t.commission_account_id::text, '') <> COALESCE(v_new_commission_acc::text, '') THEN
    v_changes := jsonb_set(v_changes, '{commission}',
      jsonb_build_object(
        'from', jsonb_build_object('type', v_t.commission_type,
                                   'value', v_t.commission_value,
                                   'currency', v_t.commission_currency,
                                   'mode', v_t.commission_mode,
                                   'accountId', v_t.commission_account_id),
        'to',   jsonb_build_object('type', v_commission_type,
                                   'value', v_commission_value,
                                   'currency', v_commission_currency,
                                   'mode', v_commission_mode,
                                   'accountId', v_new_commission_acc)));
  END IF;
  IF v_t.from_account_id <> v_new_from THEN
    v_changes := jsonb_set(v_changes, '{from_account_id}',
      jsonb_build_object('from', v_t.from_account_id::text, 'to', v_new_from::text));
  END IF;

  UPDATE transfers SET
    from_account_id    = v_new_from,
    amount             = v_amount,
    currency           = v_currency,
    to_currency        = v_to_cur,
    exchange_rate      = v_rate,
    converted_amount   = v_converted,
    commission         = v_commission,
    commission_type    = v_commission_type,
    commission_value   = v_commission_value,
    commission_currency= v_commission_currency,
    commission_mode    = v_commission_mode,
    commission_account_id = v_new_commission_acc,
    to_account_id      = CASE
      WHEN p_to_account_id IS NULL THEN to_account_id
      WHEN p_to_account_id = ''    THEN ''
      ELSE p_to_account_id
    END,
    description        = COALESCE(p_description, description),
    client_id          = COALESCE(p_client_id, client_id),
    sender_name        = COALESCE(p_sender_name, sender_name),
    sender_phone       = COALESCE(p_sender_phone, sender_phone),
    sender_info        = COALESCE(p_sender_info, sender_info),
    receiver_name      = COALESCE(p_receiver_name, receiver_name),
    receiver_phone     = COALESCE(p_receiver_phone, receiver_phone),
    receiver_info      = COALESCE(p_receiver_info, receiver_info),
    amendment_history  = COALESCE(amendment_history, '[]'::jsonb) || jsonb_build_array(
        jsonb_build_object(
          'at',      v_now,
          'userId',  v_user_id::text,
          'note',    NULLIF(trim(coalesce(p_amendment_note,'')), ''),
          'changes', v_changes
        )
      )
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'changes', v_changes
  );
END;
$$;


-- ─── 3. Сводка собранных комиссий по ledger_entries ─────────────
-- Считаем по credit-проводкам с reference_type='commission' — это
-- именно «доходные» комиссии в новой семантике fromAccount.
-- Раньше (до 032) commission был debit — такие старые записи мы тоже
-- учитываем как валовые суммы, но помечаем направление через
-- separate columns.
CREATE OR REPLACE FUNCTION private.commission_summary(
  p_branch_id uuid DEFAULT NULL,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
)
RETURNS TABLE (
  branch_id uuid,
  currency text,
  total_income double precision,
  total_legacy_debit double precision,
  net double precision,
  entries bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    le.branch_id,
    le.currency,
    COALESCE(SUM(CASE WHEN le.type = 'credit' THEN le.amount ELSE 0 END), 0)
      AS total_income,
    COALESCE(SUM(CASE WHEN le.type = 'debit'  THEN le.amount ELSE 0 END), 0)
      AS total_legacy_debit,
    COALESCE(SUM(CASE WHEN le.type = 'credit' THEN le.amount
                      WHEN le.type = 'debit'  THEN -le.amount
                      ELSE 0 END), 0) AS net,
    COUNT(*) AS entries
  FROM ledger_entries le
  WHERE le.reference_type = 'commission'
    AND (p_branch_id IS NULL OR le.branch_id = p_branch_id)
    AND (p_start IS NULL OR le.created_at >= p_start)
    AND (p_end   IS NULL OR le.created_at <  p_end)
  GROUP BY le.branch_id, le.currency
  ORDER BY le.branch_id, le.currency;
$$;

CREATE OR REPLACE FUNCTION public.admin_commission_summary(
  p_branch_id uuid DEFAULT NULL,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
)
RETURNS TABLE (
  branch_id uuid,
  currency text,
  total_income double precision,
  total_legacy_debit double precision,
  net double precision,
  entries bigint
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role::text INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('creator', 'director') THEN
    RAISE EXCEPTION 'Only creator/director can view commission summary';
  END IF;
  RETURN QUERY SELECT * FROM private.commission_summary(p_branch_id, p_start, p_end);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_commission_summary(uuid, timestamptz, timestamptz)
  TO authenticated;

COMMIT;
