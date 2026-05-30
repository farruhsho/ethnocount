-- ============================================================
-- 025: Accountant branch guard
-- ============================================================
-- Бухгалтер привязан ровно к одному филиалу — попытка создать
-- (или перевыставить) перевод из чужого филиала отбивается на уровне
-- транзакции, минуя любую клиентскую логику.
--
-- creator / director — без ограничений (видят и работают со всеми).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION private.enforce_accountant_from_branch(
  p_from_branch_id uuid
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_role      text;
  v_assigned  text[];
BEGIN
  -- Сервисные вызовы без auth (например, миграции) пропускаем.
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role, assigned_branch_ids
    INTO v_role, v_assigned
  FROM public.users
  WHERE id = v_uid;

  -- Неизвестный пользователь — обычно creator до promote'а, пропускаем.
  IF v_role IS NULL OR v_role <> 'accountant' THEN RETURN; END IF;

  IF v_assigned IS NULL
     OR array_length(v_assigned, 1) IS NULL
     OR NOT (p_from_branch_id::text = ANY(v_assigned)) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Бухгалтер не привязан к филиалу-отправителю. '
            || 'Обратитесь к Creator/Director для назначения филиала.';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.enforce_accountant_from_branch(uuid) TO authenticated;

-- ── Триггер на transfers: INSERT и UPDATE(from_branch_id/from_account_id) ──
CREATE OR REPLACE FUNCTION private.tg_transfers_accountant_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM private.enforce_accountant_from_branch(NEW.from_branch_id);
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.from_branch_id IS DISTINCT FROM OLD.from_branch_id THEN
      PERFORM private.enforce_accountant_from_branch(NEW.from_branch_id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS transfers_accountant_guard ON public.transfers;
CREATE TRIGGER transfers_accountant_guard
  BEFORE INSERT OR UPDATE OF from_branch_id ON public.transfers
  FOR EACH ROW EXECUTE FUNCTION private.tg_transfers_accountant_guard();

-- ── Валидация при назначении филиала: accountant получает ровно один ──
CREATE OR REPLACE FUNCTION private.tg_users_single_branch_for_accountant()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.role = 'accountant' THEN
    IF NEW.assigned_branch_ids IS NULL
       OR array_length(NEW.assigned_branch_ids, 1) IS NULL THEN
      -- Только что созданный аккаунт до назначения — пропускаем,
      -- но запрещаем сохранять >1 филиала.
      RETURN NEW;
    END IF;
    IF array_length(NEW.assigned_branch_ids, 1) > 1 THEN
      RAISE EXCEPTION 'У роли accountant должен быть ровно один филиал (получено: %)',
        array_length(NEW.assigned_branch_ids, 1);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_single_branch_for_accountant ON public.users;
CREATE TRIGGER users_single_branch_for_accountant
  BEFORE INSERT OR UPDATE OF assigned_branch_ids, role ON public.users
  FOR EACH ROW EXECUTE FUNCTION private.tg_users_single_branch_for_accountant();

COMMIT;
