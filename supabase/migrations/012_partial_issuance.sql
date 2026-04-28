-- ============================================================
-- Migration 012: partial issuance (частичная выдача переводов)
--
-- A confirmed transfer can be issued in multiple parts. Each
-- payout creates a `transfer_issuances` row and bumps
-- `transfers.issued_amount`. The transfer flips to status `issued`
-- only when the cumulative payout equals the credited amount
-- (`converted_amount`).
-- ============================================================

-- ─── Schema additions ───
ALTER TABLE public.transfers
  ADD COLUMN IF NOT EXISTS issued_amount double precision NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.transfer_issuances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid NOT NULL REFERENCES public.transfers(id) ON DELETE CASCADE,
  amount double precision NOT NULL CHECK (amount > 0),
  currency text NOT NULL,
  issued_by uuid NOT NULL REFERENCES auth.users(id),
  issued_at timestamptz NOT NULL DEFAULT now(),
  note text,
  CONSTRAINT transfer_issuances_amount_positive CHECK (amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_transfer_issuances_transfer
  ON public.transfer_issuances (transfer_id, issued_at DESC);

-- RLS: piggyback on transfer access — same branches as the parent transfer
ALTER TABLE public.transfer_issuances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS transfer_issuances_select ON public.transfer_issuances;
CREATE POLICY transfer_issuances_select ON public.transfer_issuances
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.transfers t
      WHERE t.id = transfer_issuances.transfer_id
        AND (
          public.is_creator()
          OR t.from_branch_id::text = ANY((SELECT assigned_branch_ids FROM public.users WHERE id = auth.uid()))
          OR t.to_branch_id::text = ANY((SELECT assigned_branch_ids FROM public.users WHERE id = auth.uid()))
        )
    )
  );

-- ─── Partial-issue RPC (атомарная) ───
CREATE OR REPLACE FUNCTION private.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_remaining double precision;
  v_new_total double precision;
  v_code text;
  v_currency text;
  v_branch_name text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма выдачи должна быть больше нуля';
  END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status NOT IN ('confirmed') THEN
    RAISE EXCEPTION 'Выдача возможна только для подтверждённых переводов (текущий статус: %)', v_transfer.status;
  END IF;

  v_currency := COALESCE(v_transfer.to_currency, v_transfer.currency);
  v_remaining := v_transfer.converted_amount - COALESCE(v_transfer.issued_amount, 0);

  -- Allow tiny float epsilon (1e-6) so users don't get blocked by rounding.
  IF p_amount > v_remaining + 1e-6 THEN
    RAISE EXCEPTION 'Сумма выдачи (%) превышает остаток к выдаче (%)',
      round(p_amount::numeric, 2), round(v_remaining::numeric, 2);
  END IF;

  -- Snap to remainder if within epsilon to avoid trailing fractional cents.
  IF abs(p_amount - v_remaining) < 1e-6 THEN
    p_amount := v_remaining;
  END IF;

  v_new_total := COALESCE(v_transfer.issued_amount, 0) + p_amount;
  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  INSERT INTO transfer_issuances (transfer_id, amount, currency, issued_by, note)
  VALUES (p_transfer_id, p_amount, v_currency, v_user_id, NULLIF(trim(p_note), ''));

  IF v_new_total >= v_transfer.converted_amount - 1e-6 THEN
    -- Last (or only) tranche → close as issued.
    UPDATE transfers SET
      status = 'issued',
      issued_amount = v_transfer.converted_amount,
      issued_by = v_user_id,
      issued_at = now()
    WHERE id = p_transfer_id;

    SELECT name INTO v_branch_name FROM branches WHERE id = v_transfer.to_branch_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' выдан',
        'Перевод ' || to_char(v_transfer.amount::numeric, 'FM999G999G990D00')
          || ' ' || v_transfer.currency
          || ' полностью выдан получателю в ' || COALESCE(v_branch_name, '—'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', v_transfer.amount,
          'currency', v_transfer.currency
        )
      ),
      (
        v_transfer.to_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ' закрыт',
        'Финальная выдача '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || '. Перевод полностью передан.',
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', true
        )
      );

    RETURN jsonb_build_object(
      'success', true,
      'fullyIssued', true,
      'remaining', 0,
      'amount', p_amount
    );
  ELSE
    -- Partial — keep transfer in confirmed, only bump issued_amount.
    UPDATE transfers SET issued_amount = v_new_total WHERE id = p_transfer_id;

    INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
      (
        v_transfer.from_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || ' из ' || to_char(v_transfer.converted_amount::numeric, 'FM999G999G990D00')
          || '. Остаток: ' || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total
        )
      ),
      (
        v_transfer.to_branch_id::text,
        'transfer_issued',
        'Перевод ' || v_code || ': частичная выдача',
        'Выдано '
          || to_char(p_amount::numeric, 'FM999G999G990D00') || ' ' || v_currency
          || ' получателю. Остаток к выдаче: '
          || to_char((v_transfer.converted_amount - v_new_total)::numeric, 'FM999G999G990D00'),
        jsonb_build_object(
          'transferId', p_transfer_id::text,
          'transactionCode', v_code,
          'amount', p_amount,
          'currency', v_currency,
          'finalTranche', false,
          'remaining', v_transfer.converted_amount - v_new_total
        )
      );

    RETURN jsonb_build_object(
      'success', true,
      'fullyIssued', false,
      'remaining', v_transfer.converted_amount - v_new_total,
      'amount', p_amount
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION private.issue_transfer_partial(uuid, double precision, text) TO authenticated;

-- ─── Public wrapper ───
CREATE OR REPLACE FUNCTION public.issue_transfer_partial(
  p_transfer_id uuid,
  p_amount double precision,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER
SET search_path = public
AS $$
  SELECT private.issue_transfer_partial(p_transfer_id, p_amount, p_note);
$$;

GRANT EXECUTE ON FUNCTION public.issue_transfer_partial(uuid, double precision, text) TO authenticated;

-- ─── Reissue full as "issue remaining" ───
-- Old `issue_transfer(p_transfer_id)` becomes equivalent to "issue all remaining".
-- Implemented by delegating to the partial function with the outstanding amount.
CREATE OR REPLACE FUNCTION private.issue_transfer(p_transfer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transfer transfers%ROWTYPE;
  v_remaining double precision;
BEGIN
  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status != 'confirmed' THEN
    RAISE EXCEPTION 'Transfer must be confirmed first';
  END IF;
  v_remaining := v_transfer.converted_amount - COALESCE(v_transfer.issued_amount, 0);
  IF v_remaining <= 0 THEN
    RAISE EXCEPTION 'Нет остатка к выдаче';
  END IF;
  RETURN private.issue_transfer_partial(p_transfer_id, v_remaining, 'Полная выдача остатка');
END;
$$;

-- Backfill existing issued transfers so they show issued_amount = converted_amount
-- (required for the UI "Выдано X из Y" indicator).
UPDATE public.transfers
   SET issued_amount = converted_amount
 WHERE status = 'issued' AND COALESCE(issued_amount, 0) = 0;
