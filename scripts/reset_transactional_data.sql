-- ============================================================
-- ОЧИСТКА ТРАНЗАКЦИОННЫХ ДАННЫХ
-- ============================================================
-- Запускать из SQL Editor в Supabase Studio (или supabase db psql).
-- Применять ТОЛЬКО когда вы готовы стереть всю историю операций.
--
-- Что удаляется:
--   • Все переводы (public.transfers) и сопутствующее:
--     - transfer_issuances (частичные выдачи)
--     - commissions (списания комиссий)
--     - notifications (входящие/исходящие уведомления)
--     - ledger_entries из transfers/commissions
--   • Все клиенты-контрагенты (public.clients) и их операции:
--     - client_balances, client_transactions
--     - ledger_entries из client_deposit/client_debit
--   • Удалённые покупки (deleted_purchases) и аудит-логи операций.
--   • Сбрасываются счётчики номеров (TRX-/PUR-/...).
--   • Все account_balances обнуляются (ставятся в 0) — иначе они
--     останутся со старыми значениями, посчитанными по уже стёртым
--     ledger_entries.
--
-- Что СОХРАНЯЕТСЯ:
--   • Пользователи (public.users), их роли, пароли (auth.users).
--   • Филиалы (public.branches) и их счета (public.branch_accounts).
--   • Курсы валют, system_settings.
--
-- Запускайте в одной транзакции — либо всё, либо ничего.
-- ============================================================

BEGIN;

-- ─── Хелпер: TRUNCATE только для существующих таблиц ───
-- Часть таблиц добавлена поздними миграциями (012 — transfer_issuances и т.п.).
-- Если миграция ещё не применена, TRUNCATE на отсутствующую таблицу даст
-- 42P01 и сломает всю транзакцию. Динамический EXECUTE решает проблему.
DO $cleanup$
DECLARE
  t text;
  -- Порядок важен: дочерние с FK — сначала, родители — потом.
  tables text[] := ARRAY[
    -- переводы и связанные
    'transfer_issuances',
    'commissions',
    'notifications',
    'transfers',
    -- клиенты
    'client_transactions',
    'client_balances',
    'clients',
    -- журнал
    'ledger_entries',
    -- покупки
    'deleted_purchases',
    'purchases',
    -- счётчики
    'counters'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = t
    ) THEN
      EXECUTE format('TRUNCATE TABLE public.%I RESTART IDENTITY CASCADE', t);
      RAISE NOTICE '  TRUNCATE public.% — ok', t;
    ELSE
      RAISE NOTICE '  пропущено (не существует): public.%', t;
    END IF;
  END LOOP;
END
$cleanup$;

-- Аудит — операционные записи (создания/правки переводов/клиентов).
-- Записи об управлении пользователями/филиалами оставляем.
DO $audit$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'audit_logs'
  ) THEN
    DELETE FROM public.audit_logs
     WHERE entity_type IN (
       'transfer', 'client', 'ledger', 'purchase', 'commission',
       'client_transaction', 'transfer_issuance'
     );
  END IF;
END
$audit$;

-- Обнуляем балансы счетов (иначе они "висят" из удалённых проводок).
DO $balances$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'account_balances'
  ) THEN
    UPDATE public.account_balances
       SET balance = 0,
           updated_at = now();
  END IF;
END
$balances$;

-- ─── Проверка (только для существующих таблиц) ───
DO $verify$
DECLARE
  v_count int;
  t text;
  v_failed boolean := false;
  tables text[] := ARRAY[
    'transfers','clients','ledger_entries','purchases'
  ];
BEGIN
  RAISE NOTICE 'Очистка завершена:';
  FOREACH t IN ARRAY tables LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = t
    ) THEN
      EXECUTE format('SELECT count(*) FROM public.%I', t) INTO v_count;
      RAISE NOTICE '  % — %', rpad(t, 16), v_count;
      IF v_count <> 0 THEN v_failed := true; END IF;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'account_balances'
  ) THEN
    SELECT count(*) INTO v_count
      FROM public.account_balances WHERE balance <> 0;
    RAISE NOTICE '  ненулевых балансов: %', v_count;
    IF v_count <> 0 THEN v_failed := true; END IF;
  END IF;

  IF v_failed THEN
    RAISE EXCEPTION 'Что-то не очистилось — откатываем';
  END IF;
END
$verify$;

COMMIT;

-- После COMMIT можно открыть приложение — оно покажет нулевые балансы
-- и пустые списки. Курсы валют, филиалы, счета и пользователи на месте.
