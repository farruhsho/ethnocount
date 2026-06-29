-- ============================================================
-- 073: AML — скрин клиентских кошельков + branch-scope ленты флагов
-- ============================================================
-- Follow-up к 061/062. Два направления форензик-аудита (06.2026):
--
--   (#20) aml_flags_list возвращает PII (телефоны/имена субъектов)
--         по флагам ВСЕХ филиалов любому authenticated. 062 закрыл
--         только анонимный доступ (auth.uid() IS NULL), но бухгалтер
--         одного филиала по-прежнему видел журнал чужих. Сужаем по той
--         же модели, что clients/transfers (068, 011):
--           creator/director — всё; accountant — только флаги своих
--           назначенных филиалов + флаги, которые он сам зафиксировал
--           (клиентские velocity-флаги по subject_phone без привязки к
--           transfer/counterparty иначе были бы ему невидимы).
--         Привязка флага к филиалу: через transfers.from/to_branch_id,
--         через counterparties.branch_id или явный details->>'branchId'.
--
--   (#7)  Клиентские кошельки (deposit/debit/convert) НЕ проходили AML.
--         Добавляем private/public.aml_screen_client_op — зеркало
--         aml_screen, но velocity считается по обороту самого клиента
--         (client_transactions по client_id) И по нормализованному
--         телефону клиента (как субъекта переводов). Контур остаётся
--         СОВЕТУЮЩИМ: при превышении порога функция ПИШЕТ флаг, но
--         ВСЕГДА возвращает результат и НИКОГДА не блокирует операцию.
--
--   (#7 has_id) Порог идентификации теперь принимает реальный has_id
--         (p_has_id boolean DEFAULT false) — больше не зашит как false.
--
-- Денежные слои (saldo / касса / ledger) НЕ трогаются.
-- aml_flags_list: сигнатура (text, integer) не меняется → CREATE OR
-- REPLACE тела private-версии. Идемпотентно, в BEGIN; ... COMMIT;.
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. (#20) aml_flags_list — branch-scope журнала флагов
-- ─────────────────────────────────────────────────────────────
-- Сигнатура та же, что в 061/062, поэтому переопределяем только
-- private-тело (public-обёртка остаётся прежней). creator/director
-- видят всё; accountant — флаги своих филиалов плюс свои собственные.
CREATE OR REPLACE FUNCTION private.aml_flags_list(
  p_status text DEFAULT NULL,
  p_limit  integer DEFAULT 100
) RETURNS TABLE (
  id uuid,
  transfer_id uuid,
  counterparty_id uuid,
  subject_phone text,
  subject_name text,
  flag_type text,
  severity text,
  currency text,
  amount numeric,
  details jsonb,
  status text,
  created_at timestamptz,
  created_by uuid,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text,
  transaction_code text,
  counterparty_name text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid    := auth.uid();
  v_all     boolean := private.is_creator_or_director();
  v_branches text[] := COALESCE(private.user_branches(), '{}');
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  RETURN QUERY
  SELECT
    f.id, f.transfer_id, f.counterparty_id, f.subject_phone, f.subject_name,
    f.flag_type, f.severity, f.currency, f.amount, f.details, f.status,
    f.created_at, f.created_by, f.resolved_at, f.resolved_by, f.resolution_note,
    t.transaction_code, cp.name
  FROM aml_flags f
  LEFT JOIN transfers t       ON t.id  = f.transfer_id
  LEFT JOIN counterparties cp ON cp.id = f.counterparty_id
  WHERE (p_status IS NULL OR f.status = p_status)
    AND (
      -- creator/director — без ограничений
      v_all
      -- свои собственные флаги (клиентские velocity по subject_phone и пр.)
      OR f.created_by = v_uid
      -- флаг привязан к переводу одного из своих филиалов
      OR (t.from_branch_id::text = ANY(v_branches))
      OR (t.to_branch_id::text   = ANY(v_branches))
      -- флаг привязан к контрагенту своего филиала
      OR (cp.branch_id = ANY(v_branches))
      -- явная привязка филиала в details
      OR (NULLIF(f.details->>'branchId', '') = ANY(v_branches))
    )
  ORDER BY f.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 2. (#7) aml_screen_client_op — velocity-скрин клиентского кошелька
-- ─────────────────────────────────────────────────────────────
-- Зеркало aml_screen, но оборот считается по операциям самого клиента
-- (client_transactions.amount за окна 1 день / 30 дней) И, если у клиента
-- есть телефон, дополнительно по этому нормализованному телефону как
-- субъекту переводов (как в aml_screen). Текущая сумма p_amount учтена
-- в velocity. p_has_id — реальное KYC-состояние субъекта (default false).
--
-- СОВЕТУЮЩИЙ контур: при срабатывании порога ПИШЕТ флаг (через
-- private.aml_record_flag, без падения при ошибке записи) и ВСЕГДА
-- возвращает jsonb-результат. Никогда не бросает на превышении и не
-- блокирует операцию.
CREATE OR REPLACE FUNCTION private.aml_screen_client_op(
  p_client_id uuid,
  p_amount    numeric DEFAULT NULL,
  p_currency  text    DEFAULT NULL,
  p_op_type   text    DEFAULT NULL,
  p_has_id    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_cur text := upper(NULLIF(trim(p_currency), ''));
  v_op  text := lower(NULLIF(trim(p_op_type), ''));
  v_s aml_settings%ROWTYPE;
  v_client clients%ROWTYPE;
  v_phone text;
  v_amount numeric := COALESCE(p_amount, 0);
  v_daily   numeric := 0;
  v_monthly numeric := 0;
  v_phone_daily   numeric := 0;
  v_phone_monthly numeric := 0;
  v_id_thr      numeric;
  v_review_thr  numeric;
  v_daily_thr   numeric;
  v_monthly_thr numeric;
  v_warnings jsonb := '[]'::jsonb;
  v_requires_id  boolean := false;
  v_large        boolean := false;
  v_over_daily   boolean := false;
  v_over_monthly boolean := false;
  v_flagged      boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_s      FROM aml_settings WHERE id = true;
  SELECT * INTO v_client FROM clients WHERE id = p_client_id;
  v_phone := private.normalize_phone(v_client.phone);

  IF v_cur IS NOT NULL THEN
    v_id_thr      := NULLIF(v_s.id_required_by_currency->>v_cur, '')::numeric;
    v_review_thr  := NULLIF(v_s.single_tx_review_by_currency->>v_cur, '')::numeric;
    v_daily_thr   := NULLIF(v_s.daily_limit_by_currency->>v_cur, '')::numeric;
    v_monthly_thr := NULLIF(v_s.monthly_limit_by_currency->>v_cur, '')::numeric;
  END IF;

  -- Оборот самого клиента по client_transactions (любой тип операции).
  IF p_client_id IS NOT NULL AND v_cur IS NOT NULL THEN
    SELECT
      COALESCE(SUM(ct.amount) FILTER (WHERE ct.created_at >= now() - interval '1 day'), 0),
      COALESCE(SUM(ct.amount) FILTER (WHERE ct.created_at >= now() - interval '30 days'), 0)
    INTO v_daily, v_monthly
    FROM client_transactions ct
    WHERE ct.client_id = p_client_id
      AND upper(ct.currency) = v_cur;
  END IF;

  -- Доп. оборот по телефону клиента как субъекта переводов (как aml_screen).
  IF v_phone IS NOT NULL AND v_phone <> '' AND v_cur IS NOT NULL THEN
    SELECT
      COALESCE(SUM(t.amount) FILTER (WHERE t.created_at >= now() - interval '1 day'), 0),
      COALESCE(SUM(t.amount) FILTER (WHERE t.created_at >= now() - interval '30 days'), 0)
    INTO v_phone_daily, v_phone_monthly
    FROM transfers t
    WHERE upper(t.currency) = v_cur
      AND (
        private.normalize_phone(t.sender_phone)   = v_phone
        OR private.normalize_phone(t.receiver_phone) = v_phone
      );
  END IF;

  v_daily   := v_daily   + v_phone_daily;
  v_monthly := v_monthly + v_phone_monthly;

  -- Порог идентификации (реальный has_id).
  IF v_id_thr IS NOT NULL AND v_id_thr > 0 AND v_amount >= v_id_thr THEN
    v_requires_id := true;
    IF NOT COALESCE(p_has_id, false) THEN
      v_warnings := v_warnings || to_jsonb(format(
        'Сумма %s %s ≥ порога идентификации %s — нужен документ клиента',
        round(v_amount, 2), v_cur, round(v_id_thr, 2)));
    END IF;
  END IF;

  -- Крупная разовая операция.
  IF v_review_thr IS NOT NULL AND v_review_thr > 0 AND v_amount >= v_review_thr THEN
    v_large := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Крупная разовая операция клиента: %s %s ≥ %s — нужна проверка',
      round(v_amount, 2), v_cur, round(v_review_thr, 2)));
  END IF;

  -- Суточный оборот клиента (с учётом текущей суммы).
  IF v_daily_thr IS NOT NULL AND v_daily_thr > 0
     AND (v_daily + v_amount) > v_daily_thr + 1e-6 THEN
    v_over_daily := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Превышен суточный лимит клиента: %s + %s > %s %s',
      round(v_daily, 2), round(v_amount, 2), round(v_daily_thr, 2), v_cur));
  END IF;

  -- Месячный оборот клиента.
  IF v_monthly_thr IS NOT NULL AND v_monthly_thr > 0
     AND (v_monthly + v_amount) > v_monthly_thr + 1e-6 THEN
    v_over_monthly := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Превышен месячный лимит клиента: %s + %s > %s %s',
      round(v_monthly, 2), round(v_amount, 2), round(v_monthly_thr, 2), v_cur));
  END IF;

  v_flagged := (jsonb_array_length(v_warnings) > 0);

  -- СОВЕТУЮЩАЯ запись флага: при срабатывании фиксируем, но не падаем
  -- и не блокируем операцию, если запись по какой-то причине не удалась.
  IF v_flagged THEN
    BEGIN
      PERFORM private.aml_record_flag(
        p_flag_type     => 'client_velocity',
        p_subject_phone => NULLIF(v_phone, ''),
        p_subject_name  => NULLIF(trim(v_client.name), ''),
        p_transfer_id   => NULL,
        p_counterparty_id => NULL,
        p_currency      => v_cur,
        p_amount        => v_amount,
        p_severity      => CASE WHEN v_over_monthly OR v_large THEN 'high' ELSE 'medium' END,
        p_details       => jsonb_build_object(
          'source',       'client_wallet',
          'clientId',     p_client_id::text,
          'branchId',     v_client.branch_id,
          'opType',       v_op,
          'dailyTotal',   round(v_daily, 4),
          'monthlyTotal', round(v_monthly, 4),
          'requiresId',   v_requires_id,
          'hasId',        COALESCE(p_has_id, false),
          'largeAmount',  v_large,
          'overDaily',    v_over_daily,
          'overMonthly',  v_over_monthly,
          'warnings',     v_warnings
        )
      );
    EXCEPTION WHEN others THEN
      -- advisory: запись флага не должна ломать денежную операцию.
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'clientId',     p_client_id,
    'subjectPhone', v_phone,
    'currency',     v_cur,
    'opType',       v_op,
    'amount',       v_amount,
    'dailyTotal',   round(v_daily, 4),
    'monthlyTotal', round(v_monthly, 4),
    'requiresId',   v_requires_id,
    'hasId',        COALESCE(p_has_id, false),
    'largeAmount',  v_large,
    'overDaily',    v_over_daily,
    'overMonthly',  v_over_monthly,
    'flagged',      v_flagged,
    'warnings',     v_warnings
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.aml_screen_client_op(
  p_client_id uuid,
  p_amount    numeric DEFAULT NULL,
  p_currency  text    DEFAULT NULL,
  p_op_type   text    DEFAULT NULL,
  p_has_id    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.aml_screen_client_op(
    p_client_id, p_amount, p_currency, p_op_type, p_has_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.aml_screen_client_op(uuid, numeric, text, text, boolean)
  TO authenticated;

COMMIT;
