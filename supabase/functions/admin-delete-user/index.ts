// Supabase Edge Function: admin-delete-user
//
// Deletes a user (auth account + profile) on behalf of a logged-in
// creator or director.
//   - Creator: may delete any non-root user (root farruh@gmail.com is
//     protected, and the last active creator cannot be removed).
//   - Director: may delete only accountants.
// Uses the service_role key to call auth.admin.deleteUser; the
// public.users row is removed first via the admin_delete_user RPC
// (which audits the action). public.users → auth.users uses ON DELETE
// CASCADE, so removing the auth row also sweeps any leftover row.
//
// Invoked from Flutter as:
//   supabase.functions.invoke('admin-delete-user', body: { userId, reason? })

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';

interface DeleteUserBody {
  userId: string;
  reason?: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

    const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
    const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY');
    if (!SUPABASE_URL || !SERVICE_KEY || !ANON_KEY) {
      return json({ error: 'Server misconfigured (missing env)' }, 500);
    }

    // 1. Verify caller JWT
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) return json({ error: 'Unauthorized' }, 401);
    const callerId = userData.user.id;

    const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // 2. Confirm caller role (defence in depth — RPC checks the same)
    const { data: callerRow, error: callerErr } = await admin
      .from('users')
      .select('role, is_active')
      .eq('id', callerId)
      .single();
    if (callerErr || !callerRow) {
      return json({ error: 'Caller profile not found' }, 403);
    }
    const callerRole = callerRow.role;
    if (
      callerRow.is_active === false ||
      (callerRole !== 'creator' && callerRole !== 'director')
    ) {
      return json({ error: 'Forbidden — creator or director only' }, 403);
    }

    // 3. Validate body
    const body = (await req.json()) as DeleteUserBody;
    const targetId = (body.userId || '').trim();
    const reason = (body.reason || '').trim() || null;
    if (!targetId) return json({ error: 'userId is required' }, 400);
    if (targetId === callerId) {
      return json({ error: 'Нельзя удалить самого себя' }, 400);
    }

    // 4. Lookup target so we can give a clear message if director hits a
    //    creator/director (the RPC would also reject, but this is friendlier).
    const { data: targetRow, error: targetErr } = await admin
      .from('users')
      .select('role, email')
      .eq('id', targetId)
      .single();
    if (targetErr || !targetRow) {
      return json({ error: 'Пользователь не найден' }, 404);
    }
    if (callerRole === 'director' && targetRow.role !== 'accountant') {
      return json(
        { error: 'Director может удалять только бухгалтеров' },
        403,
      );
    }

    // 5. Защитные проверки в Edge Function (на случай если RPC не
    //    задеплоен — миграция 013 могла ещё не применяться).
    if ((targetRow.email || '').toLowerCase() === 'farruh@gmail.com') {
      return json({ error: 'Корневой creator не может быть удалён' }, 403);
    }
    if (targetRow.role === 'creator') {
      const { count } = await admin
        .from('users')
        .select('id', { count: 'exact', head: true })
        .eq('role', 'creator')
        .eq('is_active', true)
        .neq('id', targetId);
      if ((count ?? 0) === 0) {
        return json(
          { error: 'Нельзя удалить последнего активного Creator-а' },
          400,
        );
      }
    }

    // 6. Best-effort audit через RPC. Если 013 не применена — RPC
    //    отсутствует, ловим ошибку и продолжаем: реальный delete
    //    делает service_role на следующем шаге.
    try {
      await userClient.rpc('admin_delete_user', {
        p_user_id: targetId,
        p_reason: reason,
      });
    } catch (e) {
      // Свалимся на fallback ниже — это не блокирующая операция.
      console.warn('admin_delete_user RPC failed (fallback to direct delete):', e);
    }

    // 7. Auth account delete — основной путь, всегда работает с
    //    service_role-ключом. public.users удалится каскадно через FK.
    const { error: authErr } = await admin.auth.admin.deleteUser(targetId);
    if (authErr) {
      return json({ error: friendly(authErr.message) }, 400);
    }

    // 8. Подстраховка — если по какой-то причине RPC не отработала
    //    и trigger ON DELETE CASCADE на public.users не сработал,
    //    добиваем строку профиля напрямую через service_role.
    await admin.from('users').delete().eq('id', targetId);

    return json({ success: true });
  } catch (e) {
    return json({ error: `Unexpected: ${(e as Error).message}` }, 500);
  }
});

function friendly(raw: string): string {
  const s = raw.toLowerCase();
  if (s.includes('not found')) return 'Пользователь уже удалён';
  if (s.includes('forbidden') || s.includes('unauthorized')) {
    return 'Недостаточно прав для удаления (проверьте service_role)';
  }
  return raw;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
