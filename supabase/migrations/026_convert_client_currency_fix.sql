-- ============================================================
-- 026: convert_client_currency — права + защита от nullable wallet_currencies
-- ============================================================
-- Симптом: «Обмен валюты в клиентском балансе выводит ошибку».
-- Корневые причины:
--   1) В 017 не было GRANT EXECUTE на private.convert_client_currency,
--      а public wrapper стоит как SECURITY INVOKER → у authenticated нет
--      прав войти в private-функцию. PostgreSQL отдаёт permission denied,
--      а Supabase-клиент видит просто PostgrestException.
--   2) UPDATE clients SET wallet_currencies = array_append(NULL, x) даёт
--      NULL → следующая конвертация падает на «cannot iterate over NULL».
-- ============================================================

BEGIN;

GRANT EXECUTE ON FUNCTION private.convert_client_currency(
  uuid, text, text, double precision, double precision, text
) TO authenticated;

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
    RAISE EXCEPTION 'Недостаточно средств в валюте %: на счёте %, требуется %',
      v_from, round(v_from_bal::numeric, 2), round(p_amount::numeric, 2);
  END IF;

  v_received := round((p_amount * p_rate)::numeric, 2);
  v_balance_after_from := round((v_from_bal - p_amount)::numeric, 2);
  v_balance_after_to := round((v_to_bal + v_received)::numeric, 2);

  v_balances := v_balances
    || jsonb_build_object(v_from, v_balance_after_from)
    || jsonb_build_object(v_to, v_balance_after_to);

  v_primary_bal := COALESCE((v_balances->>v_client.currency)::double precision, 0);

  -- Если для клиента ещё нет строки client_balances — создаём её здесь же,
  -- иначе UPDATE без WHERE-совпадения тихо ничего не сделает.
  INSERT INTO client_balances (client_id, balances, balance, currency, updated_at)
  VALUES (p_client_id, v_balances, round(v_primary_bal::numeric, 2),
          v_client.currency, now())
  ON CONFLICT (client_id) DO UPDATE SET
    balances    = v_balances,
    balance     = round(v_primary_bal::numeric, 2),
    updated_at  = now();

  -- Авто-добавляем валюту в wallet_currencies, обрабатывая NULL/пустой массив.
  UPDATE clients
    SET wallet_currencies = (
      CASE
        WHEN wallet_currencies IS NULL THEN ARRAY[v_to]
        WHEN v_to = ANY(wallet_currencies) THEN wallet_currencies
        ELSE array_append(wallet_currencies, v_to)
      END
    )
    WHERE id = p_client_id;

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
  v_desc_deposit := v_desc_debit;

  INSERT INTO client_transactions (
    client_id, transaction_code, type, amount, currency, balance_after,
    description, created_by, conversion_id, conversion_meta
  ) VALUES (
    p_client_id, v_debit_code, 'debit', round(p_amount::numeric, 2), v_from,
    v_balance_after_from, v_desc_debit, v_user_id, v_conv_id, v_meta
  );

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

-- Защитный grant на public wrapper тоже (мог сбиться при пересоздании).
GRANT EXECUTE ON FUNCTION public.convert_client_currency(
  uuid, text, text, double precision, double precision, text
) TO authenticated;

COMMIT;
