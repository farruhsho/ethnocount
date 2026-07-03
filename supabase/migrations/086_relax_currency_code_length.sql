-- ============================================================
-- 086: validate_currency_codes — разрешить 3-4 буквенные коды (USDT)
-- ============================================================
-- ПРОБЛЕМА (F14, ре-аудит 07.2026): validate_currency_codes (016:25)
-- требует ровно 3-буквенные ISO-коды (length(e) <> 3) → 'USDT' (4 буквы)
-- отвергается CHECK-констрейнтом branches_supported_currencies_valid, хотя
-- UITX предлагает USDT в пикере supported_currencies и как базовую валюту
-- филиала (branches_page.dart). Создание/правка филиала с USDT падает.
--
-- РЕШЕНИЕ: разрешить длину 3-4 (покрывает USDT и будущие крипто-коды),
-- регистр по-прежнему только upper. CREATE OR REPLACE IMMUTABLE-функции —
-- существующий CHECK-констрейнт автоматически подхватит новую версию;
-- существующие строки Postgres не перепроверяет (риска на apply нет).
-- Идемпотентно.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.validate_currency_codes(p jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p IS NULL OR (
    jsonb_typeof(p) = 'array'
    AND jsonb_array_length(p) > 0
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(p) e
      WHERE length(e) NOT BETWEEN 3 AND 4 OR e <> upper(e)
    )
  )
$$;

COMMIT;
