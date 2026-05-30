-- ============================================================
-- 036: Dealer spread + partner profit analytics
-- ============================================================
-- Этот апгрейд закрывает классическую дилерскую модель:
--
--   У клиента в Ташкенте принимаем местную валюту (UZS) по нашему
--   КУРСУ ПРИЁМА (buy_rate). Например 1 USD = 12500 UZS.
--   Партнёр в Москве выплачивает получателю эквивалент в RUB.
--   Settlement с партнёром — по КУРСУ РАСЧЁТА (sell_rate), обычно
--   ниже: 1 USD = 12000 UZS. Разница (12500-12000) × amount/12500 = ПРИБЫЛЬ С КУРСА.
--
-- Что вводим:
--   transfers.buy_rate         — наш курс приёма (1 base = X currency)
--   transfers.sell_rate        — курс расчёта с партнёром
--   transfers.base_currency    — валюта учёта прибыли и saldo
--                               (если NULL → = currency, spread = 0)
--
-- Что обновляем:
--   create_partner_transfer    — принимает p_buy_rate, p_sell_rate,
--                                p_base_currency. Считает и сохраняет
--                                spread_profit_amount в transfers
--                                как кэш для быстрой аналитики
--                                (см. ниже про profit_amount).
--
-- Что добавляем RPC-уровнем:
--   partner_profit_summary     — детальный профит по партнёру за период,
--                                разбит на spread / commission / settlement,
--                                сгруппирован по base_currency.
--   transfer_profit_summary    — то же для всех переводов (свод по
--                                филиалам, опц. фильтр partner_only).
--   account_partner_profit_window — KPI карточки в UI карточки партнёра.
--
-- Backfill — НЕ делаем (по решению пользователя). Старые переводы
-- остаются с buy_rate=NULL, sell_rate=NULL → spread = 0. Аналитика
-- покажет 0 spread для исторических данных.
--
-- Идемпотентно. Безопасно повторно применять.
-- ============================================================

BEGIN;

-- ─── 1. Колонки на transfers ─────────────────────────────────
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS buy_rate       double precision,
  ADD COLUMN IF NOT EXISTS sell_rate      double precision,
  ADD COLUMN IF NOT EXISTS base_currency  text,
  -- Кэшированная прибыль с курса. Заполняется в RPC. Для исторических
  -- переводов NULL — аналитика трактует как 0.
  -- Валюта профита всегда = currency (валюте принятия).
  ADD COLUMN IF NOT EXISTS spread_profit  double precision;

COMMENT ON COLUMN public.transfers.buy_rate IS
  'Курс приёма от клиента: 1 [base_currency] = X [currency]. '
  'Например, USD-base: 1 USD = 12500 UZS → buy_rate=12500.';
COMMENT ON COLUMN public.transfers.sell_rate IS
  'Курс расчёта с партнёром: 1 [base_currency] = Y [currency]. '
  'Меньше buy_rate → есть spread profit.';
COMMENT ON COLUMN public.transfers.base_currency IS
  'Валюта учёта прибыли и saldo. Если NULL — same-currency, spread=0.';
COMMENT ON COLUMN public.transfers.spread_profit IS
  'Кэш курсовой прибыли в валюте currency: amount - (amount/buy_rate)*sell_rate.';

CREATE INDEX IF NOT EXISTS idx_transfers_via_counterparty_created
  ON public.transfers (via_counterparty_id, created_at DESC)
  WHERE via_counterparty_id IS NOT NULL;

-- ─── 2. Helper: вычисление spread profit ─────────────────────
-- Возвращает сумму spread в валюте `currency`. NULL если базовых
-- данных нет или нет смысла (same-rate / one of rates is NULL).
CREATE OR REPLACE FUNCTION private.calc_spread_profit(
  p_amount    double precision,
  p_buy_rate  double precision,
  p_sell_rate double precision
) RETURNS double precision
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_amount IS NULL OR p_amount <= 0 THEN 0
    WHEN p_buy_rate IS NULL OR p_sell_rate IS NULL THEN 0
    WHEN p_buy_rate <= 0 OR p_sell_rate <= 0 THEN 0
    -- amount_in_base = amount / buy_rate
    -- partner_owes  = amount_in_base * sell_rate
    -- spread        = amount - partner_owes
    ELSE p_amount - (p_amount / p_buy_rate) * p_sell_rate
  END;
$$;

-- ─── 3. create_partner_transfer: расширенный ─────────────────
-- Сигнатура добавляет: p_buy_rate, p_sell_rate, p_base_currency.
-- Обратная совместимость: если присланы только legacy p_exchange_rate +
-- p_to_currency (старые клиенты) — buy=sell=exchange_rate, spread=0.
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
  -- NEW: курс приёма от клиента (наш дилерский курс)
  p_buy_rate              double precision DEFAULT NULL,
  -- NEW: курс расчёта с партнёром (settlement-курс)
  p_sell_rate             double precision DEFAULT NULL,
  -- NEW: валюта учёта прибыли и saldo. Если NULL — берётся p_currency.
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

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN
    RAISE EXCEPTION 'Партнёр архивирован — операции запрещены. Разархивируйте его, чтобы продолжить.';
  END IF;

  v_payout_method := COALESCE(NULLIF(trim(p_payout_method), ''), 'cash');
  IF v_payout_method NOT IN ('cash', 'card', 'transfer', 'other') THEN
    RAISE EXCEPTION 'Неизвестный способ выплаты: %', v_payout_method;
  END IF;

  -- Cross-currency для выплаты получателю (legacy логика).
  v_to_currency := COALESCE(NULLIF(trim(p_to_currency), ''), p_currency);
  v_rate := COALESCE(p_exchange_rate, 1);
  IF v_rate <= 0 THEN
    RAISE EXCEPTION 'Курс обмена должен быть больше нуля (получен: %)', v_rate;
  END IF;
  IF v_to_currency = p_currency AND v_rate <> 1 THEN
    v_rate := 1;
  END IF;

  -- Buy/Sell/base: дилерская модель.
  -- Если оба buy_rate и sell_rate NULL — same-rate transfer (spread=0).
  -- Если присланы — base_currency обязательна, иначе берём p_currency.
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
    -- Если base = currency — buy/sell не имеют смысла (нет конвертации).
    -- Защищаемся: spread = 0.
    IF v_base_cur = p_currency THEN
      v_spread := 0;
    ELSE
      v_spread := private.calc_spread_profit(p_amount, v_buy, v_sell);
    END IF;
  ELSE
    v_spread := 0;
  END IF;

  -- Сверка branch ↔ account.
  SELECT branch_id INTO v_acc_branch
    FROM branch_accounts WHERE id = p_from_account_id;
  IF v_acc_branch IS NULL THEN RAISE EXCEPTION 'Счёт-источник не найден'; END IF;
  IF v_acc_branch <> p_from_branch_id THEN
    RAISE EXCEPTION 'Счёт-источник не относится к указанному филиалу';
  END IF;

  -- Резолвим коммиссию.
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
  v_converted := p_amount * v_rate;

  -- Saldo с партнёром.
  -- Если есть buy/sell — мы должны partner = base_amount в base_currency.
  -- Без них — fallback: мы должны partner = amount в currency (legacy).
  IF v_buy IS NOT NULL AND v_buy > 0 AND v_base_cur IS NOT NULL
     AND v_base_cur <> p_currency THEN
    v_partner_owes_amount := p_amount / v_buy;
    v_partner_owes_currency := v_base_cur;
  ELSE
    v_partner_owes_amount := p_amount;
    v_partner_owes_currency := p_currency;
  END IF;

  -- Insert transfer (delivered сразу).
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

  -- Commission на отдельный счёт.
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

  -- Commissions table.
  IF v_commission > 0 THEN
    INSERT INTO commissions (transfer_id, branch_id, amount, currency, type, created_at)
    VALUES (
      v_transfer_id, p_from_branch_id, v_commission,
      CASE WHEN p_commission_mode = 'fromAccount' THEN v_comm_acc_currency
           ELSE COALESCE(NULLIF(p_commission_currency, ''), p_currency) END,
      COALESCE(p_commission_type, 'fixed'), now()
    );
  END IF;

  -- Партнёр стал нам должен в РАСЧЁТНОЙ валюте.
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
    p_exchange_rate   := CASE WHEN v_buy IS NULL THEN NULL ELSE v_buy END
  );

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
    'baseCurrency', v_partner_owes_currency
  );
END;
$$;

-- Drop старая узкая сигнатура.
DROP FUNCTION IF EXISTS public.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text, text, double precision);

CREATE OR REPLACE FUNCTION public.create_partner_transfer(
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
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.create_partner_transfer(
    p_from_branch_id, p_from_account_id, p_counterparty_id,
    p_amount, p_currency, p_payout_method,
    p_commission_type, p_commission_value, p_commission_currency,
    p_commission_mode, p_commission_account_id,
    p_idempotency_key, p_description, p_client_id,
    p_sender_name, p_sender_phone, p_sender_info,
    p_receiver_name, p_receiver_phone, p_receiver_info,
    p_to_currency, p_exchange_rate,
    p_buy_rate, p_sell_rate, p_base_currency
  );
$$;

GRANT EXECUTE ON FUNCTION public.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text, text, double precision,
  double precision, double precision, text
) TO authenticated;


-- ─── 4. partner_profit_summary ────────────────────────────────
-- Возвращает прибыль с партнёра за период, разбитую по валютам.
-- Spread считается из transfers, commission — из commissions table.
CREATE OR REPLACE FUNCTION private.partner_profit_summary(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
) RETURNS TABLE (
  currency text,
  transfer_count bigint,
  total_volume double precision,            -- сумма amount (в этой currency)
  spread_profit double precision,           -- сумма spread_profit (в currency)
  commission_profit double precision,       -- сумма commission (в currency)
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.currency,
      t.amount,
      COALESCE(t.spread_profit, 0) AS spread,
      t.created_at
    FROM transfers t
    WHERE t.via_counterparty_id = p_counterparty_id
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
  ),
  comm AS (
    SELECT
      c.transfer_id,
      c.currency,
      SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id, c.currency
  )
  SELECT
    b.currency,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount) AS total_volume,
    SUM(b.spread) AS spread_profit,
    COALESCE(SUM(
      (SELECT commission_total FROM comm WHERE comm.transfer_id = b.id AND comm.currency = b.currency)
    ), 0) AS commission_profit,
    MIN(b.created_at) AS first_at,
    MAX(b.created_at) AS last_at
  FROM base b
  GROUP BY b.currency
  ORDER BY total_volume DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION public.partner_profit_summary(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
) RETURNS TABLE (
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_summary(p_counterparty_id, p_start, p_end);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_summary(uuid, timestamptz, timestamptz)
  TO authenticated;


-- ─── 5. transfer_profit_summary (общий) ───────────────────────
-- Свод по филиалам, для общей аналитики. Опц. фильтр partner_only.
CREATE OR REPLACE FUNCTION private.transfer_profit_summary(
  p_branch_id     uuid DEFAULT NULL,
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT false
) RETURNS TABLE (
  branch_id uuid,
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  is_partner boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.from_branch_id AS branch_id,
      t.currency,
      t.amount,
      COALESCE(t.spread_profit, 0) AS spread,
      (t.via_counterparty_id IS NOT NULL) AS is_partner
    FROM transfers t
    WHERE (p_branch_id IS NULL OR t.from_branch_id = p_branch_id)
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
      AND (NOT p_partner_only OR t.via_counterparty_id IS NOT NULL)
      -- Учитываем только переводы которые НЕ отменены/отказаны.
      AND t.status NOT IN ('cancelled', 'rejected')
  ),
  comm AS (
    SELECT
      c.transfer_id,
      c.currency,
      SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id, c.currency
  )
  SELECT
    b.branch_id,
    b.currency,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount) AS total_volume,
    SUM(b.spread) AS spread_profit,
    COALESCE(SUM(
      (SELECT commission_total FROM comm WHERE comm.transfer_id = b.id AND comm.currency = b.currency)
    ), 0) AS commission_profit,
    bool_or(b.is_partner) AS is_partner
  FROM base b
  GROUP BY b.branch_id, b.currency
  ORDER BY total_volume DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION public.transfer_profit_summary(
  p_branch_id     uuid DEFAULT NULL,
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT false
) RETURNS TABLE (
  branch_id uuid,
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  is_partner boolean
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.transfer_profit_summary(p_branch_id, p_start, p_end, p_partner_only);
$$;

GRANT EXECUTE ON FUNCTION public.transfer_profit_summary(
  uuid, timestamptz, timestamptz, boolean
) TO authenticated;


-- ─── 6. partner_profit_top_partners ───────────────────────────
-- Топ-N партнёров по объёму или прибыли — для общей аналитики.
CREATE OR REPLACE FUNCTION private.partner_profit_top_partners(
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL,
  p_limit int DEFAULT 5
) RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  transfer_count bigint,
  total_volume_usd_proxy double precision,    -- грубая нормировка через avg buy_rate
  total_spread_proxy double precision,
  total_commission_proxy double precision
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  -- Дисклеймер: USD-нормировка приближённая, потому что курсы
  -- в transfers могут быть в разных шкалах. Берём buy_rate если есть,
  -- иначе 1. Это для рейтинга «крупные / мелкие», не для бухгалтерии.
  WITH base AS (
    SELECT
      t.id,
      t.via_counterparty_id,
      t.amount,
      t.currency,
      COALESCE(t.spread_profit, 0) AS spread,
      CASE
        WHEN t.buy_rate IS NULL OR t.buy_rate = 0 THEN t.amount
        ELSE t.amount / t.buy_rate
      END AS amount_norm
    FROM transfers t
    WHERE t.via_counterparty_id IS NOT NULL
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
      AND t.status NOT IN ('cancelled', 'rejected')
  ),
  comm AS (
    SELECT c.transfer_id, SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id
  )
  SELECT
    b.via_counterparty_id AS counterparty_id,
    cp.name,
    cp.city,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount_norm) AS total_volume_usd_proxy,
    SUM(b.spread) AS total_spread_proxy,
    COALESCE(SUM(
      (SELECT commission_total FROM comm WHERE comm.transfer_id = b.id)
    ), 0) AS total_commission_proxy
  FROM base b
  JOIN counterparties cp ON cp.id = b.via_counterparty_id
  GROUP BY b.via_counterparty_id, cp.name, cp.city
  ORDER BY SUM(b.amount_norm) DESC NULLS LAST
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION public.partner_profit_top_partners(
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL,
  p_limit int DEFAULT 5
) RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  transfer_count bigint,
  total_volume_usd_proxy double precision,
  total_spread_proxy double precision,
  total_commission_proxy double precision
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_top_partners(p_start, p_end, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_top_partners(
  timestamptz, timestamptz, int
) TO authenticated;

COMMIT;
