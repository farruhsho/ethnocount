-- ============================================================
-- 068: Branch-scoping RLS на клиентов, балансы и транзакции
-- ============================================================
-- Закрывает CRITICAL/HIGH S1 форензик-аудита (06.2026): SELECT-политики
-- clients_select / client_balances_select / client_tx_select объявлены как
-- USING(true) — любой авторизованный бухгалтер читал ПЕРСОНАЛЬНЫЕ данные
-- (имена, телефоны), балансы и всю историю транзакций клиентов ВСЕХ филиалов.
-- Дополнительно client_balances_all (FOR ALL, role IN creator/accountant)
-- тоже даёт SELECT по всем балансам — его тоже нужно сузить, иначе он
-- перекрывает (OR) ограниченную select-политику и дыра остаётся открытой.
--
-- Модель (как для transfers/branch_accounts): creator/director видят всё;
-- accountant — только клиентов своих назначенных филиалов (user_branches()).
-- client_balances/client_transactions не имеют своей колонки branch_id —
-- скоупим через EXISTS-join к clients по client_id.
--
-- ⚠️ ПЕРЕД ПРИМЕНЕНИЕМ К БОЕВОЙ БД:
--   1) Backfill: клиенты с пустым branch_id станут невидимы для accountant.
--        SELECT count(*) FROM public.clients
--        WHERE branch_id IS NULL OR trim(branch_id) = '';
--      При наличии таких — сначала проставить branch_id.
--   2) Сверить инвентарь политик (на случай, если поздняя миграция/ручная
--      правка добавила ещё одну permissive SELECT-политику — она бы OR-нула
--      ограничение):
--        SELECT polname, cmd, qual FROM pg_policies
--        WHERE tablename IN ('clients','client_balances','client_transactions');
-- Идемпотентно: DROP POLICY IF EXISTS + CREATE.
-- ============================================================

BEGIN;

-- ── clients ──────────────────────────────────────────────────
DROP POLICY IF EXISTS "clients_select" ON public.clients;
CREATE POLICY "clients_select" ON public.clients FOR SELECT TO authenticated
  USING (
    private.is_creator_or_director()
    OR (branch_id IS NOT NULL AND branch_id = ANY(private.user_branches()))
  );

-- ── client_balances ─────────────────────────────────────────
DROP POLICY IF EXISTS "client_balances_select" ON public.client_balances;
CREATE POLICY "client_balances_select" ON public.client_balances FOR SELECT TO authenticated
  USING (
    private.is_creator_or_director()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = client_balances.client_id
        AND c.branch_id = ANY(private.user_branches())
    )
  );

-- FOR ALL тоже сужаем (иначе перекрывает select-политику по OR).
DROP POLICY IF EXISTS "client_balances_all" ON public.client_balances;
CREATE POLICY "client_balances_all" ON public.client_balances FOR ALL TO authenticated
  USING (
    private.is_creator_or_director()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = client_balances.client_id
        AND c.branch_id = ANY(private.user_branches())
    )
  )
  WITH CHECK (
    private.is_creator_or_director()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = client_balances.client_id
        AND c.branch_id = ANY(private.user_branches())
    )
  );

-- ── client_transactions ─────────────────────────────────────
DROP POLICY IF EXISTS "client_tx_select" ON public.client_transactions;
CREATE POLICY "client_tx_select" ON public.client_transactions FOR SELECT TO authenticated
  USING (
    private.is_creator_or_director()
    OR EXISTS (
      SELECT 1 FROM public.clients c
      WHERE c.id = client_transactions.client_id
        AND c.branch_id = ANY(private.user_branches())
    )
  );

COMMIT;
