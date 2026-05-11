-- ============================================================
-- 021: Pending approvals workflow (accountant → director)
-- ============================================================
-- Бизнес-правило: бухгалтер не может в одиночку изменять/удалять
-- деньги клиентов и реквизиты — каждое такое действие сначала уходит
-- директору на согласование, и только после approve_request оно
-- реально применяется (RPC исполняется внутри approve_request).
--
-- Что добавлено в этой миграции:
--   * Таблица public.pending_approvals + два enum-типа
--   * RLS: accountant создаёт/видит свои, director/creator видит все
--     и единственный кто может approve/reject
--   * Realtime publication для подписки клиента
--   * Новые admin-RPC для клиентов (admin_update_client,
--     admin_archive_client) — их раньше не было
--   * RPC request_approval (любая authenticated роль)
--   * RPC approve_request (creator/director) — диспатчит на
--     существующие admin_* и transfer_* RPC согласно action
--   * RPC reject_request (creator/director)
--
-- Идемпотентна (можно запускать повторно).
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Enum-типы
-- ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'approval_action_t') THEN
    CREATE TYPE public.approval_action_t AS ENUM (
      'transfer_reject',
      'transfer_amend_amount',
      'client_update',
      'client_archive',
      'branch_account_update',
      'branch_account_archive'
    );
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'approval_status_t') THEN
    CREATE TYPE public.approval_status_t AS ENUM (
      'pending',
      'approved',
      'rejected'
    );
  END IF;
END
$$;

-- ─────────────────────────────────────────────────────────────
-- 2. Таблица pending_approvals
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.pending_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action public.approval_action_t NOT NULL,
  target_id uuid NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  reason text,
  requested_by uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  requested_at timestamptz NOT NULL DEFAULT now(),
  status public.approval_status_t NOT NULL DEFAULT 'pending',
  reviewed_by uuid REFERENCES public.users(id),
  reviewed_at timestamptz,
  review_note text,
  -- Снимок результата исполнения admin_* RPC при approve (для аудита/отладки)
  execution_result jsonb
);

CREATE INDEX IF NOT EXISTS idx_pending_approvals_status_created
  ON public.pending_approvals (status, requested_at DESC);

CREATE INDEX IF NOT EXISTS idx_pending_approvals_target
  ON public.pending_approvals (target_id);

CREATE INDEX IF NOT EXISTS idx_pending_approvals_requester
  ON public.pending_approvals (requested_by);

-- ─────────────────────────────────────────────────────────────
-- 3. RLS
-- ─────────────────────────────────────────────────────────────

ALTER TABLE public.pending_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "approvals_select_creator_director" ON public.pending_approvals;
CREATE POLICY "approvals_select_creator_director"
  ON public.pending_approvals
  FOR SELECT
  USING (private.is_creator_or_director());

DROP POLICY IF EXISTS "approvals_select_own" ON public.pending_approvals;
CREATE POLICY "approvals_select_own"
  ON public.pending_approvals
  FOR SELECT
  USING (requested_by = auth.uid());

-- Прямые INSERT/UPDATE/DELETE запрещены — только через RPC (которые
-- SECURITY DEFINER и обходят RLS, но содержат свои проверки роли).
DROP POLICY IF EXISTS "approvals_no_direct_writes" ON public.pending_approvals;
CREATE POLICY "approvals_no_direct_writes"
  ON public.pending_approvals
  FOR ALL
  USING (false)
  WITH CHECK (false);

-- ─────────────────────────────────────────────────────────────
-- 4. Realtime publication
-- ─────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    -- Добавим таблицу, если её там ещё нет
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = 'pending_approvals'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.pending_approvals;
    END IF;
  END IF;
END
$$;

-- ─────────────────────────────────────────────────────────────
-- 5. Новый admin_update_client RPC
-- ─────────────────────────────────────────────────────────────
-- Раньше клиента изменяли прямым UPDATE на public.clients от
-- creator/director. Теперь — централизованный RPC, чтобы approval
-- мог его вызвать с SECURITY DEFINER правами.

CREATE OR REPLACE FUNCTION private.admin_update_client(
  p_client_id uuid,
  p_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_branch_id text DEFAULT NULL,
  p_wallet_currencies text[] DEFAULT NULL,
  p_counterparty_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL,
  p_clear_telegram boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_client public.clients%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может изменять клиентов';
  END IF;

  SELECT * INTO v_client FROM public.clients WHERE id = p_client_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

  UPDATE public.clients SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    phone = COALESCE(NULLIF(trim(p_phone), ''), phone),
    country = COALESCE(NULLIF(trim(p_country), ''), country),
    currency = COALESCE(NULLIF(trim(p_currency), ''), currency),
    branch_id = COALESCE(NULLIF(trim(p_branch_id), ''), branch_id),
    wallet_currencies = COALESCE(p_wallet_currencies, wallet_currencies),
    -- counterparty_id допускает пустую строку (если колонка есть в схеме)
    counterparty_id = CASE
      WHEN p_counterparty_id IS NULL THEN counterparty_id
      ELSE NULLIF(trim(p_counterparty_id), '')
    END,
    telegram_chat_id = CASE
      WHEN p_clear_telegram THEN NULL
      WHEN p_telegram_chat_id IS NULL THEN telegram_chat_id
      ELSE NULLIF(trim(p_telegram_chat_id), '')
    END
  WHERE id = p_client_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('client.updated', 'client', p_client_id::text, v_uid,
          jsonb_build_object(
            'name', p_name,
            'phone', p_phone,
            'currency', p_currency
          ));

  RETURN jsonb_build_object('success', true);
EXCEPTION
  -- counterparty_id или telegram_chat_id колонка может отсутствовать в схеме —
  -- проверка по сообщению, чтобы откатить без падения миграции у тех, кто
  -- ещё не накатил соответствующие столбцы.
  WHEN undefined_column THEN
    UPDATE public.clients SET
      name = COALESCE(NULLIF(trim(p_name), ''), name),
      phone = COALESCE(NULLIF(trim(p_phone), ''), phone),
      country = COALESCE(NULLIF(trim(p_country), ''), country),
      currency = COALESCE(NULLIF(trim(p_currency), ''), currency),
      branch_id = COALESCE(NULLIF(trim(p_branch_id), ''), branch_id),
      wallet_currencies = COALESCE(p_wallet_currencies, wallet_currencies)
    WHERE id = p_client_id;
    RETURN jsonb_build_object('success', true, 'partial', true);
END
$$;

CREATE OR REPLACE FUNCTION public.admin_update_client(
  p_client_id uuid,
  p_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_branch_id text DEFAULT NULL,
  p_wallet_currencies text[] DEFAULT NULL,
  p_counterparty_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL,
  p_clear_telegram boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT private.admin_update_client(
    p_client_id, p_name, p_phone, p_country, p_currency,
    p_branch_id, p_wallet_currencies, p_counterparty_id,
    p_telegram_chat_id, p_clear_telegram
  )
$$;

REVOKE EXECUTE ON FUNCTION public.admin_update_client(
  uuid, text, text, text, text, text, text[], text, text, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_client(
  uuid, text, text, text, text, text, text[], text, text, boolean
) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 6. Новый admin_archive_client RPC
-- ─────────────────────────────────────────────────────────────
-- Soft-delete клиента: ставит is_active=false. Блокируем, если у
-- клиента есть ненулевой баланс — нужно сначала закрыть кошельки.

CREATE OR REPLACE FUNCTION private.admin_archive_client(
  p_client_id uuid,
  p_archive boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_balances jsonb;
  v_has_balance boolean := false;
  v_currency text;
  v_amount double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может удалять клиентов';
  END IF;

  IF p_archive THEN
    -- Проверяем нулевой баланс
    SELECT balances INTO v_balances
      FROM public.client_balances WHERE client_id = p_client_id;

    IF v_balances IS NOT NULL THEN
      FOR v_currency, v_amount IN
        SELECT k, (val)::text::double precision
        FROM jsonb_each(v_balances) AS j(k, val)
      LOOP
        IF v_amount IS NOT NULL AND abs(v_amount) > 0.005 THEN
          v_has_balance := true;
          EXIT;
        END IF;
      END LOOP;
    END IF;

    IF v_has_balance THEN
      RAISE EXCEPTION 'Нельзя удалить клиента с ненулевым балансом. Сначала закройте кошельки.';
    END IF;
  END IF;

  UPDATE public.clients SET is_active = NOT p_archive WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (
    CASE WHEN p_archive THEN 'client.archived' ELSE 'client.restored' END,
    'client', p_client_id::text, v_uid, '{}'::jsonb);

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION public.admin_archive_client(
  p_client_id uuid,
  p_archive boolean DEFAULT true
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT private.admin_archive_client(p_client_id, p_archive) $$;

REVOKE EXECUTE ON FUNCTION public.admin_archive_client(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_archive_client(uuid, boolean) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 7. request_approval — accountant создаёт заявку
-- ─────────────────────────────────────────────────────────────
-- Любая роль может создать заявку. Reason обязателен (минимум 3 символа),
-- чтобы директор понимал контекст. Target должен существовать.

CREATE OR REPLACE FUNCTION private.request_approval(
  p_action public.approval_action_t,
  p_target_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
  v_exists boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF p_target_id IS NULL THEN RAISE EXCEPTION 'target_id обязателен'; END IF;
  IF length(coalesce(trim(p_reason), '')) < 3 THEN
    RAISE EXCEPTION 'Укажите причину (минимум 3 символа)';
  END IF;

  -- Проверка существования цели по типу действия
  CASE p_action
    WHEN 'transfer_reject', 'transfer_amend_amount' THEN
      SELECT EXISTS (SELECT 1 FROM public.transfers WHERE id = p_target_id) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

    WHEN 'client_update', 'client_archive' THEN
      SELECT EXISTS (SELECT 1 FROM public.clients WHERE id = p_target_id) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

    WHEN 'branch_account_update', 'branch_account_archive' THEN
      SELECT EXISTS (SELECT 1 FROM public.branch_accounts WHERE id = p_target_id) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Счёт не найден'; END IF;
  END CASE;

  -- Не плодим дубли по одной и той же цели/действию в статусе pending
  IF EXISTS (
    SELECT 1 FROM public.pending_approvals
    WHERE action = p_action
      AND target_id = p_target_id
      AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'По этой операции уже есть заявка на согласовании';
  END IF;

  INSERT INTO public.pending_approvals (
    action, target_id, payload, reason, requested_by
  ) VALUES (
    p_action, p_target_id, COALESCE(p_payload, '{}'::jsonb),
    trim(p_reason), v_uid
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('approval.requested', 'pending_approval', v_id::text, v_uid,
          jsonb_build_object(
            'action', p_action::text,
            'targetId', p_target_id::text,
            'reason', trim(p_reason)
          ));

  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION public.request_approval(
  p_action text,
  p_target_id uuid,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_reason text DEFAULT NULL
) RETURNS uuid
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT private.request_approval(
    p_action::public.approval_action_t,
    p_target_id, p_payload, p_reason
  )
$$;

REVOKE EXECUTE ON FUNCTION public.request_approval(text, uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_approval(text, uuid, jsonb, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 8. approve_request — director/creator одобряет и сразу исполняет
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.approve_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req public.pending_approvals%ROWTYPE;
  v_result jsonb;
  v_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может одобрять заявки';
  END IF;

  SELECT * INTO v_req
    FROM public.pending_approvals
    WHERE id = p_approval_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Заявка не найдена'; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'Заявка уже % раннее', v_req.status;
  END IF;

  v_payload := COALESCE(v_req.payload, '{}'::jsonb);

  -- Диспатч по action
  CASE v_req.action
    WHEN 'transfer_reject' THEN
      v_result := private.reject_transfer(
        v_req.target_id,
        v_payload->>'reason'
      );

    WHEN 'transfer_amend_amount' THEN
      v_result := private.update_transfer_amount(
        v_req.target_id,
        (v_payload->>'amount')::double precision,
        v_payload->>'note'
      );

    WHEN 'client_update' THEN
      v_result := private.admin_update_client(
        v_req.target_id,
        v_payload->>'name',
        v_payload->>'phone',
        v_payload->>'country',
        v_payload->>'currency',
        v_payload->>'branch_id',
        CASE WHEN v_payload ? 'wallet_currencies'
             THEN ARRAY(SELECT jsonb_array_elements_text(v_payload->'wallet_currencies'))
             ELSE NULL END,
        v_payload->>'counterparty_id',
        v_payload->>'telegram_chat_id',
        COALESCE((v_payload->>'clear_telegram')::boolean, false)
      );

    WHEN 'client_archive' THEN
      v_result := private.admin_archive_client(
        v_req.target_id,
        COALESCE((v_payload->>'archive')::boolean, true)
      );

    WHEN 'branch_account_update' THEN
      v_result := private.admin_update_branch_account(
        v_req.target_id,
        v_payload->>'name',
        v_payload->>'type',
        v_payload->>'currency',
        v_payload->>'card_number',
        COALESCE((v_payload->>'clear_card_number')::boolean, false),
        v_payload->>'cardholder_name',
        v_payload->>'bank_name',
        NULLIF(v_payload->>'expiry_month', '')::smallint,
        NULLIF(v_payload->>'expiry_year', '')::smallint,
        v_payload->>'notes',
        NULLIF(v_payload->>'sort_order', '')::int
      );

    WHEN 'branch_account_archive' THEN
      v_result := private.admin_archive_branch_account(
        v_req.target_id,
        COALESCE((v_payload->>'archive')::boolean, true)
      );
  END CASE;

  UPDATE public.pending_approvals SET
    status = 'approved',
    reviewed_by = v_uid,
    reviewed_at = now(),
    review_note = NULLIF(trim(p_note), ''),
    execution_result = v_result
  WHERE id = p_approval_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('approval.approved', 'pending_approval', p_approval_id::text, v_uid,
          jsonb_build_object(
            'action', v_req.action::text,
            'targetId', v_req.target_id::text
          ));

  -- Уведомление инициатору
  INSERT INTO public.notifications (target_user_id, type, title, body, data) VALUES (
    v_req.requested_by::text,
    'approval_approved',
    'Заявка одобрена',
    'Ваш запрос на ' || v_req.action::text || ' одобрен.',
    jsonb_build_object(
      'approvalId', p_approval_id::text,
      'action', v_req.action::text,
      'targetId', v_req.target_id::text
    )
  );

  RETURN jsonb_build_object('success', true, 'execution', v_result);
END
$$;

CREATE OR REPLACE FUNCTION public.approve_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT private.approve_request(p_approval_id, p_note) $$;

REVOKE EXECUTE ON FUNCTION public.approve_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_request(uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 9. reject_request — director/creator отклоняет заявку
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.reject_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_req public.pending_approvals%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может отклонять заявки';
  END IF;

  SELECT * INTO v_req
    FROM public.pending_approvals
    WHERE id = p_approval_id
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Заявка не найдена'; END IF;
  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'Заявка уже % раннее', v_req.status;
  END IF;

  UPDATE public.pending_approvals SET
    status = 'rejected',
    reviewed_by = v_uid,
    reviewed_at = now(),
    review_note = NULLIF(trim(p_note), '')
  WHERE id = p_approval_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('approval.rejected', 'pending_approval', p_approval_id::text, v_uid,
          jsonb_build_object(
            'action', v_req.action::text,
            'targetId', v_req.target_id::text,
            'note', NULLIF(trim(p_note), '')
          ));

  INSERT INTO public.notifications (target_user_id, type, title, body, data) VALUES (
    v_req.requested_by::text,
    'approval_rejected',
    'Заявка отклонена',
    COALESCE(NULLIF(trim(p_note), ''), 'Директор отклонил запрос.'),
    jsonb_build_object(
      'approvalId', p_approval_id::text,
      'action', v_req.action::text,
      'targetId', v_req.target_id::text
    )
  );

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION public.reject_request(
  p_approval_id uuid,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT private.reject_request(p_approval_id, p_note) $$;

REVOKE EXECUTE ON FUNCTION public.reject_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reject_request(uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 10. Конец миграции
-- ─────────────────────────────────────────────────────────────

COMMENT ON TABLE public.pending_approvals IS
  'Заявки от бухгалтеров на изменение/удаление финансовых сущностей. Подтверждаются директором через approve_request.';
