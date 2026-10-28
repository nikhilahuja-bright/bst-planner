// BST Planner – Edge Function "invite-member"
//
// POST /functions/v1/invite-member
//   headers: Authorization: Bearer <signed-in user's JWT>   (supabase.functions.invoke adds it)
//   body:    { "board_id": "<uuid>", "email": "person@company.com", "role": "editor" | "viewer" | "owner",
//              "redirect_to": "https://your-app.example/bst-planner.html" }
//
// 1. Verifies the caller's JWT and that the caller is an OWNER of the board
//    (the same rule as the board_members RLS policies in setup.sql).
// 2. Adds / updates the board_members row (as the caller, so RLS and the audit
//    columns apply).
// 3. Sends a login e-mail: auth.admin.inviteUserByEmail() for new people, or a
//    magic link (signInWithOtp, no new user) if the account already exists.
//
// The service_role key is read ONLY from this function's environment
// (SUPABASE_SERVICE_ROLE_KEY is injected automatically by Supabase). It is never
// sent to, or stored in, the browser app.
//
// Deploy: supabase functions deploy invite-member --no-verify-jwt
//   (--no-verify-jwt is fine: the function checks the JWT itself with auth.getUser,
//    which also works with the new asymmetric JWT signing keys.)

import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const ROLES = new Set(['owner', 'editor', 'viewer']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json(405, { ok: false, error: 'method_not_allowed', message: 'Use POST.' });

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
  const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY');
  const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!SUPABASE_URL || !ANON_KEY || !SERVICE_KEY) {
    return json(500, { ok: false, error: 'not_configured', message: 'Function environment is missing SUPABASE_URL / keys.' });
  }

  // --- 1. Who is calling? -------------------------------------------------
  const authHeader = req.headers.get('Authorization') ?? '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!jwt) return json(401, { ok: false, error: 'unauthorized', message: 'Sign in first.' });

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userData?.user) return json(401, { ok: false, error: 'unauthorized', message: 'Invalid or expired session.' });
  const caller = userData.user;

  // --- 2. Validate input --------------------------------------------------
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { ok: false, error: 'bad_request', message: 'Body must be JSON.' }); }
  const boardId = String(body.board_id ?? '');
  const email = String(body.email ?? '').trim().toLowerCase();
  const role = String(body.role ?? 'editor');
  const redirectTo = typeof body.redirect_to === 'string' && /^https?:\/\//.test(body.redirect_to) ? body.redirect_to : undefined;
  if (!UUID_RE.test(boardId)) return json(400, { ok: false, error: 'bad_request', message: 'board_id must be a UUID.' });
  if (!EMAIL_RE.test(email) || email.length > 320) return json(400, { ok: false, error: 'bad_email', message: 'Enter a valid email address.' });
  if (!ROLES.has(role)) return json(400, { ok: false, error: 'bad_role', message: 'role must be owner, editor or viewer.' });

  // --- 3. Is the caller an owner of this board? (same rule as RLS) ---------
  const { data: me, error: meErr } = await admin.from('board_members')
    .select('role').eq('board_id', boardId).eq('user_id', caller.id).maybeSingle();
  if (meErr) return json(500, { ok: false, error: 'db_error', message: meErr.message });
  if (!me || me.role !== 'owner') {
    return json(403, { ok: false, error: 'forbidden', message: 'Only owners of this board can invite people.' });
  }

  // --- 4. Add / update the member row AS THE CALLER (RLS + audit columns) --
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data: existing } = await admin.from('board_members')
    .select('id, role, user_id').eq('board_id', boardId).eq('email', email).maybeSingle();
  let member;
  if (existing) {
    if (existing.role !== role) {
      const { data, error } = await asCaller.from('board_members').update({ role }).eq('id', existing.id).select('id, email, role, user_id').single();
      if (error) return json(error.code === '42501' ? 403 : 400, { ok: false, error: 'db_error', message: error.message });
      member = data;
    } else member = { id: existing.id, email, role: existing.role, user_id: existing.user_id };
  } else {
    const { data, error } = await asCaller.from('board_members').insert({ board_id: boardId, email, role }).select('id, email, role, user_id').single();
    if (error) return json(error.code === '42501' ? 403 : 400, { ok: false, error: 'db_error', message: error.message });
    member = data;
  }
  const alreadyMember = !!existing;

  // --- 5. Send the login e-mail -------------------------------------------
  // New person → invite e-mail (creates the auth user; the pending invite is
  // linked by the bst_on_auth_user trigger). Existing account → magic link.
  const inv = await admin.auth.admin.inviteUserByEmail(email, { redirectTo });
  if (!inv.error) {
    return json(200, { ok: true, status: 'invited', email_sent: true, already_member: alreadyMember, member,
      message: `Invitation e-mail sent to ${email}.` });
  }
  const exists = inv.error.status === 422 || /already|registered|exists/i.test(inv.error.message ?? '') ||
    (inv.error as { code?: string }).code === 'email_exists';
  if (exists) {
    const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
    const otp = await anon.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo: redirectTo } });
    if (!otp.error) {
      return json(200, { ok: true, status: 'magic_link_sent', email_sent: true, already_member: alreadyMember, member,
        message: `${email} already has an account; a sign-in link was sent.` });
    }
    return json(200, { ok: true, status: 'added', email_sent: false, already_member: alreadyMember, member,
      email_error: otp.error.message, message: `${email} was added, but no e-mail could be sent (${otp.error.message}). Share the app link instead.` });
  }
  // e.g. e-mail rate limit / SMTP not configured: membership is still saved.
  return json(200, { ok: true, status: 'added', email_sent: false, already_member: alreadyMember, member,
    email_error: inv.error.message, message: `${email} was added, but the invite e-mail failed (${inv.error.message}). Share the app link instead.` });
});
