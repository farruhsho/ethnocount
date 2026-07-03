-- ============================================================
-- 083: client_balances — прямая запись только creator/director
-- ============================================================
-- ПРОБЛЕМА (ре-аудит 07.2026, MEDIUM): политика client_balances_all
-- (068:54, FOR ALL) с WITH CHECK по филиалу разрешает БУХГАЛТЕРУ писать
-- в public.client_balances напрямую через PostgREST — мимо RPC
-- deposit_client / debit_client / convert_client_currency. BEFORE-триггер
-- 053 валидирует только jsonb (капы/NaN), но НЕ требует парной строки в
-- client_transactions и НЕ проверяет достаточность средств. Значит баланс
-- кошелька можно раздуть/обнулить без единой записи в журнале, а
-- reconciliation (080) клиентский слой не сверяет → фантомные деньги без
-- следа.
--
-- РЕШЕНИЕ: сузить client_balances_all до creator/director. Это НЕ ломает
-- приложение:
--   • deposit/debit/convert — SECURITY DEFINER RPC, выполняются под
--     владельцем и RLS обходят (запись балансов продолжает работать);
--   • Dart-клиент в client_balances только ЧИТАЕТ (client_remote_ds.dart:
--     97/134 — .select()), прямых INSERT/UPDATE нет;
--   • branch-scoped ЧТЕНИЕ бухгалтером остаётся через отдельную политику
--     client_balances_select (068:42), которую мы не трогаем.
-- Итог: единственный путь изменения баланса для бухгалтера — RPC (журнал +
-- проверки), а прямая ручная правка таблицы остаётся только у creator/
-- director (аварийный доступ).
--
-- Идемпотентно: DROP POLICY IF EXISTS + CREATE.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "client_balances_all" ON public.client_balances;
CREATE POLICY "client_balances_all" ON public.client_balances FOR ALL TO authenticated
  USING (private.is_creator_or_director())
  WITH CHECK (private.is_creator_or_director());

COMMIT;
