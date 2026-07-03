-- ============================================================
-- 090: request_approval — branch-scope (закрыть PII-оракул) (F2)
-- ============================================================
-- ПРОБЛЕМА (F2, ре-аудит 07.2026): private.request_approval (074) делает
-- _before-снимок ЛЮБОГО target_id (проверка только на существование), кладёт
-- его в pending_approvals.payload. Политика approvals_select_own (021) даёт
-- инициатору читать свою заявку. Значит бухгалтер запрашивает approval на
-- клиента/перевод/счёт ЧУЖОГО филиала и читает _before (имя, телефон, баланс,
-- реквизиты — PII+финданные) в обход branch-RLS 068. SECURITY DEFINER
-- обходит RLS, а внутри branch-скоупа нет.
--
-- РЕШЕНИЕ: в проверке существования цели для accountant дополнительно
-- требовать принадлежность цели его assignedBranchIds (private.user_branches()).
-- creator/director — без ограничений. Одинаковый текст ошибки ('...не
-- найден'), чтобы бухгалтер не мог по разнице ошибок отличить «нет цели» от
-- «чужой филиал» (без enumeration-оракула). Снимок строится только после
-- прохождения проверки.
--
-- Тело воспроизводит 074 1:1; изменены ТОЛЬКО три EXISTS-проверки (добавлен
-- branch-скоуп). Сигнатура и обёртки (021) не меняются. Идемпотентно.
-- ⚠️ Клиенты/счета/переводы с NULL branch_id станут недоступны accountant
-- для approval (как и в 068) — тот же backfill-предусловие, что у 068.
-- ============================================================

BEGIN;

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
  v_before jsonb;
  v_clean_payload jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF p_target_id IS NULL THEN RAISE EXCEPTION 'target_id обязателен'; END IF;
  IF length(coalesce(trim(p_reason), '')) < 3 THEN
    RAISE EXCEPTION 'Укажите причину (минимум 3 символа)';
  END IF;

  -- Проверка существования цели + snapshot текущего состояния (v_before).
  -- 090: для accountant существование дополнительно скоупится его филиалами —
  -- иначе снимок чужого филиала утекал бы через approvals_select_own.
  CASE p_action
    WHEN 'transfer_reject', 'transfer_amend_amount' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.transfers
        WHERE id = p_target_id
          AND (private.is_creator_or_director()
               OR from_branch_id::text = ANY(private.user_branches())
               OR to_branch_id::text   = ANY(private.user_branches()))
      ) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
      SELECT jsonb_build_object(
        'amount', amount,
        'currency', currency,
        'to_currency', to_currency,
        'exchange_rate', exchange_rate,
        'commission', commission,
        'description', description,
        'receiver_name', receiver_name,
        'receiver_phone', receiver_phone,
        'status', status::text
      )
        INTO v_before
        FROM public.transfers
        WHERE id = p_target_id;

    WHEN 'client_update', 'client_archive' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.clients
        WHERE id = p_target_id
          AND (private.is_creator_or_director()
               OR branch_id = ANY(private.user_branches()))
      ) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Клиент не найден'; END IF;
      SELECT jsonb_build_object(
        'name', name,
        'phone', phone,
        'country', country,
        'currency', currency,
        'branch_id', branch_id,
        'wallet_currencies', wallet_currencies,
        'is_active', is_active,
        'telegram_chat_id', telegram_chat_id
      )
        INTO v_before
        FROM public.clients
        WHERE id = p_target_id;

    WHEN 'branch_account_update', 'branch_account_archive' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.branch_accounts
        WHERE id = p_target_id
          AND (private.is_creator_or_director()
               OR branch_id::text = ANY(private.user_branches()))
      ) INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Счёт не найден'; END IF;
      SELECT jsonb_build_object(
        'name', name,
        'type', type,
        'currency', currency,
        -- SEC-2: маскируем PAN — директор сверяет только последние 4 цифры,
        -- полный номер в заявку/аудит не уходит.
        'card_number', private.mask_pan(card_number),
        'cardholder_name', cardholder_name,
        'bank_name', bank_name,
        'expiry_month', expiry_month,
        'expiry_year', expiry_year,
        'notes', notes,
        'is_active', is_active,
        'sort_order', sort_order
      )
        INTO v_before
        FROM public.branch_accounts
        WHERE id = p_target_id;
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

  -- Очищаем поступивший payload от служебного ключа `_before` (если
  -- передан) — он управляется только RPC.
  v_clean_payload := COALESCE(p_payload, '{}'::jsonb) - '_before';

  INSERT INTO public.pending_approvals (
    action, target_id, payload, reason, requested_by
  ) VALUES (
    p_action, p_target_id,
    v_clean_payload || jsonb_build_object('_before', COALESCE(v_before, '{}'::jsonb)),
    trim(p_reason), v_uid
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('approval.requested', 'pending_approval', v_id::text, v_uid,
          jsonb_build_object(
            'action', p_action::text,
            'targetId', p_target_id::text,
            'reason', trim(p_reason),
            'before', COALESCE(v_before, '{}'::jsonb)
          ));

  RETURN v_id;
END
$$;

COMMIT;
