-- ============================================================
-- 053: sanity caps on client deposit/debit/balance values
-- ============================================================
-- Сценарий который сломал прод: пользователь ввёл сумму депозита
-- в большом количестве цифр (или scientific notation) — на бэкенд
-- ушло amount=1e+61. Транзакция прошла, balances[USD] стало 1e+61.
-- В UI `_DesktopWalletRow.toStringAsFixed(2)` отрендерил 62-символьную
-- строку, layout рухнул, операторам показалось «клиентский счёт не
-- показывает» — на самом деле его вытеснило за viewport.
--
-- Защита в двух слоях (на случай если фронт-валидация обойдена):
--   1. CHECK constraint на client_transactions.amount: 0 < amount <= 1e12
--      и не NaN.
--   2. BEFORE-trigger на client_balances валидирует значения jsonb
--      `balances` тем же диапазоном.
--
-- 1 трлн как потолок выбран эмпирически: реальные операции в UZS
-- редко превышают 1 миллиард сум, USDT/USD — миллион. 1e12 даёт
-- ~3 порядка запаса.
--
-- Идемпотентно. DROP IF EXISTS + CREATE.
-- ============================================================

BEGIN;

-- ─── 1. CHECK на client_transactions.amount ─────────────────
ALTER TABLE public.client_transactions
  DROP CONSTRAINT IF EXISTS client_transactions_amount_sanity;

ALTER TABLE public.client_transactions
  ADD CONSTRAINT client_transactions_amount_sanity
  CHECK (
    amount IS NULL
    OR (amount = amount AND amount > 0 AND amount <= 1e12)
  );

-- ─── 2. Helper для использования из RPC (если захотим явный raise) ─
CREATE OR REPLACE FUNCTION private._validate_client_amount(p_amount double precision)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше 0';
  END IF;
  IF NOT (p_amount = p_amount) THEN
    RAISE EXCEPTION 'Сумма не является числом';
  END IF;
  IF p_amount > 1e12 THEN
    RAISE EXCEPTION 'Слишком большая сумма (%). Максимум: 1 000 000 000 000.', p_amount;
  END IF;
END;
$$;

-- ─── 3. Trigger на client_balances.balances jsonb ────────────
CREATE OR REPLACE FUNCTION private.validate_client_balances_jsonb()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  kv RECORD;
  v double precision;
BEGIN
  IF NEW.balances IS NULL THEN RETURN NEW; END IF;
  FOR kv IN SELECT * FROM jsonb_each_text(NEW.balances) LOOP
    BEGIN
      v := kv.value::double precision;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Некорректное значение в balances[%]: %', kv.key, kv.value;
    END;
    IF NOT (v = v) THEN
      RAISE EXCEPTION 'NaN в balances[%]', kv.key;
    END IF;
    IF v > 1e12 OR v < -1e12 THEN
      RAISE EXCEPTION 'balances[%] = % за пределами (-1e12, 1e12). Скорее всего ошибка ввода.', kv.key, v;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_client_balances_jsonb_trg ON public.client_balances;
CREATE TRIGGER validate_client_balances_jsonb_trg
  BEFORE INSERT OR UPDATE OF balances ON public.client_balances
  FOR EACH ROW EXECUTE FUNCTION private.validate_client_balances_jsonb();

COMMIT;
