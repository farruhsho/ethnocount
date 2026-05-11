-- ============================================================
-- 017: Client wallet currency conversion
-- ============================================================
-- Атомарно списывает сумму с одного кошелька клиента и зачисляет
-- эквивалент на другой кошелёк по указанному курсу. Создаёт два
-- ClientTransaction (debit + deposit) с общим conversion_id и видом
-- описания «Конвертация USD → RUB · 1 USD = 92.50 RUB».
--
-- Курс — это «сколько единиц to за 1 from» (multiplier from→to).
-- Зачисление = списание × rate, округлённое до 2 знаков.
-- ============================================================

-- 1. extend client_transactions ---------------------------------
ALTER TABLE public.client_transactions
  ADD COLUMN IF NOT EXISTS conversion_id uuid;

ALTER TABLE public.client_transactions
  ADD COLUMN IF NOT EXISTS conversion_meta jsonb;

CREATE INDEX IF NOT EXISTS idx_client_transactions_conversion
  ON public.client_transactions (conversion_id) WHERE conversion_id IS NOT NULL;

COMMENT ON COLUMN public.client_transactions.conversion_id IS
  'Группирует две связанные проводки конвертации (debit + deposit одного клиента).';
COMMENT ON COLUMN public.client_transactions.conversion_meta IS
  'JSON с from/to/rate для UI: {"from":"USD","to":"RUB","rate":92.5,"counterAmount":...}';

-- 2. private.convert_client_currency ----------------------------

CREATE OR REPLACE FUNCTION private.convert_client_currency(
  p_client_id uuid,
  p_from_currency text,
  p_to_currency text,
  p_amount double precision,
  p_rate double precision,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_client clients%ROWTYPE;
  v_from text;
  v_to text;
  v_balances jsonb;
  v_from_bal double precision;
  v_to_bal double precision;
  v_received double precision;
  v_primary_bal double precision;
  v_conv_id uuid := gen_random_uuid();
  v_meta jsonb;
  v_debit_code text;
  v_deposit_code text;
  v_desc_debit text;
  v_desc_deposit text;
  v_balance_after_from double precision;
  v_balance_after_to double precision;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive'; END IF;
  IF p_rate <= 0 THEN RAISE EXCEPTION 'Rate must be positive'; END IF;

  v_from := upper(trim(p_from_currency));
  v_to := upper(trim(p_to_currency));
  IF v_from = '' OR v_to = '' THEN
    RAISE EXCEPTION 'Both currencies are required';
  END IF;
  IF v_from = v_to THEN
    RAISE EXCEPTION 'Source and target currencies must differ';
  END IF;

  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Client not found'; END IF;
  IF NOT v_client.is_active THEN RAISE EXCEPTION 'Client account is inactive'; END IF;

  SELECT balances INTO v_balances
  FROM client_balances
  WHERE client_id = p_client_id
  FOR UPDATE;

  IF v_balances IS NULL THEN v_balances := '{}'::jsonb; END IF;

  v_from_bal := COALESCE((v_balances->>v_from)::double precision, 0);
  v_to_bal := COALESCE((v_balances->>v_to)::double precision, 0);

  IF v_from_bal < p_amount THEN
    RAISE EXCEPTION 'Insufficient client balance in %: % available, % required',
      v_from, v_from_bal, p_amount;
  END IF;

  v_received := round((p_amount * p_rate)::numeric, 2);
  v_balance_after_from := round((v_from_bal - p_amount)::numeric, 2);
  v_balance_after_to := round((v_to_bal + v_received)::numeric, 2);

  v_balances := v_balances
    || jsonb_build_object(v_from, v_balance_after_from)
    || jsonb_build_object(v_to, v_balance_after_to);

  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  UPDATE client_balances SET
    balances = v_balances,
    balance = round(v_primary_bal::numeric, 2),
    updated_at = now()
  WHERE client_id = p_client_id;

  -- Авто-добавляем валюту в wallet_currencies, если её там не было.
  UPDATE clients
    SET wallet_currencies = array_append(wallet_currencies, v_to)
    WHERE id = p_client_id AND NOT (v_to = ANY(wallet_currencies));

  v_meta := jsonb_build_object(
    'conversionId', v_conv_id,
    'from', v_from,
    'to', v_to,
    'rate', p_rate,
    'fromAmount', round(p_amount::numeric, 2),
    'toAmount', v_received
  );

  v_debit_code := private.next_transaction_code('ETH-TX', 'transactionCodes');
  v_deposit_code := private.next_transaction_code('ETH-TX', 'transactionCodes');

  v_desc_debit := COALESCE(NULLIF(trim(p_description), ''),
    format('Конвертация %s → %s · 1 %s = %s %s', v_from, v_to, v_from, p_rate::text, v_to));
  v_desc_deposit := COALESCE(NULLIF(trim(p_description), ''),
    format('Конвертация %s → %s · 1 %s = %s %s', v_from, v_to, v_from, p_rate::text, v_to));

  -- debit leg (списание исходной валюты)
  INSERT INTO client_transactions (
    client_id, transaction_code, type, amount, currency, balance_after,
    description, created_by, conversion_id, conversion_meta
  ) VALUES (
    p_client_id, v_debit_code, 'debit', round(p_amount::numeric, 2), v_from,
    v_balance_after_from, v_desc_debit, v_user_id, v_conv_id, v_meta
  );

  -- deposit leg (зачисление целевой валюты)
  INSERT INTO client_transactions (
    client_id, transaction_code, type, amount, currency, balance_after,
    description, created_by, conversion_id, conversion_meta
  ) VALUES (
    p_client_id, v_deposit_code, 'deposit', v_received, v_to,
    v_balance_after_to, v_desc_deposit, v_user_id, v_conv_id, v_meta
  );

  RETURN jsonb_build_object(
    'success', true,
    'conversionId', v_conv_id,
    'fromAmount', round(p_amount::numeric, 2),
    'toAmount', v_received,
    'rate', p_rate
  );
END;
$$;

-- 3. public wrapper ---------------------------------------------

CREATE OR REPLACE FUNCTION public.convert_client_currency(
  p_client_id uuid,
  p_from_currency text,
  p_to_currency text,
  p_amount double precision,
  p_rate double precision,
  p_description text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER
SET search_path = public, pg_temp
AS $$ SELECT private.convert_client_currency(
  p_client_id, p_from_currency, p_to_currency, p_amount, p_rate, p_description
) $$;

GRANT EXECUTE ON FUNCTION public.convert_client_currency(uuid, text, text, double precision, double precision, text) TO authenticated;
