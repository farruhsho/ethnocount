// Supabase Edge Function: admin-create-user
//
// Creates a new auth user on behalf of a logged-in creator.
// - Uses service_role to call auth.admin.createUser (email_confirm: true) so no
//   confirmation email is sent → no SMTP rate limit.
// - Does NOT swap the caller's session (unlike client-side auth.signUp).
// - Trigger public.handle_new_user (migration 008) inserts the baseline
//   public.users row; we then UPDATE with the full profile (role, branches,
//   permissions, display_name).
//
// Invoked from the Flutter client as:
//   supabase.functions.invoke('admin-create-user', body: {...})

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';

interface CreateUserBody {
  email: string;
  password: string;
  displayName: string;
  role: 'accountant' | 'creator';
  assignedBranchIds?: string[];
  permissions?: Record<string, unknown>;
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

    // 2. Confirm caller is a creator
    const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: callerRow, error: callerErr } = await admin
      .from('users')
      .select('role, is_active')
      .eq('id', userData.user.id)
      .single();
    if (callerErr || !callerRow) {
      return json({ error: 'Caller profile not found' }, 403);
    }
    if (callerRow.role !== 'creator' || callerRow.is_active === false) {
      return json({ error: 'Forbidden — creator only' }, 403);
    }

    // 3. Validate body
    const body = (await req.json()) as CreateUserBody;
    const email = (body.email || '').trim().toLowerCase();
    const password = body.password || '';
    const displayName = (body.displayName || '').trim();
    const role = body.role;
    const assignedBranchIds = body.assignedBranchIds ?? [];
    const permissions = body.permissions ?? {};

    if (!email || !email.includes('@')) return json({ error: 'Некорректный email' }, 400);
    if (password.length < 6) return json({ error: 'Пароль минимум 6 символов' }, 400);
    if (displayName.length < 2) return json({ error: 'Имя минимум 2 символа' }, 400);
    if (role !== 'accountant' && role !== 'creator') {
      return json({ error: 'Invalid role' }, 400);
    }

    // 4. Create auth user (no email sent — email_confirm=true)
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { display_name: displayName, signup_role: role },
    });
    if (createErr || !created?.user) {
      return json({ error: friendly(createErr?.message ?? 'Ошибка создания') }, 400);
    }

    const newId = created.user.id;

    // 5. Trigger 008 has inserted a baseline row (role=accountant). Update with full profile.
    const { error: updateErr } = await admin
      .from('users')
      .update({
        display_name: displayName,
        email,
        role,
        assigned_branch_ids: assignedBranchIds,
        permissions,
        is_active: true,
      })
      .eq('id', newId);
    if (updateErr) {
      // Best-effort rollback: delete the auth user we just created
      await admin.auth.admin.deleteUser(newId).catch(() => {});
      return json({ error: `Profile update failed: ${updateErr.message}` }, 500);
    }

    return json({ success: true, userId: newId });
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
    return 'Пользователь с таким email уже существует';
  }
  if (s.includes('weak') || s.includes('password')) {
    return 'Пароль слишком слабый (мин. 6 символов)';
  }
  if (s.includes('invalid') && s.includes('email')) {
    return 'Некорректный email';
  }
  return raw;
}
