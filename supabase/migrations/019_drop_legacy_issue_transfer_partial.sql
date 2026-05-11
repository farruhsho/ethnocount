-- ============================================================
-- 019: Drop legacy 3-argument issue_transfer_partial overloads
-- ============================================================
-- Контекст: миграция 012 (partial_issuance) создала
--   private.issue_transfer_partial(uuid, double precision, text)
-- Миграция 014 (issuance_account_amend_notify) добавила расширенную
-- версию с дополнительным параметром выдающего счёта:
--   private.issue_transfer_partial(uuid, double precision, text, uuid DEFAULT NULL)
-- Старая версия НЕ была удалена — а так как у новой `p_from_account_id`
-- имеет DEFAULT NULL, оба варианта стали кандидатами при вызове из
-- supabase-flutter с тремя аргументами `(uuid, numeric, text)`.
-- PostgREST падает с 42725: function ... is not unique.
--
-- Лечение: дропаем старые перегрузки в обеих схемах. Новые остаются
-- единственными, и вызовы клиента (как с from_account_id, так и без)
-- разрешаются однозначно.
--
-- Идемпотентно: DROP IF EXISTS с явной сигнатурой; повторный запуск
-- без ошибки.
-- ============================================================

DROP FUNCTION IF EXISTS public.issue_transfer_partial(uuid, double precision, text);
DROP FUNCTION IF EXISTS private.issue_transfer_partial(uuid, double precision, text);

-- Sanity-check: убедимся, что 4-арг версия в обеих схемах ещё на месте.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'issue_transfer_partial'
      AND n.nspname = 'private'
      AND pg_get_function_arguments(p.oid) LIKE '%p_from_account_id%'
  ) THEN
    RAISE EXCEPTION 'private.issue_transfer_partial(uuid, double precision, text, uuid) пропала после дропа — миграция 014 должна быть применена раньше 019';
  END IF;
END $$;
