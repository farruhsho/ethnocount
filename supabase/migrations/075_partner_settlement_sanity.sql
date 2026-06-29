-- ============================================================
-- 075: Санити-проверки расчётов с партнёром (#12 + #13)
-- ============================================================
-- Базируется на теле record_counterparty_op из 058 (лимит
-- экспозиции). Сигнатура НЕ меняется → CREATE OR REPLACE,
-- public-обёртка и GRANT из 040 остаются в силе.
--
-- Проблема #12 (фальшивая прибыль из «толстого пальца»):
--   Кросс-валютный расчёт (settle_to_us / settle_from_us) брал
--   amount, closes_amount и expected_rate без проверки, что
--   фактический курс actual_rate = amount / closes_amount
--   адекватен. settlement_profit = (expected-actual)*close писался
--   напрямую, поэтому ошибка в курсе создавала фиктивную
--   прибыль/saldo, которую сверка (reconcile) не ловит.
--   Решение: серверная валидация — требуем amount>0 и
--   closes_amount>0; считаем actual_rate и ОТКЛОНЯЕМ (RAISE),
--   если относительное отклонение |actual-expected|/expected
--   превышает допуск RATE_TOLERANCE (= 0.05 = 5%).
--
-- Проблема #13 (обход лимита экспозиции через пере-расчёт):
--   Лимит проверялся только на росте |saldo| (paid_for_us /
--   we_paid_for_them). Чрезмерный расчёт (settle_*) мог
--   перевернуть знак saldo за лимит на противоположной стороне,
--   не задев проверку. Решение: ограничиваем АБСОЛЮТНОЕ итоговое
--   saldo (|new saldo| <= limit) в валюте расчёта и на settle_*,
--   но блокируем только когда операция УВЕЛИЧИВАЕТ |saldo|
--   (т.е. перелёт за ноль), — обычный расчёт, уменьшающий
--   позицию, не блокируется.
--
-- Идемпотентно: CREATE OR REPLACE, обёрнуто в BEGIN/COMMIT.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL::text,
  p_cash_account_id uuid DEFAULT NULL::uuid,
  p_transfer_id uuid DEFAULT NULL::uuid,
  p_payout_method text DEFAULT NULL::text,
  p_exchange_rate double precision DEFAULT NULL::double precision,
  p_close_amount double precision DEFAULT NULL::double precision,
  p_close_currency text DEFAULT NULL::text,
  p_expected_rate double precision DEFAULT NULL::double precision)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  -- #12: допуск на отклонение фактического курса от ожидаемого (5%)
  c_rate_tolerance constant double precision := 0.05;
  v_uid uuid := auth.uid();
  v_cp counterparties%ROWTYPE;
  v_cash_cur text;
  v_saldo_cur text;
  v_curr_saldo double precision;
  v_saldo_delta double precision;
  v_new_saldo double precision;
  v_acc branch_accounts%ROWTYPE;
  v_cash_delta double precision;
  v_acc_balance double precision;
  v_role text;
  v_close_amount double precision;
  v_settlement_profit double precision := 0;
  v_actual_rate double precision;
  v_rate_dev double precision;
  v_limit numeric;
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

  v_cash_cur := upper(trim(p_currency));
  IF v_cash_cur = '' THEN RAISE EXCEPTION 'Валюта обязательна'; END IF;

  v_saldo_cur := upper(COALESCE(NULLIF(trim(p_close_currency), ''), v_cash_cur));
  v_close_amount := COALESCE(p_close_amount, p_amount);
  IF v_close_amount <= 0 THEN
    RAISE EXCEPTION 'closes_amount должен быть > 0';
  END IF;

  v_saldo_delta := CASE p_kind
    WHEN 'paid_for_us'      THEN -v_close_amount
    WHEN 'we_paid_for_them' THEN  v_close_amount
    WHEN 'settle_to_us'     THEN -v_close_amount
    WHEN 'settle_from_us'   THEN  v_close_amount
    ELSE NULL
  END;
  IF v_saldo_delta IS NULL THEN
    RAISE EXCEPTION 'Неизвестный тип операции: %', p_kind;
  END IF;

  IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
    IF p_cash_account_id IS NULL THEN
      RAISE EXCEPTION
        'Для расчёта (settle) обязательно укажите кеш-счёт нашего филиала';
    END IF;
    SELECT * INTO v_acc FROM branch_accounts WHERE id = p_cash_account_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Кеш-счёт не найден'; END IF;
    IF upper(v_acc.currency) <> v_cash_cur THEN
      RAISE EXCEPTION
        'Валюта расчёта (%) не совпадает с валютой выбранного счёта (%)',
        v_cash_cur, v_acc.currency;
    END IF;

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
    VALUES (p_cash_account_id, v_acc.branch_id, round(v_cash_delta::numeric, 4), v_acc.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = round((account_balances.balance + v_cash_delta)::numeric, 4),
          updated_at = now();

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
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
           ELSE 'Расчёт партнёру ' || v_cp.name
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
      END,
      v_uid
    );

    IF v_saldo_cur <> v_cash_cur AND p_expected_rate IS NOT NULL
       AND p_expected_rate > 0 AND v_close_amount > 0 THEN
      -- ── #12: санити фактического курса перед расчётом прибыли ──
      -- amount и closes_amount уже проверены на > 0 выше; считаем
      -- фактический курс и отклоняем «толстый палец» по допуску.
      IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Сумма расчёта (amount) должна быть > 0';
      END IF;
      v_actual_rate := p_amount / v_close_amount;
      v_rate_dev := abs(v_actual_rate - p_expected_rate)
                    / NULLIF(p_expected_rate, 0);
      IF v_rate_dev IS NULL OR v_rate_dev > c_rate_tolerance THEN
        RAISE EXCEPTION
          'Курс расчёта вне допуска: фактический % vs ожидаемый % (отклонение %%, допуск %%). Проверьте сумму/курс.',
          round(v_actual_rate::numeric, 6),
          round(p_expected_rate::numeric, 6),
          round((COALESCE(v_rate_dev, 1) * 100)::numeric, 2),
          round((c_rate_tolerance * 100)::numeric, 2);
      END IF;

      v_settlement_profit := CASE p_kind
        WHEN 'settle_from_us' THEN (p_expected_rate - v_actual_rate) * v_close_amount
        WHEN 'settle_to_us'   THEN (v_actual_rate - p_expected_rate) * v_close_amount
        ELSE 0
      END;
    END IF;
  END IF;

  v_settlement_profit := round(COALESCE(v_settlement_profit, 0)::numeric, 4);

  v_curr_saldo := round(COALESCE(
    (v_cp.saldo_by_currency->>v_saldo_cur)::double precision, 0)::numeric, 4);
  v_new_saldo := round((v_curr_saldo + v_saldo_delta)::numeric, 4);

  -- ── F5 + #13: лимит экспозиции (АБСОЛЮТНОЕ итоговое saldo) ──
  -- Лимит ограничивает |saldo| в валюте позиции. Блокируем любую
  -- операцию, которая УВЕЛИЧИВАЕТ |saldo| сверх лимита:
  --   • рост долга (paid_for_us / we_paid_for_them);
  --   • чрезмерный расчёт (settle_*), переворачивающий знак за
  --     ноль так, что |new| > |curr| и > лимита (#13). Обычный
  --     расчёт, уменьшающий позицию, не блокируется.
  v_limit := NULLIF(v_cp.exposure_limit_by_currency->>v_saldo_cur, '')::numeric;
  IF v_limit IS NOT NULL AND v_limit > 0
     AND abs(v_new_saldo) > v_limit + 1e-6
     AND abs(v_new_saldo) > abs(v_curr_saldo) + 1e-6 THEN
    IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
      RAISE EXCEPTION
        'Расчёт перевернул бы позицию по партнёру «%» в % за лимит: лимит %, позиция станет % (перерасчёт). Уменьшите сумму расчёта.',
        v_cp.name, v_saldo_cur, round(v_limit, 2), round(v_new_saldo::numeric, 2);
    ELSE
      RAISE EXCEPTION
        'Превышен лимит экспозиции по партнёру «%» в %: лимит %, позиция станет %. Сначала проведите расчёт.',
        v_cp.name, v_saldo_cur, round(v_limit, 2), round(abs(v_new_saldo)::numeric, 2);
    END IF;
  END IF;

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_saldo_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

  INSERT INTO counterparty_transactions
    (counterparty_id, kind, amount, currency, description, created_by,
     transfer_id, cash_account_id, payout_method, exchange_rate,
     closes_amount, closes_currency, expected_rate,
     settlement_profit, settlement_profit_currency)
  VALUES
    (p_counterparty_id, p_kind, p_amount, v_cash_cur,
     NULLIF(trim(p_description), ''), v_uid,
     p_transfer_id, p_cash_account_id,
     NULLIF(trim(p_payout_method), ''), p_exchange_rate,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_close_amount ELSE NULL END,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_saldo_cur ELSE NULL END,
     p_expected_rate,
     NULLIF(v_settlement_profit, 0),
     CASE WHEN v_settlement_profit <> 0 THEN v_cash_cur ELSE NULL END);

  RETURN jsonb_build_object(
    'success', true,
    'newSaldo', v_new_saldo,
    'saldoCurrency', v_saldo_cur,
    'settlementProfit', v_settlement_profit,
    'settlementProfitCurrency', v_cash_cur
  );
END;
$fn$;

COMMIT;
