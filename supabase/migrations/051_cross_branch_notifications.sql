-- ============================================================
-- 051: cross-branch notifications + approval workflow notifications
-- ============================================================
-- Type-фиксы относительно первой версии файла:
--   • notifications.target_user_id — uuid (не text), значит сравнение
--     `target_user_id = auth.uid()` без ::text-каста.
--   • clients.branch_id — text. v_client_branch_id объявлен как text.
--   • При INSERT в notifications.target_user_id передаётся uuid (u.id,
--     NEW.requested_by) — БЕЗ ::text.
-- ============================================================

BEGIN;

-- ─── 0. RLS: разрешаем DELETE уведомлений ─────────────────────
DROP POLICY IF EXISTS "notifications_delete" ON public.notifications;
CREATE POLICY "notifications_delete" ON public.notifications
  FOR DELETE TO authenticated
  USING (
    private.is_creator_or_director()
    OR target_user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_active = true
        AND notifications.target_branch_id = ANY(
          COALESCE(u.assigned_branch_ids, '{}')
        )
    )
  );


-- ─── 1. notify on transfer CREATE ─────────────────────────────
CREATE OR REPLACE FUNCTION private.notify_on_transfer_created()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from_branch_name text;
  v_code text;
BEGIN
  IF NEW.status <> 'created' THEN RETURN NEW; END IF;

  SELECT name INTO v_from_branch_name
    FROM public.branches WHERE id = NEW.from_branch_id;
  v_code := COALESCE(NEW.transaction_code, NEW.id::text);

  INSERT INTO public.notifications
    (target_branch_id, type, title, body, data)
  VALUES (
    NEW.to_branch_id::text,
    'incomingTransfer',
    'Новый перевод ' || v_code,
    'Поступил перевод '
      || to_char(NEW.amount::numeric, 'FM999G999G990D00')
      || ' ' || NEW.currency
      || ' из ' || COALESCE(v_from_branch_name, '—')
      || COALESCE(' · ' || NEW.receiver_name, ''),
    jsonb_build_object(
      'transferId', NEW.id::text,
      'transactionCode', v_code,
      'amount', NEW.amount,
      'currency', NEW.currency,
      'fromBranchId', NEW.from_branch_id::text
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_on_transfer_created_trg ON public.transfers;
CREATE TRIGGER notify_on_transfer_created_trg
  AFTER INSERT ON public.transfers
  FOR EACH ROW
  EXECUTE FUNCTION private.notify_on_transfer_created();


-- ─── 2. notify on approval REQUESTED (→ directors + creator) ─
CREATE OR REPLACE FUNCTION private.notify_on_approval_requested()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_requester_name text;
  v_action_label text;
  v_fallback_branch text;
BEGIN
  IF NEW.status::text <> 'pending' THEN RETURN NEW; END IF;

  SELECT COALESCE(display_name, email)
    INTO v_requester_name
    FROM public.users
    WHERE id = NEW.requested_by;

  v_action_label := CASE NEW.action::text
    WHEN 'transfer_amend_amount' THEN 'Изменение суммы перевода'
    WHEN 'client_update'         THEN 'Изменение клиента'
    WHEN 'client_archive'        THEN 'Удаление клиента'
    WHEN 'branch_account_update' THEN 'Изменение счёта'
    WHEN 'branch_account_archive' THEN 'Архив счёта'
    ELSE NEW.action::text
  END;

  -- Общий fallback-филиал для creator (у него assigned_branch_ids
  -- может быть пуст, но target_branch_id NOT NULL).
  SELECT id::text INTO v_fallback_branch
    FROM public.branches WHERE is_active = true ORDER BY name LIMIT 1;

  -- target_user_id типа uuid → НЕ кастуем.
  INSERT INTO public.notifications
    (target_branch_id, target_user_id, type, title, body, data)
  SELECT
    COALESCE(
      CASE
        WHEN u.role::text = 'creator'
          THEN v_fallback_branch
        ELSE COALESCE(u.assigned_branch_ids[1], v_fallback_branch)
      END,
      '—'
    ),
    u.id,                                    -- uuid, без ::text
    'systemAlert',
    'Заявка на согласование: ' || v_action_label,
    COALESCE(v_requester_name, 'Бухгалтер')
      || ' просит одобрить операцию. '
      || COALESCE('Причина: ' || NEW.reason, 'Без комментария.'),
    jsonb_build_object(
      'approvalId', NEW.id::text,
      'action', NEW.action::text,
      'requesterId', NEW.requested_by::text,
      'targetId', NEW.target_id::text
    )
  FROM public.users u
  WHERE u.role::text IN ('creator', 'director')
    AND u.is_active = true;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_on_approval_requested_trg ON public.pending_approvals;
CREATE TRIGGER notify_on_approval_requested_trg
  AFTER INSERT ON public.pending_approvals
  FOR EACH ROW
  EXECUTE FUNCTION private.notify_on_approval_requested();


-- ─── 3. notify on approval DECISION (→ requester) ─────────────
CREATE OR REPLACE FUNCTION private.notify_on_approval_decided()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer_name text;
  v_action_label text;
  v_decision text;
  v_requester_branch text;
BEGIN
  IF OLD.status::text = NEW.status::text THEN RETURN NEW; END IF;
  IF NEW.status::text NOT IN ('approved', 'rejected') THEN RETURN NEW; END IF;
  IF OLD.status::text <> 'pending' THEN RETURN NEW; END IF;

  SELECT COALESCE(display_name, email)
    INTO v_reviewer_name
    FROM public.users
    WHERE id = NEW.reviewed_by;

  v_action_label := CASE NEW.action::text
    WHEN 'transfer_amend_amount' THEN 'Изменение суммы перевода'
    WHEN 'client_update'         THEN 'Изменение клиента'
    WHEN 'client_archive'        THEN 'Удаление клиента'
    WHEN 'branch_account_update' THEN 'Изменение счёта'
    WHEN 'branch_account_archive' THEN 'Архив счёта'
    ELSE NEW.action::text
  END;
  v_decision := CASE NEW.status::text
    WHEN 'approved' THEN 'одобрена'
    WHEN 'rejected' THEN 'отклонена'
    ELSE NEW.status::text
  END;

  SELECT COALESCE(assigned_branch_ids[1],
           (SELECT id::text FROM public.branches
             WHERE is_active = true ORDER BY name LIMIT 1))
    INTO v_requester_branch
    FROM public.users
    WHERE id = NEW.requested_by;

  INSERT INTO public.notifications
    (target_branch_id, target_user_id, type, title, body, data)
  VALUES (
    COALESCE(v_requester_branch, '—'),
    NEW.requested_by,                        -- uuid, без ::text
    'systemAlert',
    'Ваша заявка ' || v_decision,
    v_action_label || ' — ' || v_decision
      || ' директором ' || COALESCE(v_reviewer_name, '—') || '.'
      || COALESCE(' Комментарий: ' || NEW.review_note, ''),
    jsonb_build_object(
      'approvalId', NEW.id::text,
      'action', NEW.action::text,
      'status', NEW.status::text,
      'reviewerId', NEW.reviewed_by::text
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_on_approval_decided_trg ON public.pending_approvals;
CREATE TRIGGER notify_on_approval_decided_trg
  AFTER UPDATE OF status ON public.pending_approvals
  FOR EACH ROW
  EXECUTE FUNCTION private.notify_on_approval_decided();


-- ─── 4. notify on client deposit/debit (→ cross-branch) ──────
CREATE OR REPLACE FUNCTION private.notify_on_client_tx()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_branch_id text;                   -- clients.branch_id is text
  v_client_name text;
  v_operator_branches text[];
  v_op_name text;
  v_op_label text;
BEGIN
  IF NEW.conversion_id IS NOT NULL THEN RETURN NEW; END IF;

  SELECT branch_id, name INTO v_client_branch_id, v_client_name
    FROM public.clients
    WHERE id = NEW.client_id;
  IF v_client_branch_id IS NULL OR v_client_branch_id = '' THEN
    RETURN NEW;
  END IF;

  SELECT assigned_branch_ids, COALESCE(display_name, email)
    INTO v_operator_branches, v_op_name
    FROM public.users WHERE id = NEW.created_by;

  -- Если оператор работает в филиале клиента — не дублируем.
  IF v_operator_branches IS NOT NULL
     AND v_client_branch_id = ANY(v_operator_branches) THEN
    RETURN NEW;
  END IF;

  v_op_label := CASE NEW.type
    WHEN 'deposit' THEN 'Пополнение'
    WHEN 'debit'   THEN 'Списание'
    ELSE NEW.type
  END;

  INSERT INTO public.notifications
    (target_branch_id, type, title, body, data)
  VALUES (
    v_client_branch_id,                      -- уже text
    'systemAlert',
    v_op_label || ' клиента ' || COALESCE(v_client_name, '—'),
    COALESCE(v_op_name, 'Бухгалтер') || ' провёл '
      || lower(v_op_label) || ' '
      || to_char(NEW.amount::numeric, 'FM999G999G990D00') || ' ' || NEW.currency
      || COALESCE(' — ' || NEW.description, '') || '.',
    jsonb_build_object(
      'clientId', NEW.client_id::text,
      'txId', NEW.id::text,
      'type', NEW.type,
      'amount', NEW.amount,
      'currency', NEW.currency,
      'operatorId', NEW.created_by::text
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_on_client_tx_trg ON public.client_transactions;
CREATE TRIGGER notify_on_client_tx_trg
  AFTER INSERT ON public.client_transactions
  FOR EACH ROW
  EXECUTE FUNCTION private.notify_on_client_tx();

COMMIT;
