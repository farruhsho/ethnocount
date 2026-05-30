-- ============================================================
-- 033: Партнёрские переводы (Тима-кейс)
-- ============================================================
-- Бизнес-сценарий:
--   • Клиент A приходит в Ташкент и хочет отправить деньги в Москву.
--   • Своего филиала в Москве у нас НЕТ — но есть партнёр Тима,
--     который выплачивает наших клиентов налом или картой на месте.
--   • Бухгалтер Ташкента отдаёт сумму нашему кэш-счёту, а в Москве
--     Тима выплачивает получателю. Тима стал должен ровно эту сумму
--     (saldo с Тимой уходит в минус).
--   • Периодически встречаемся: либо Тима везёт нал в Ташкент
--     (`settle_to_us`), либо мы отдаём ему нал в Ташкенте
--     (`settle_from_us`). Saldo возвращается к нулю.
--
-- Что добавлено:
--   1) `counterparties.home_branch_id`, `fee_percentage` (для будущего).
--   2) `counterparty_transactions.transfer_id`, `cash_account_id`,
--      `payout_method`, `exchange_rate` — связь с переводом, движение
--      нашего наличного счёта на settle-операциях, способ выплаты.
--   3) `transfers.via_counterparty_id` — маркирует партнёрский перевод.
--   4) Снят жёсткий CHECK на commission_mode (он не пускал 'fromAccount').
--   5) `private.create_partner_transfer(...)` — atomic RPC: debit
--      основного счёта + counterparty_transaction(paid_for_us) одним
--      движением. Transfer сразу идёт в статус 'delivered'.
--   6) `private.record_counterparty_op` обновлён: для settle-операций
--      обязателен cash_account_id, и наш баланс реально двигается.
--   7) `private.partner_balance_summary(...)` + public-обёртка.
--
-- Идемпотентно — CREATE OR REPLACE, ADD COLUMN IF NOT EXISTS.
-- ============================================================

BEGIN;

-- ─── 1. Расширяем counterparties ─────────────────────────────
ALTER TABLE public.counterparties
  ADD COLUMN IF NOT EXISTS home_branch_id uuid
    REFERENCES public.branches(id),
  ADD COLUMN IF NOT EXISTS fee_percentage double precision
    CHECK (fee_percentage IS NULL OR fee_percentage >= 0);

COMMENT ON COLUMN public.counterparties.home_branch_id IS
  'Филиал, который ведёт расчёты с этим партнёром (обычно head-офис).';
COMMENT ON COLUMN public.counterparties.fee_percentage IS
  'Процент партнёра за выплату — резерв на будущее, в RPC пока не используется.';

-- ─── 2. Расширяем counterparty_transactions ──────────────────
ALTER TABLE public.counterparty_transactions
  ADD COLUMN IF NOT EXISTS transfer_id uuid
    REFERENCES public.transfers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cash_account_id uuid
    REFERENCES public.branch_accounts(id),
  ADD COLUMN IF NOT EXISTS payout_method text
    CHECK (payout_method IS NULL OR payout_method IN ('cash', 'card', 'transfer', 'other')),
  ADD COLUMN IF NOT EXISTS exchange_rate double precision
    CHECK (exchange_rate IS NULL OR exchange_rate > 0);

CREATE INDEX IF NOT EXISTS idx_cp_tx_transfer
  ON public.counterparty_transactions (transfer_id)
  WHERE transfer_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cp_tx_cash_account
  ON public.counterparty_transactions (cash_account_id)
  WHERE cash_account_id IS NOT NULL;

-- ─── 3. Расширяем transfers ──────────────────────────────────
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS via_counterparty_id uuid
    REFERENCES public.counterparties(id);

CREATE INDEX IF NOT EXISTS idx_transfers_via_counterparty
  ON public.transfers (via_counterparty_id)
  WHERE via_counterparty_id IS NOT NULL;

-- Снимаем устаревший CHECK на commission_mode — 027 ввела режим
-- 'fromAccount', но constraint остался legacy. На случай, если PG
-- вообще его не применил — DROP IF EXISTS безопасен.
DO $migration$
DECLARE
  v_check_name text;
BEGIN
  SELECT conname INTO v_check_name
    FROM pg_constraint
   WHERE conrelid = 'public.transfers'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%commission_mode%';
  IF v_check_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.transfers DROP CONSTRAINT %I', v_check_name);
  END IF;
END $migration$;

ALTER TABLE public.transfers
  ADD CONSTRAINT transfers_commission_mode_check
  CHECK (commission_mode IN
    ('fromSender', 'fromTransfer', 'toReceiver', 'fromAccount'));


-- ─── 4. record_counterparty_op: settle двигает наш счёт ──────
-- Drop all overload-варианты (5/9/12 параметров) перед CREATE, чтобы
-- public-обёртки могли однозначно резолвить вызов через DEFAULT-аргументы.
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text);
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision,
  double precision, text, double precision);

CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL,
  p_cash_account_id uuid DEFAULT NULL,
  p_transfer_id uuid DEFAULT NULL,
  p_payout_method text DEFAULT NULL,
  p_exchange_rate double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_cp counterparties%ROWTYPE;
  v_cur text;
  v_curr_saldo double precision;
  v_delta double precision;
  v_new_saldo double precision;
  v_acc branch_accounts%ROWTYPE;
  v_cash_delta double precision;
  v_acc_balance double precision;
  v_role text;
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

  v_cur := upper(trim(p_currency));
  IF v_cur = '' THEN RAISE EXCEPTION 'Валюта обязательна'; END IF;

  v_delta := CASE p_kind
    WHEN 'paid_for_us'      THEN -p_amount
    WHEN 'we_paid_for_them' THEN  p_amount
    WHEN 'settle_to_us'     THEN -p_amount
    WHEN 'settle_from_us'   THEN  p_amount
    ELSE NULL
  END;
  IF v_delta IS NULL THEN
    RAISE EXCEPTION 'Неизвестный тип операции: %', p_kind;
  END IF;

  -- ── Settlement требует кэш-счёт ─────────────────────────────
  IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
    IF p_cash_account_id IS NULL THEN
      RAISE EXCEPTION
        'Для расчёта (settle) обязательно укажите кеш-счёт нашего филиала';
    END IF;
    SELECT * INTO v_acc FROM branch_accounts WHERE id = p_cash_account_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Кеш-счёт не найден'; END IF;
    -- Валюту settlement-а сводим к валюте счёта (на клиенте уже должно
    -- совпадать, но защищаемся).
    IF upper(v_acc.currency) <> v_cur THEN
      RAISE EXCEPTION
        'Валюта расчёта (%) не совпадает с валютой выбранного счёта (%)',
        v_cur, v_acc.currency;
    END IF;
    -- settle_to_us = он принёс нам нал → +на наш счёт (credit)
    -- settle_from_us = мы отдали ему нал → −с нашего счёта (debit)
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
    VALUES (p_cash_account_id, v_acc.branch_id, v_cash_delta, v_acc.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance + v_cash_delta,
          updated_at = now();

    -- Ledger-проводка для прозрачности.
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
           ELSE 'Расчёт партнёру ' || v_cp.name END,
      v_uid
    );
  END IF;

  -- ── Двигаем saldo партнёра ──────────────────────────────────
  v_curr_saldo := COALESCE(
    (v_cp.saldo_by_currency->>v_cur)::double precision, 0);
  v_new_saldo := v_curr_saldo + v_delta;

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

  INSERT INTO counterparty_transactions
    (counterparty_id, kind, amount, currency, description, created_by,
     transfer_id, cash_account_id, payout_method, exchange_rate)
  VALUES
    (p_counterparty_id, p_kind, p_amount, v_cur,
     NULLIF(trim(p_description), ''), v_uid,
     p_transfer_id, p_cash_account_id,
     NULLIF(trim(p_payout_method), ''), p_exchange_rate);

  RETURN jsonb_build_object('success', true, 'newSaldo', v_new_saldo);
END;
$$;

-- Public wrapper. Drop старая узкая сигнатура.
DROP FUNCTION IF EXISTS public.record_counterparty_op(
  uuid, text, double precision, text, text);

CREATE OR REPLACE FUNCTION public.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL,
  p_cash_account_id uuid DEFAULT NULL,
  p_transfer_id uuid DEFAULT NULL,
  p_payout_method text DEFAULT NULL,
  p_exchange_rate double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.record_counterparty_op(
    p_counterparty_id, p_kind, p_amount, p_currency, p_description,
    p_cash_account_id, p_transfer_id, p_payout_method, p_exchange_rate
  );
$$;

GRANT EXECUTE ON FUNCTION public.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision
) TO authenticated;


-- ─── 5. create_partner_transfer: создать «партнёрский» перевод ──
-- Логика:
--   • Debit основного счёта-источника на p_amount + комиссию (если fromSender)
--     или на p_amount (если fromTransfer/fromAccount).
--   • Insert transfer со status='delivered' и via_counterparty_id.
--     to_branch_id = from_branch_id (партнёр живёт в from-филиале по саДьдо).
--     to_account_id = '' (счёта получателя у нас нет).
--   • Counterparty_transaction(kind='paid_for_us', amount, currency,
--     transfer_id, payout_method) → saldo партнёра вниз (мы должны).
--   • Комиссия в режиме fromAccount: credit на commission_account_id
--     (как обычно в 032). В fromTransfer/fromSender — без отдельной
--     проводки, остаётся в самом transfer.
-- Drop overload-варианты (20/22/24 параметра) для idempotent re-apply.
DROP FUNCTION IF EXISTS private.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text);
DROP FUNCTION IF EXISTS private.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text, text, double precision);
DROP FUNCTION IF EXISTS private.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text, text, double precision,
  double precision, double precision, text);

CREATE OR REPLACE FUNCTION private.create_partner_transfer(
  p_from_branch_id uuid,
  p_from_account_id uuid,
  p_counterparty_id uuid,
  p_amount double precision,
  p_currency text DEFAULT 'USD',
  p_payout_method text DEFAULT 'cash',
  p_commission_type text DEFAULT 'fixed',
  p_commission_value double precision DEFAULT 0,
  p_commission_currency text DEFAULT NULL,
  p_commission_mode text DEFAULT 'fromTransfer',
  p_commission_account_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT '',
  p_description text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_sender_phone text DEFAULT NULL,
  p_sender_info text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL,
  p_receiver_phone text DEFAULT NULL,
  p_receiver_info text DEFAULT NULL
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
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  -- Партнёр обязателен и должен быть активен.
  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Партнёр деактивирован'; END IF;

  v_payout_method := COALESCE(NULLIF(trim(p_payout_method), ''), 'cash');
  IF v_payout_method NOT IN ('cash', 'card', 'transfer', 'other') THEN
    RAISE EXCEPTION 'Неизвестный способ выплаты: %', v_payout_method;
  END IF;

  -- Сверка branch ↔ account.
  SELECT branch_id INTO v_acc_branch
    FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Счёт-источник не найден'; END IF;
  IF v_acc_branch <> p_from_branch_id THEN
    RAISE EXCEPTION 'Счёт-источник не относится к указанному филиалу';
  END IF;

  -- Резолвим коммиссию в правильной валюте.
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
    v_total_debit := p_amount;
  ELSE
    v_commission := private.normalize_commission(
      p_commission_type, p_commission_value,
      COALESCE(NULLIF(p_commission_currency, ''), p_currency),
      p_amount, p_currency
    );
    IF p_commission_mode = 'fromSender' THEN
      v_total_debit := p_amount + v_commission;
    ELSE
      v_total_debit := p_amount;
    END IF;
  END IF;

  -- Проверка баланса основного счёта.
  SELECT balance INTO v_balance
    FROM account_balances WHERE account_id = p_from_account_id FOR UPDATE;
  v_balance := COALESCE(v_balance, 0);
  IF v_balance < v_total_debit THEN
    RAISE EXCEPTION 'Insufficient funds. Available: %, required: %',
      round(v_balance::numeric, 2), round(v_total_debit::numeric, 2);
  END IF;

  v_code := private.next_transaction_code('PTN', 'transactionCodes');
  v_transfer_id := gen_random_uuid();

  -- Insert transfer (delivered сразу — выплата произошла на стороне партнёра).
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
      created_at
    ) VALUES (
      v_transfer_id, v_code,
      p_from_branch_id, p_from_branch_id,
      p_from_account_id, '',
      p_amount, p_currency, p_currency, 1, p_amount,
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
      now()
    );
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Duplicate partner transfer';
  END;

  -- Debit основной счёт.
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
    'Партнёрский перевод ' || v_code || ' через ' || v_cp.name, v_user_id
  );

  -- Commission на отдельный счёт (income) — как в 032.
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
      'Доход: комиссия по партнёрскому переводу ' || v_code, v_user_id
    );
  END IF;

  -- Запись в commissions (история сборов).
  IF v_commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (
      v_transfer_id, p_from_branch_id, v_commission,
      CASE WHEN p_commission_mode = 'fromAccount' THEN v_comm_acc_currency
           ELSE COALESCE(NULLIF(p_commission_currency, ''), p_currency) END,
      COALESCE(p_commission_type, 'fixed'), now()
    );
  END IF;

  -- Самое главное: партнёр стал нам должен на сумму выплаты.
  PERFORM private.record_counterparty_op(
    p_counterparty_id := p_counterparty_id,
    p_kind            := 'paid_for_us',
    p_amount          := p_amount,
    p_currency        := p_currency,
    p_description     := 'Выплата по переводу ' || v_code
                          || COALESCE(' получателю ' || p_receiver_name, ''),
    p_cash_account_id := NULL,
    p_transfer_id     := v_transfer_id,
    p_payout_method   := v_payout_method,
    p_exchange_rate   := NULL
  );

  RETURN jsonb_build_object(
    'success', true,
    'transferId', v_transfer_id::text,
    'transactionCode', v_code,
    'partnerId', p_counterparty_id::text
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_partner_transfer(
  p_from_branch_id uuid,
  p_from_account_id uuid,
  p_counterparty_id uuid,
  p_amount double precision,
  p_currency text DEFAULT 'USD',
  p_payout_method text DEFAULT 'cash',
  p_commission_type text DEFAULT 'fixed',
  p_commission_value double precision DEFAULT 0,
  p_commission_currency text DEFAULT NULL,
  p_commission_mode text DEFAULT 'fromTransfer',
  p_commission_account_id uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT '',
  p_description text DEFAULT NULL,
  p_client_id text DEFAULT NULL,
  p_sender_name text DEFAULT NULL,
  p_sender_phone text DEFAULT NULL,
  p_sender_info text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL,
  p_receiver_phone text DEFAULT NULL,
  p_receiver_info text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.create_partner_transfer(
    p_from_branch_id, p_from_account_id, p_counterparty_id,
    p_amount, p_currency, p_payout_method,
    p_commission_type, p_commission_value, p_commission_currency,
    p_commission_mode, p_commission_account_id,
    p_idempotency_key, p_description, p_client_id,
    p_sender_name, p_sender_phone, p_sender_info,
    p_receiver_name, p_receiver_phone, p_receiver_info
  );
$$;

GRANT EXECUTE ON FUNCTION public.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text
) TO authenticated;


-- ─── 6. Сводка по партнёрам ──────────────────────────────────
-- saldo + последняя активность + кол-во операций по валютам.
CREATE OR REPLACE FUNCTION private.partner_balance_summary(
  p_counterparty_id uuid DEFAULT NULL
)
RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  is_active boolean,
  currency text,
  saldo double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH per_cur AS (
    SELECT
      cpt.counterparty_id,
      cpt.currency,
      COUNT(*) AS tx_count,
      MAX(cpt.created_at) AS last_op_at
    FROM counterparty_transactions cpt
    WHERE p_counterparty_id IS NULL OR cpt.counterparty_id = p_counterparty_id
    GROUP BY cpt.counterparty_id, cpt.currency
  )
  SELECT
    cp.id, cp.name, cp.city, cp.is_active,
    upper(k.key) AS currency,
    (k.value)::double precision AS saldo,
    COALESCE(p.tx_count, 0) AS tx_count,
    p.last_op_at
  FROM counterparties cp
  CROSS JOIN LATERAL jsonb_each_text(cp.saldo_by_currency) k
  LEFT JOIN per_cur p ON p.counterparty_id = cp.id
                     AND p.currency = upper(k.key)
  WHERE p_counterparty_id IS NULL OR cp.id = p_counterparty_id
  ORDER BY cp.name, currency;
$$;

CREATE OR REPLACE FUNCTION public.admin_partner_summary(
  p_counterparty_id uuid DEFAULT NULL
)
RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  is_active boolean,
  currency text,
  saldo double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role::text INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'User must be authenticated';
  END IF;
  -- accountant видит summary — это часть его работы.
  RETURN QUERY SELECT * FROM private.partner_balance_summary(p_counterparty_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_partner_summary(uuid) TO authenticated;

-- ─── 7. RLS: разрешить INSERT для record_counterparty_op ─────
-- Чтения уже открыты в 029. Для INSERT в counterparty_transactions
-- RPC SECURITY DEFINER обходит RLS, поэтому отдельные policies
-- не нужны. Но добавим explicit policy на UPDATE counterparties
-- для будущей правки через RPC.
DROP POLICY IF EXISTS counterparty_tx_insert ON public.counterparty_transactions;
DROP POLICY IF EXISTS counterparties_update ON public.counterparties;


-- ─── 8. Бухгалтеры тоже могут создавать партнёров ────────────
-- 029 пускала только creator/director. По запросу — открываем для всех
-- аутентифицированных. Для бухгалтера автоподставляем home_branch_id
-- из его первого assigned-филиала, чтобы запись сразу была привязана
-- к месту, где он работает.
-- Drop предыдущие варианты, чтобы повторный db push не падал с
-- «function is not unique».
DROP FUNCTION IF EXISTS private.create_counterparty(text, text, text, text);
DROP FUNCTION IF EXISTS private.create_counterparty(
  text, text, text, text, uuid, double precision);

CREATE OR REPLACE FUNCTION private.create_counterparty(
  p_name text,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_id uuid;
  v_home_branch uuid;
  v_assigned text[];
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Имя партнёра обязательно';
  END IF;

  -- Резолвим home_branch:
  --   • явно передан — берём как есть, но проверяем что существует;
  --   • для бухгалтера без аргумента — берём первый assigned filial;
  --   • для creator/director без аргумента — NULL (глобальный партнёр).
  IF p_home_branch_id IS NOT NULL THEN
    PERFORM 1 FROM public.branches WHERE id = p_home_branch_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Филиал партнёра не найден'; END IF;
    v_home_branch := p_home_branch_id;
  ELSIF v_role = 'accountant' THEN
    SELECT assigned_branch_ids INTO v_assigned
      FROM public.users WHERE id = v_uid;
    IF v_assigned IS NULL OR array_length(v_assigned, 1) IS NULL THEN
      RAISE EXCEPTION 'У вас нет ни одного assigned-филиала; обратитесь к директору';
    END IF;
    v_home_branch := v_assigned[1]::uuid;
  ELSE
    v_home_branch := NULL;
  END IF;

  INSERT INTO counterparties
    (name, city, phone, notes, home_branch_id, fee_percentage, created_by)
  VALUES
    (trim(p_name), NULLIF(trim(p_city), ''), NULLIF(trim(p_phone), ''),
     NULLIF(trim(p_notes), ''), v_home_branch, p_fee_percentage, v_uid)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'counterpartyId', v_id::text);
END;
$$;

-- public wrapper c расширенной сигнатурой. Сначала дропаем старую узкую.
DROP FUNCTION IF EXISTS public.create_counterparty(text, text, text, text);

CREATE OR REPLACE FUNCTION public.create_counterparty(
  p_name text,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.create_counterparty(
    p_name, p_city, p_phone, p_notes, p_home_branch_id, p_fee_percentage
  )
$$;

GRANT EXECUTE ON FUNCTION public.create_counterparty(
  text, text, text, text, uuid, double precision
) TO authenticated;

COMMIT;
