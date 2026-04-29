// Supabase Edge Function: admin-update-user-email
//
// Меняет email пользователя в auth.users (через auth.admin.updateUserById).
// Срабатывает только когда вызывает creator (или director — но только для
// бухгалтеров). Без этой функции email — read-only, потому что обычным
// SQL обновлять auth.users нельзя.
//
// Также синхронизирует public.users.email, чтобы профиль и auth-аккаунт
// не разъезжались.
//
// Тело: { userId: string, email: string }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';

interface Body {
  userId: string;
  email: string;
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

    // 1. Verify caller
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) return json({ error: 'Unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: callerRow, error: callerErr } = await admin
      .from('users')
      .select('role, is_active')
      .eq('id', userData.user.id)
      .single();
    if (callerErr || !callerRow) return json({ error: 'Caller profile not found' }, 403);
    const callerRole = callerRow.role;
    if (callerRow.is_active === false || (callerRole !== 'creator' && callerRole !== 'director')) {
      return json({ error: 'Forbidden — creator or director only' }, 403);
    }

    // 2. Validate body
    const body = (await req.json()) as Body;
    const targetId = (body.userId || '').trim();
    const newEmail = (body.email || '').trim().toLowerCase();
    if (!targetId) return json({ error: 'userId is required' }, 400);
    if (!newEmail || !newEmail.includes('@')) {
      return json({ error: 'Некорректный email' }, 400);
    }

    // 3. Director may only change accountants' emails
    const { data: targetRow, error: targetErr } = await admin
      .from('users')
      .select('role, email')
      .eq('id', targetId)
      .single();
    if (targetErr || !targetRow) return json({ error: 'Пользователь не найден' }, 404);
    if (callerRole === 'director' && targetRow.role !== 'accountant') {
      return json({ error: 'Director может менять email только бухгалтерам' }, 403);
    }
    if ((targetRow.email || '').toLowerCase() === newEmail) {
      return json({ success: true, unchanged: true });
    }

    // 4. Update auth.users (это в первую очередь — иначе на фронте
    //    появится несинхронизированный профиль).
    const { error: authErr } = await admin.auth.admin.updateUserById(targetId, {
      email: newEmail,
      email_confirm: true, // не отправлять верификацию — admin доверенный
    });
    if (authErr) {
      return json({ error: friendly(authErr.message) }, 400);
    }

    // 5. Sync public.users.email
    const { error: syncErr } = await admin
      .from('users')
      .update({ email: newEmail })
      .eq('id', targetId);
    if (syncErr) {
      return json({
        success: true,
        warning: `Auth email updated; profile sync failed: ${syncErr.message}`,
      });
    }

    return json({ success: true });
  } catch (e) {
    return json({ error: `Unexpected: ${(e as Error).message}` }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function friendly(raw: string): string {
  const s = raw.toLowerCase();
  if (s.includes('already registered') || s.includes('already exists') || s.includes('email_exists')) {
    return 'Этот email уже занят другим пользователем';
  }
  if (s.includes('invalid') && s.includes('email')) return 'Некорректный email';
  return raw;
}
