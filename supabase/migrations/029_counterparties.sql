-- ============================================================
-- 029: Контрагенты (внешние посредники) и взаиморасчёты
-- ============================================================
-- Контрагент — лицо в другом городе, через которого мы выплачиваем
-- клиентов или которое выплачивает клиентов за нас. Saldo по валютам:
--   saldo > 0 — он должен нам;
--   saldo < 0 — мы должны ему.
--
-- Операции:
--   paid_for_us       — он выплатил нашему клиенту   → saldo -= amount
--   we_paid_for_them  — мы выплатили его клиенту    → saldo += amount
--   settle_to_us      — он принёс нам наличные      → saldo -= amount
--   settle_from_us    — мы отдали ему наличные      → saldo += amount
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.counterparties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  city text,
  phone text,
  notes text,
  saldo_by_currency jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_counterparties_name
  ON public.counterparties (name);

CREATE TABLE IF NOT EXISTS public.counterparty_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  counterparty_id uuid NOT NULL
    REFERENCES public.counterparties(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN (
    'paid_for_us', 'we_paid_for_them',
    'settle_to_us', 'settle_from_us'
  )),
  amount double precision NOT NULL CHECK (amount > 0),
  currency text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_counterparty_tx_counterparty
  ON public.counterparty_transactions (counterparty_id, created_at DESC);

ALTER TABLE public.counterparties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.counterparty_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS counterparties_select ON public.counterparties;
CREATE POLICY counterparties_select ON public.counterparties
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS counterparty_tx_select ON public.counterparty_transactions;
CREATE POLICY counterparty_tx_select ON public.counterparty_transactions
  FOR SELECT TO authenticated USING (true);

-- Создание контрагента (только creator/director).
-- ВАЖНО: дропаем все возможные overload-варианты этой функции перед
-- созданием. Иначе при повторном применении (например после 033, который
-- расширил сигнатуру до 6 параметров) PG не сможет однозначно разрешить
-- public.create_counterparty(text,text,text,text) → private.create_counterparty:
-- обе версии подходят через DEFAULT. Ошибка: «function ... is not unique».
DROP FUNCTION IF EXISTS private.create_counterparty(text, text, text, text);
DROP FUNCTION IF EXISTS private.create_counterparty(text, text, text, text, uuid, double precision);
DROP FUNCTION IF EXISTS public.create_counterparty(text, text, text, text);
DROP FUNCTION IF EXISTS public.create_counterparty(text, text, text, text, uuid, double precision);

CREATE OR REPLACE FUNCTION private.create_counterparty(
  p_name text,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role NOT IN ('creator', 'director') THEN
    RAISE EXCEPTION 'Только Creator/Director может создавать контрагентов';
  END IF;
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Имя контрагента обязательно';
  END IF;

  INSERT INTO counterparties (name, city, phone, notes, created_by)
  VALUES (trim(p_name), NULLIF(trim(p_city), ''), NULLIF(trim(p_phone), ''),
          NULLIF(trim(p_notes), ''), v_uid)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'counterpartyId', v_id::text);
END;
$$;

GRANT EXECUTE ON FUNCTION private.create_counterparty(text, text, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.create_counterparty(
  p_name text,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.create_counterparty(p_name, p_city, p_phone, p_notes) $$;

GRANT EXECUTE ON FUNCTION public.create_counterparty(text, text, text, text)
  TO authenticated;

-- Запись операции — сдвигает saldo и фиксирует tx.
-- Аналогично create_counterparty: дропаем все варианты record_counterparty_op
-- (5 → 9 → 12 параметров в 029/033/040), чтобы избежать ambiguous overload.
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text);
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision);
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision,
  double precision, text, double precision);
DROP FUNCTION IF EXISTS public.record_counterparty_op(
  uuid, text, double precision, text, text);
DROP FUNCTION IF EXISTS public.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision);
DROP FUNCTION IF EXISTS public.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision,
  double precision, text, double precision);

CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL
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
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Контрагент не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Контрагент деактивирован'; END IF;

  v_cur := upper(trim(p_currency));
  IF v_cur = '' THEN RAISE EXCEPTION 'Валюта обязательна'; END IF;

  v_delta := CASE p_kind
    WHEN 'paid_for_us'      THEN -p_amount   -- он выплатил, мы должны больше → saldo вниз
    WHEN 'we_paid_for_them' THEN  p_amount   -- мы выплатили за него → saldo вверх
    WHEN 'settle_to_us'     THEN -p_amount   -- он принёс кэш → saldo вниз
    WHEN 'settle_from_us'   THEN  p_amount   -- мы отдали кэш → saldo вверх
    ELSE NULL
  END;
  IF v_delta IS NULL THEN
    RAISE EXCEPTION 'Неизвестный тип операции: %', p_kind;
  END IF;

  v_curr_saldo := COALESCE(
    (v_cp.saldo_by_currency->>v_cur)::double precision, 0);
  v_new_saldo := v_curr_saldo + v_delta;

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

  INSERT INTO counterparty_transactions
    (counterparty_id, kind, amount, currency, description, created_by)
  VALUES
    (p_counterparty_id, p_kind, p_amount, v_cur,
     NULLIF(trim(p_description), ''), v_uid);

  RETURN jsonb_build_object('success', true, 'newSaldo', v_new_saldo);
END;
$$;

GRANT EXECUTE ON FUNCTION private.record_counterparty_op(
  uuid, text, double precision, text, text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.record_counterparty_op(
    p_counterparty_id, p_kind, p_amount, p_currency, p_description
  );
$$;

GRANT EXECUTE ON FUNCTION public.record_counterparty_op(
  uuid, text, double precision, text, text
) TO authenticated;

COMMIT;
