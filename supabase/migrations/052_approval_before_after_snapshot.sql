-- ============================================================
-- 052: capture before-snapshot in approval payload
-- ============================================================
-- В UI на экране согласований директор видит только новые значения
-- (то что бухгалтер хочет применить), но не текущие. Это мешает
-- быстро оценить «что именно меняется». Например:
--   Запрос: client_update {name: "ООО Шарк-Карго"}
--   А что было? Имя или адрес? Из карточки не видно.
--
-- Эта миграция расширяет `private.request_approval` так, чтобы перед
-- сохранением заявки она ДЕЛАЛА СНИМОК текущего состояния target-объекта
-- и положила его в payload как ключ `_before`. UI потом рендерит
-- before → after diff из этого ключа.
--
-- Backward compat:
--   • Старые заявки (без `_before`) UI рендерит как раньше — просто
--     показывает payload без diff.
--   • Поле `_before` управляется самим RPC; передавать его извне
--     нельзя — RPC перетирает.
--
-- Идемпотентно. CREATE OR REPLACE.
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
  -- Снимок — это сокращённый набор полей которые в принципе можно
  -- редактировать через approval. Сюда НЕ попадают системные поля
  -- (created_at, updated_at, RLS, …) — только то что директор должен
  -- сверять при approve.
  CASE p_action
    WHEN 'transfer_reject', 'transfer_amend_amount' THEN
      SELECT EXISTS (SELECT 1 FROM public.transfers WHERE id = p_target_id)
        INTO v_exists;
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
      SELECT EXISTS (SELECT 1 FROM public.clients WHERE id = p_target_id)
        INTO v_exists;
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
      SELECT EXISTS (SELECT 1 FROM public.branch_accounts WHERE id = p_target_id)
        INTO v_exists;
      IF NOT v_exists THEN RAISE EXCEPTION 'Счёт не найден'; END IF;
      SELECT jsonb_build_object(
        'name', name,
        'type', type,
        'currency', currency,
        'card_number', card_number,
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
