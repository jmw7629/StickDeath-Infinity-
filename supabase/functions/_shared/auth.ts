/**
 * Shared auth verification helpers.
 * Extracts and validates user identity from requests.
 */

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { createAdminClient, createUserClient } from './supabase.ts';
import { errorResponse } from './cors.ts';

export interface AuthUser {
  id: string;
  email?: string;
  role?: string;
}

export interface AuthResult {
  user: AuthUser;
  adminClient: SupabaseClient;
  userClient: SupabaseClient;
}

/**
 * Verifies the Authorization header and returns the authenticated user
 * along with both admin and user-scoped Supabase clients.
 */
export async function verifyAuth(req: Request): Promise<AuthResult> {
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    throw new AuthError('Missing Authorization header', 401);
  }

  const token = authHeader.replace('Bearer ', '');
  const adminClient = createAdminClient();

  const {
    data: { user },
    error,
  } = await adminClient.auth.getUser(token);

  if (error || !user) {
    throw new AuthError('Invalid or expired token', 401);
  }

  // Fetch the user's profile to get their role
  const { data: profile } = await adminClient
    .from('users')
    .select('role')
    .eq('id', user.id)
    .single();

  const userClient = createUserClient(authHeader);

  return {
    user: {
      id: user.id,
      email: user.email,
      role: profile?.role ?? 'free',
    },
    adminClient,
    userClient,
  };
}

/**
 * Checks that the authenticated user has admin role.
 */
export function requireAdmin(user: AuthUser): void {
  if (user.role !== 'admin') {
    throw new AuthError('Admin access required', 403);
  }
}

/**
 * Checks that the user has a Pro subscription.
 */
export async function requirePro(
  adminClient: SupabaseClient,
  userId: string,
): Promise<void> {
  const { data: sub } = await adminClient
    .from('subscriptions')
    .select('status')
    .eq('user_id', userId)
    .in('status', ['active', 'trialing'])
    .single();

  if (!sub) {
    throw new AuthError('Pro subscription required', 403);
  }
}

/**
 * Custom error class for auth failures — includes HTTP status code.
 */
export class AuthError extends Error {
  status: number;
  constructor(message: string, status = 401) {
    super(message);
    this.name = 'AuthError';
    this.status = status;
  }
}

/**
 * Verifies a webhook secret from the request headers.
 */
export function verifyWebhookSecret(req: Request, envKey: string): void {
  const secret = req.headers.get('x-webhook-secret');
  const expected = Deno.env.get(envKey);
  if (!expected || secret !== expected) {
    throw new AuthError('Invalid webhook secret', 403);
  }
}
