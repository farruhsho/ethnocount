-- ============================================================
-- 065: Аудит before/after на чувствительные изменения — Этап 1.2
-- ============================================================
-- audit_logs уже пишется частью RPC (архив филиалов/счетов 011, юзеры
-- 013, approve-workflow со снимком old/new 021/052, архив клиента 021,
-- курс 001). Но три класса чувствительных изменений остаются «немыми»:
--
--   1) system_settings — пишется ПРЯМЫМ upsert с клиента (RPC нет вовсе,
--      см. system_settings_remote_ds.dart). Никто не фиксирует, кто и
--      когда поменял комиссии / telegram-токен / длительность сессии.
--   2) aml_settings — aml_update_settings (061) меняет пороги AML, но в
--      audit_logs ничего не пишет. Это комплаенс-чувствительное действие.
--   3) Архив/удаление партнёра — set_counterparty_active (034) и каскадные
--      DELETE не логируются вообще («каскад молчит»).
--   + у set_exchange_rate (001) есть запись, но без предыдущего значения.
--
-- РЕШЕНИЕ — гибрид, по природе каждого источника:
--
--   • Конфиг-таблицы и архив/удаление (system_settings, aml_settings,
--     counterparties) — универсальный AFTER-триггер. Это единственный
--     способ покрыть прямой upsert system_settings (RPC нет), и он не
--     требует воспроизводить тело 200-строчных денежных RPC. Триггер
--     видит актора через auth.uid() (claim из JWT сохраняется и в
--     SECURITY DEFINER, и в триггерном контексте).
--   • Курс валют (exchange_rates) — append-only история (каждый set =
--     новый ряд) и запись в audit_logs УЖЕ есть. Триггер тут только
--     дублировал бы строку и не видел бы «old». Поэтому дополняем сам
--     RPC: достаём предыдущий курс пары и кладём old→new в ту же запись.
--
-- ЧЕГО СОЗНАТЕЛЬНО НЕ ДЕЛАЕМ (во избежание дублей и write-amplification):
--   • Движения сальдо партнёра НЕ логируем повторно — они уже неизменно
--     лежат в counterparty_transactions (и сверяются reconcile_counterparty
--     из 066). Триггер на counterparties ограничен сменой is_active.
--   • Архив/восстановление клиента уже пишет admin_archive_client (021) —
--     UPDATE-триггер на clients был бы дублем и срабатывал бы на каждое
--     изменение баланса. На clients ловим только «тихое» удаление (DELETE).
--
-- Идемпотентно: CREATE OR REPLACE функций + DROP TRIGGER IF EXISTS перед
-- CREATE TRIGGER. Новых таблиц/колонок нет, схема не меняется.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. Универсальная триггер-функция аудита
--    SECURITY DEFINER — пишет в audit_logs в обход RLS вызывающего.
--    Два инварианта надёжности:
--      (a) performed_by NOT NULL + FK→auth.users: без актора писать
--          нельзя. Системные/фоновые изменения (миграции, бэкфилл,
--          auth.uid() IS NULL) тихо пропускаем — аудит не должен ронять
--          саму операцию.
--      (b) сбой вставки аудита НЕ должен отменять основную операцию —
--          оборачиваем INSERT в под-блок с EXCEPTION WHEN others.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.audit_sensitive_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_entity_id text;
  v_details   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN COALESCE(NEW, OLD);   -- нет актора → нечего и некому атрибутировать
  END IF;

  v_entity_id := COALESCE(to_jsonb(NEW) ->> 'id', to_jsonb(OLD) ->> 'id', '');

  -- {op, old?, new?} — old только если есть (не INSERT), new только если
  -- есть (не DELETE). null-поля внутри строки НЕ срезаем: «field → null»
  -- это значимое изменение, его надо видеть в before/after.
  v_details := jsonb_build_object('op', TG_OP);
  IF TG_OP <> 'INSERT' THEN
    v_details := v_details || jsonb_build_object('old', to_jsonb(OLD));
  END IF;
  IF TG_OP <> 'DELETE' THEN
    v_details := v_details || jsonb_build_object('new', to_jsonb(NEW));
  END IF;

  BEGIN
    INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
    VALUES (
      TG_TABLE_NAME || '.' || lower(TG_OP),  -- напр. 'system_settings.update'
      TG_TABLE_NAME,
      v_entity_id,
      v_uid,
      v_details
    );
  EXCEPTION WHEN others THEN
    NULL;  -- аудит — вспомогательная запись, его сбой не рушит операцию
  END;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 2. system_settings — нет RPC, прямой upsert с клиента.
--    Триггер — единственный способ зафиксировать изменения конфигурации.
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_audit_system_settings ON public.system_settings;
CREATE TRIGGER trg_audit_system_settings
  AFTER INSERT OR UPDATE OR DELETE ON public.system_settings
  FOR EACH ROW EXECUTE FUNCTION private.audit_sensitive_change();

-- ────────────────────────────────────────────────────────────
-- 3. aml_settings — один ряд (id=true), меняется на месте.
--    AFTER UPDATE даёт полный old/new порогов AML.
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_audit_aml_settings ON public.aml_settings;
CREATE TRIGGER trg_audit_aml_settings
  AFTER UPDATE ON public.aml_settings
  FOR EACH ROW EXECUTE FUNCTION private.audit_sensitive_change();

-- ────────────────────────────────────────────────────────────
-- 4. counterparties — архивация (set_counterparty_active) и каскадное
--    удаление сейчас не логируются. UPDATE-триггер ограничен сменой
--    is_active: движения сальдо (saldo_by_currency) НЕ логируем — они уже
--    в counterparty_transactions, иначе дубль + write-amplification.
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_audit_counterparties_archive ON public.counterparties;
CREATE TRIGGER trg_audit_counterparties_archive
  AFTER UPDATE ON public.counterparties
  FOR EACH ROW
  WHEN (OLD.is_active IS DISTINCT FROM NEW.is_active)
  EXECUTE FUNCTION private.audit_sensitive_change();

DROP TRIGGER IF EXISTS trg_audit_counterparties_delete ON public.counterparties;
CREATE TRIGGER trg_audit_counterparties_delete
  AFTER DELETE ON public.counterparties
  FOR EACH ROW EXECUTE FUNCTION private.audit_sensitive_change();

-- ────────────────────────────────────────────────────────────
-- 5. clients — архив/восстановление уже пишет admin_archive_client (021),
--    поэтому UPDATE НЕ трогаем (дубль + срабатывал бы на каждое движение
--    баланса). Ловим только «тихое» удаление (прямое/каскадом).
-- ────────────────────────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_audit_clients_delete ON public.clients;
CREATE TRIGGER trg_audit_clients_delete
  AFTER DELETE ON public.clients
  FOR EACH ROW EXECUTE FUNCTION private.audit_sensitive_change();

-- ────────────────────────────────────────────────────────────
-- 6. Курс валют — дополняем существующую запись audit_logs предыдущим
--    значением. Тело воспроизведено из 001 без изменений; добавлены
--    только выборка v_old_rate и поля oldRate/newRate в details.
--    Сигнатура и public-обёртка (010) сохраняются → привилегии тоже.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.set_exchange_rate(
  p_from_currency text,
  p_to_currency text,
  p_rate double precision
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_rate_id uuid;
  v_old_rate double precision;   -- 065: предыдущий курс пары для old→new
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  -- Последний установленный курс той же пары ДО вставки нового ряда.
  SELECT rate INTO v_old_rate
    FROM exchange_rates
   WHERE from_currency = p_from_currency
     AND to_currency   = p_to_currency
   ORDER BY effective_at DESC, created_at DESC
   LIMIT 1;

  v_rate_id := gen_random_uuid();
  INSERT INTO exchange_rates (id, from_currency, to_currency, rate, set_by, effective_at)
  VALUES (v_rate_id, p_from_currency, p_to_currency, p_rate, v_user_id, now());

  INSERT INTO audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('set_exchange_rate', 'exchangeRate', v_rate_id::text, v_user_id,
          jsonb_build_object(
            'fromCurrency', p_from_currency,
            'toCurrency',   p_to_currency,
            'rate',         p_rate,        -- сохранено для обратной совместимости
            'oldRate',      v_old_rate,    -- 065: было (NULL если первый курс пары)
            'newRate',      p_rate         -- 065: стало
          ));

  RETURN jsonb_build_object('success', true);
END;
$$;

COMMIT;
