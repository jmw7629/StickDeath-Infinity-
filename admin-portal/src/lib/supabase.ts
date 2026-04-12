import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseServiceKey = import.meta.env.VITE_SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseServiceKey) {
  throw new Error('Missing Supabase env vars — check .env');
}

/** Admin client uses service_role key for full access (bypasses RLS). */
export const supabase = createClient(supabaseUrl, supabaseServiceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

/** Auth-scoped client for admin login. */
export const authClient = createClient(
  supabaseUrl,
  import.meta.env.VITE_SUPABASE_ANON_KEY ?? supabaseServiceKey,
);

export default supabase;
