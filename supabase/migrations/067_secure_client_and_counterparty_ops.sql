-- ============================================================
-- 067: Branch-guard на денежные операции клиентов и расчёты с партнёрами
-- ============================================================
-- Закрывает CRITICAL-3/4 форензик-аудита (06.2026):
--   • deposit_client / debit_client / convert_client_currency — все три
--     SECURITY DEFINER RPC проверяли только `auth.uid() IS NOT NULL`,
--     без проверки филиала. Бухгалтер филиала A мог двигать баланс любого
--     клиента филиала B по UUID.
--   • record_counterparty_op (settle_*) — читал роль (v_role), но НЕ применял
--     её: прямой DEBIT/CREDIT кассы по произвольному p_cash_account_id без
--     проверки принадлежности филиалу бухгалтера.
--
-- ПОДХОД: не переписываем тела SECURITY DEFINER money-функций (риск
-- транскрипции = денежный баг), а ставим BEFORE INSERT триггеры на
-- counterparty/client-журналы — единые чокпоинты, через которые проходят
-- ВСЕ эти операции. SECURITY DEFINER меняет привилегии, но НЕ auth.uid(),
-- поэтому внутри функций триггер видит реального вызывающего.
--
-- Модель доступа: creator/director — без ограничений; accountant — только
-- свой назначенный филиал (assigned_branch_ids). Зеркалит уже работающий
-- private.enforce_accountant_from_branch (025) для transfers.
--
-- ⚠️ ПЕРЕД ПРИМЕНЕНИЕМ К БОЕВОЙ БД:
--   1) Проверить клиентов без филиала — у них accountant потеряет доступ:
--        SELECT count(*) FROM public.clients
--        WHERE branch_id IS NULL OR trim(branch_id) = '';
--      Если такие есть — сначала проставить им branch_id (backfill).
--   2) Триггеры идемпотентны (DROP TRIGGER IF EXISTS + CREATE).
-- ============================================================

BEGIN;

-- ── Общий guard: текстовый branch_id (clients.branch_id — text) ──
CREATE OR REPLACE FUNCTION private.enforce_accountant_branch(
  p_branch_id text,
  p_subject   text DEFAULT 'этой записи'
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_role     text;
  v_assigned text[];
BEGIN
  -- Сервисные вызовы без auth (миграции/бэкенд) пропускаем.
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role, assigned_branch_ids
    INTO v_role, v_assigned
  FROM public.users
  WHERE id = v_uid;

  -- creator / director / неизвестный (creator до promote) — без ограничений.
  IF v_role IS NULL OR v_role <> 'accountant' THEN RETURN; END IF;

  IF p_branch_id IS NULL
     OR trim(p_branch_id) = ''
     OR v_assigned IS NULL
     OR array_length(v_assigned, 1) IS NULL
     OR NOT (p_branch_id = ANY(v_assigned)) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Нет доступа к ' || p_subject || ' другого филиала. '
            || 'Бухгалтер работает только со своим назначенным филиалом.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.enforce_accountant_branch(text, text) TO authenticated;

-- ── client_transactions: каждая операция клиента (deposit/debit/convert) ──
-- вставляет хотя бы одну строку в client_transactions — единый чокпоинт.
CREATE OR REPLACE FUNCTION private.tg_client_tx_branch_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_branch text;
BEGIN
  SELECT branch_id INTO v_branch FROM public.clients WHERE id = NEW.client_id;
  PERFORM private.enforce_accountant_branch(v_branch, 'клиента');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS client_tx_branch_guard ON public.client_transactions;
CREATE TRIGGER client_tx_branch_guard
  BEFORE INSERT ON public.client_transactions
  FOR EACH ROW EXECUTE FUNCTION private.tg_client_tx_branch_guard();

-- ── counterparty_transactions: settle_* двигает кассу нашего филиала ──
-- Гейтим только расчёты с указанным кеш-счётом (именно они трогают
-- account_balances). paid_for_us / we_paid_for_them кассу не двигают.
CREATE OR REPLACE FUNCTION private.tg_cp_settle_branch_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_branch text;
BEGIN
  IF NEW.kind IN ('settle_to_us', 'settle_from_us')
     AND NEW.cash_account_id IS NOT NULL THEN
    SELECT branch_id::text INTO v_branch
      FROM public.branch_accounts WHERE id = NEW.cash_account_id;
    PERFORM private.enforce_accountant_branch(v_branch, 'кассы для расчёта с партнёром');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS cp_settle_branch_guard ON public.counterparty_transactions;
CREATE TRIGGER cp_settle_branch_guard
  BEFORE INSERT ON public.counterparty_transactions
  FOR EACH ROW EXECUTE FUNCTION private.tg_cp_settle_branch_guard();

COMMIT;
