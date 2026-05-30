-- ============================================================
-- 043: Open SELECT on branches for all authenticated users
-- ============================================================
-- Бухгалтер видел только свой филиал из-за RLS:
--   branches_select USING (is_creator() OR id::text = ANY(user_branches()))
--
-- Это блокировало выбор филиала-получателя в форме «Новый перевод»:
-- _allBranches был фильтрован тем же RLS → dropdown получателя пуст.
--
-- Открываем SELECT для всех authenticated. Защита от создания перевода
-- из чужого филиала остаётся на уровне триггера
-- private.enforce_accountant_from_branch (миграция 025).
--
-- INSERT/UPDATE/DELETE по-прежнему creator-only.
-- Идемпотентно.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS branches_select ON public.branches;
CREATE POLICY branches_select ON public.branches
  FOR SELECT TO authenticated USING (true);

COMMIT;
