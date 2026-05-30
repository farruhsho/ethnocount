-- ============================================================
-- 034: Partner transfer — cross-currency + archive + search
-- ============================================================
-- Эта миграция закрывает 3 пробела из 033:
--
--   1) create_partner_transfer не поддерживал cross-currency:
--      «1000 USD → выплата в UZS по курсу 12780» было невозможно.
--      Добавляем p_to_currency + p_exchange_rate. Логика расчёта
--      получаемой суммы — как в обычной create_transfer (032):
--        debit основного счёта  = p_amount [в p_currency]
--        converted_amount       = p_amount * p_exchange_rate
--                                 [в p_to_currency]
--      Saldo партнёра по-прежнему уходит в МИНУС на p_amount в нашей
--      валюте (мы дали ему НАШИХ денег — он должен нам в этой валюте).
--      В counterparty_transactions сохраняем exchange_rate, чтобы
--      потом можно было сводить выплаты к валюте payout-а.
--
--   2) Архивация партнёров — пока только через прямой UPDATE в БД.
--      Добавляем set_counterparty_active(uuid, bool) — единственная
--      операция, которую можно делать с активным/неактивным партнёром.
--      Только creator/director может архивировать; accountant — нет
--      (иначе бухгалтер может «потерять» партнёра у других филиалов).
--
--   3) Список партнёров: добавляем search_counterparties с одним
--      запросом, который сразу отдаёт name+city+saldo_by_currency+
--      tx_count+last_op_at+is_active. На клиенте делать ilike-фильтр
--      по name/city тоже можно, но этот RPC даёт расширенные данные
--      (для сортировки по last_op_at).
--
-- Идемпотентно — CREATE OR REPLACE, безопасно повторно применять.
-- ============================================================

BEGIN;

-- ─── 1. create_partner_transfer: cross-currency ─────────────────
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
  p_exchange_rate         double precision DEFAULT 1
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
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;

  -- Партнёр обязателен и должен быть активен.
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

  -- Cross-currency: если to_currency не указана — выплата в той же валюте.
  v_to_currency := COALESCE(NULLIF(trim(p_to_currency), ''), p_currency);
  v_rate := COALESCE(p_exchange_rate, 1);
  IF v_rate <= 0 THEN
    RAISE EXCEPTION 'Курс обмена должен быть больше нуля (получен: %)', v_rate;
  END IF;
  -- Same currency → rate 1, защищаемся от ввода вроде 12780 для USD→USD.
  IF v_to_currency = p_currency AND v_rate <> 1 THEN
    v_rate := 1;
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
  v_converted := p_amount * v_rate;

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

  -- Партнёр стал нам должен на сумму выплаты В НАШЕЙ ВАЛЮТЕ.
  -- exchange_rate сохраняем — чтобы можно было свести выплаты к валюте
  -- получателя в отчёте «сколько вы выплатили клиентам через партнёра».
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
    p_exchange_rate   := CASE WHEN v_to_currency = p_currency THEN NULL ELSE v_rate END
  );

  RETURN jsonb_build_object(
    'success', true,
    'transferId', v_transfer_id::text,
    'transactionCode', v_code,
    'partnerId', p_counterparty_id::text,
    'convertedAmount', v_converted,
    'toCurrency', v_to_currency
  );
END;
$$;

-- Drop старая узкая сигнатура (она была без p_to_currency / p_exchange_rate).
DROP FUNCTION IF EXISTS public.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text);

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
  p_exchange_rate         double precision DEFAULT 1
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
    p_to_currency, p_exchange_rate
  );
$$;

GRANT EXECUTE ON FUNCTION public.create_partner_transfer(
  uuid, uuid, uuid, double precision, text, text,
  text, double precision, text, text, uuid, text, text, text,
  text, text, text, text, text, text, text, double precision
) TO authenticated;

-- ─── 2. Архивация партнёров ────────────────────────────────────
-- Toggle is_active. Только creator/director — иначе бухгалтер может
-- скрыть партнёра у других филиалов.
CREATE OR REPLACE FUNCTION private.set_counterparty_active(
  p_counterparty_id uuid,
  p_active boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role NOT IN ('creator', 'director') THEN
    RAISE EXCEPTION 'Только Creator/Director может архивировать партнёров';
  END IF;

  UPDATE counterparties
     SET is_active = p_active
   WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;

  RETURN jsonb_build_object('success', true, 'isActive', p_active);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_counterparty_active(
  p_counterparty_id uuid,
  p_active boolean
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.set_counterparty_active(p_counterparty_id, p_active);
$$;

GRANT EXECUTE ON FUNCTION public.set_counterparty_active(uuid, boolean)
  TO authenticated;


-- ─── 3. Расширенный список партнёров с агрегатами ─────────────
-- Возвращает партнёров + last_op_at + tx_count + saldo_by_currency,
-- чтобы клиент мог сортировать по «активности» / «нам должны» / «мы
-- должны».
CREATE OR REPLACE FUNCTION private.counterparties_list(
  p_include_archived boolean DEFAULT false
) RETURNS TABLE (
  id uuid,
  name text,
  city text,
  phone text,
  notes text,
  saldo_by_currency jsonb,
  is_active boolean,
  home_branch_id uuid,
  fee_percentage double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cp.id,
    cp.name,
    cp.city,
    cp.phone,
    cp.notes,
    cp.saldo_by_currency,
    cp.is_active,
    cp.home_branch_id,
    cp.fee_percentage,
    COALESCE(t.tx_count, 0) AS tx_count,
    t.last_op_at
  FROM counterparties cp
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS tx_count,
           MAX(created_at) AS last_op_at
    FROM counterparty_transactions
    WHERE counterparty_id = cp.id
  ) t ON true
  WHERE p_include_archived OR cp.is_active
  ORDER BY cp.name;
$$;

CREATE OR REPLACE FUNCTION public.counterparties_list(
  p_include_archived boolean DEFAULT false
) RETURNS TABLE (
  id uuid,
  name text,
  city text,
  phone text,
  notes text,
  saldo_by_currency jsonb,
  is_active boolean,
  home_branch_id uuid,
  fee_percentage double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparties_list(p_include_archived);
$$;

GRANT EXECUTE ON FUNCTION public.counterparties_list(boolean) TO authenticated;


-- ─── 4. Список городов из существующих партнёров ──────────────
-- Для автокомплита поля «Город» при создании. Включает count, чтобы
-- сортировать «по частоте использования».
CREATE OR REPLACE FUNCTION private.counterparty_cities()
RETURNS TABLE (city text, usage_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT city, COUNT(*) AS usage_count
  FROM counterparties
  WHERE city IS NOT NULL AND length(trim(city)) > 0
  GROUP BY city
  ORDER BY usage_count DESC, city ASC;
$$;

CREATE OR REPLACE FUNCTION public.counterparty_cities()
RETURNS TABLE (city text, usage_count bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT * FROM private.counterparty_cities(); $$;

GRANT EXECUTE ON FUNCTION public.counterparty_cities() TO authenticated;


-- ─── 5. Защита: phone-нормализация при INSERT/UPDATE ──────────
-- На UI добавим formatter (+ автоформат по странам). На БД-стороне
-- страхуемся: убираем всё кроме цифр и '+', сохраняем как E.164
-- ('+' + digits, без пробелов). Иначе search по части номера в
-- transfers/contacts будет рассинхронизирован.
CREATE OR REPLACE FUNCTION private.normalize_phone(p_raw text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_clean text;
BEGIN
  IF p_raw IS NULL THEN RETURN NULL; END IF;
  v_clean := regexp_replace(p_raw, '[^0-9+]', '', 'g');
  -- Если плюса нет, но цифр достаточно — добавляем (предполагаем что
  -- пользователь ввёл без него). Если меньше 5 цифр — оставляем «как
  -- есть» (мусор всё равно поймает валидатор).
  IF v_clean !~ '^\+' AND length(regexp_replace(v_clean, '[^0-9]', '', 'g')) >= 5 THEN
    v_clean := '+' || v_clean;
  END IF;
  RETURN NULLIF(v_clean, '');
END;
$$;

CREATE OR REPLACE FUNCTION private.tg_counterparties_normalize_phone()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.phone IS DISTINCT FROM COALESCE(OLD.phone, '') THEN
    NEW.phone := private.normalize_phone(NEW.phone);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS counterparties_normalize_phone ON public.counterparties;
CREATE TRIGGER counterparties_normalize_phone
  BEFORE INSERT OR UPDATE OF phone ON public.counterparties
  FOR EACH ROW EXECUTE FUNCTION private.tg_counterparties_normalize_phone();

COMMIT;
