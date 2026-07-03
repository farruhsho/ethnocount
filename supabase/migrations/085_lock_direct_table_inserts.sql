-- ============================================================
-- 085: Запрет прямых REST-вставок мимо RPC (курсы + журнал клиента)
-- ============================================================
-- Дополняет 083/084. Гейт в RPC ничего не стоит, если ту же таблицу можно
-- писать напрямую через PostgREST в обход RPC. Найдены две такие дыры:
--
--  (A) rates_insert (001:471) = WITH CHECK (true) — ЛЮБОЙ authenticated
--      может POST /rest/v1/exchange_rates и вписать произвольный курс,
--      минуя private.set_exchange_rate (и его ролевой гейт + санити из 084).
--      Курс определяет сумму получателю по всем переводам → это тот же
--      класс, что и 084, но на уровне таблицы.
--
--  (B) client_tx_insert (001:466) = get_user_role() IN ('creator',
--      'accountant') — бухгалтер может POST /rest/v1/client_transactions
--      напрямую, мимо deposit_client/debit_client/convert_client_currency.
--      BEFORE-триггер 067 валидирует лишь филиал, но НЕ сумму/достаточность
--      и НЕ парность с client_balances → фантомные строки журнала,
--      расхождение журнал/баланс, искажение истории и отчётов.
--
-- РЕШЕНИЕ: обе политики INSERT сужаем до creator/director
-- (private.is_creator_or_director()) — как аварийный прямой доступ. Штатный
-- путь для бухгалтера — SECURITY DEFINER RPC, которые исполняются под
-- владельцем и RLS обходят, поэтому НЕ ломаются:
--   • set_exchange_rate (084: гейт canExchangeRates + санити) — курсы;
--   • deposit/debit/convert_client_currency — журнал клиента.
-- Dart-клиент ни в exchange_rates, ни в client_transactions напрямую НЕ
-- пишет (exchange_rate_remote_ds.dart:75 — только rpc; в client_transactions
-- только .select()). Значит сужение прозрачно для приложения.
--
-- Идемпотентно: DROP POLICY IF EXISTS + CREATE.
-- ============================================================

BEGIN;

-- ── (A) exchange_rates: прямая вставка только creator/director ──
DROP POLICY IF EXISTS "rates_insert" ON public.exchange_rates;
CREATE POLICY "rates_insert" ON public.exchange_rates FOR INSERT TO authenticated
  WITH CHECK (private.is_creator_or_director());

-- ── (B) client_transactions: прямая вставка только creator/director ──
DROP POLICY IF EXISTS "client_tx_insert" ON public.client_transactions;
CREATE POLICY "client_tx_insert" ON public.client_transactions FOR INSERT TO authenticated
  WITH CHECK (private.is_creator_or_director());

COMMIT;
