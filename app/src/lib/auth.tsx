/**
 * Auth Context Provider
 *
 * Wraps the app and exposes the current Supabase session,
 * user profile, and auth helpers (sign in, sign up, sign out, OAuth).
 */

import React, {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from 'react';
import { Alert, Platform } from 'react-native';
import { makeRedirectUri } from 'expo-auth-session';
import * as WebBrowser from 'expo-web-browser';
import type { Session, User, AuthError } from '@supabase/supabase-js';
import { supabase } from './supabase';
import type { Profile } from '../types/database';

// Warm the browser for OAuth on native
if (Platform.OS !== 'web') {
  WebBrowser.maybeCompleteAuthSession();
}

// ── Types ──────────────────────────────────────────────

export interface AuthState {
  /** True while we're checking for an existing session on mount */
  isLoading: boolean;
  /** Current Supabase session (null = signed out) */
  session: Session | null;
  /** Shortcut: session.user */
  user: User | null;
  /** Public profile row for the signed-in user */
  profile: Profile | null;
  /** Sign in with email + password */
  signInWithEmail: (email: string, password: string) => Promise<void>;
  /** Create account with email + password + username */
  signUpWithEmail: (
    email: string,
    password: string,
    username: string
  ) => Promise<void>;
  /** OAuth sign-in (Apple / Google) */
  signInWithOAuth: (provider: 'apple' | 'google') => Promise<void>;
  /** Sign out and clear local session */
  signOut: () => Promise<void>;
  /** Refresh the profile from Supabase */
  refreshProfile: () => Promise<void>;
}

export const AuthContext = createContext<AuthState | undefined>(undefined);

// ── Provider ───────────────────────────────────────────

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [isLoading, setIsLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);

  const user = session?.user ?? null;

  // ── Fetch profile ──────────────────────────────────
  const fetchProfile = useCallback(async (userId: string) => {
    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .single();

      if (error) {
        console.warn('[auth] profile fetch error:', error.message);
        return;
      }
      setProfile(data as Profile);
    } catch (err) {
      console.warn('[auth] profile fetch exception:', err);
    }
  }, []);

  const refreshProfile = useCallback(async () => {
    if (user?.id) {
      await fetchProfile(user.id);
    }
  }, [user?.id, fetchProfile]);

  // ── Session listener ───────────────────────────────
  useEffect(() => {
    // Get initial session
    supabase.auth.getSession().then(({ data: { session: s } }) => {
      setSession(s);
      if (s?.user) fetchProfile(s.user.id);
      setIsLoading(false);
    });

    // Listen for auth state changes
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      if (s?.user) {
        fetchProfile(s.user.id);
      } else {
        setProfile(null);
      }
    });

    return () => subscription.unsubscribe();
  }, [fetchProfile]);

  // ── Email sign-in ──────────────────────────────────
  const signInWithEmail = useCallback(
    async (email: string, password: string) => {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim().toLowerCase(),
        password,
      });
      if (error) throw error;
    },
    []
  );

  // ── Email sign-up ──────────────────────────────────
  const signUpWithEmail = useCallback(
    async (email: string, password: string, username: string) => {
      // 1. Check username availability
      const { data: existing } = await supabase
        .from('profiles')
        .select('id')
        .eq('username', username.trim().toLowerCase())
        .maybeSingle();

      if (existing) {
        throw new Error('Username is already taken. Try another.');
      }

      // 2. Create auth user
      const { data, error } = await supabase.auth.signUp({
        email: email.trim().toLowerCase(),
        password,
        options: {
          data: {
            username: username.trim().toLowerCase(),
            display_name: username.trim(),
          },
        },
      });

      if (error) throw error;

      // Profile row is created by the DB trigger (handle_new_user),
      // but we set the username via user metadata above so the
      // trigger can pick it up.
      if (data.user) {
        await fetchProfile(data.user.id);
      }
    },
    [fetchProfile]
  );

  // ── OAuth sign-in ──────────────────────────────────
  const signInWithOAuth = useCallback(
    async (provider: 'apple' | 'google') => {
      try {
        const redirectTo = makeRedirectUri({
          scheme: 'stickdeath',
          path: 'auth/callback',
        });

        const { data, error } = await supabase.auth.signInWithOAuth({
          provider,
          options: {
            redirectTo,
            skipBrowserRedirect: true,
          },
        });

        if (error) throw error;
        if (!data.url) throw new Error('No OAuth URL returned');

        // Open OAuth flow in system browser
        const result = await WebBrowser.openAuthSessionAsync(
          data.url,
          redirectTo
        );

        if (result.type === 'success' && result.url) {
          // Extract tokens from callback URL
          const url = new URL(result.url);
          const params = new URLSearchParams(
            url.hash ? url.hash.substring(1) : url.search.substring(1)
          );

          const accessToken = params.get('access_token');
          const refreshToken = params.get('refresh_token');

          if (accessToken && refreshToken) {
            const { error: sessionError } = await supabase.auth.setSession({
              access_token: accessToken,
              refresh_token: refreshToken,
            });
            if (sessionError) throw sessionError;
          }
        }
      } catch (err) {
        const message =
          err instanceof Error ? err.message : 'OAuth sign-in failed';
        if (!message.includes('cancel')) {
          Alert.alert('Sign In Error', message);
        }
      }
    },
    []
  );

  // ── Sign out ───────────────────────────────────────
  const signOut = useCallback(async () => {
    const { error } = await supabase.auth.signOut();
    if (error) console.warn('[auth] sign out error:', error.message);
    setSession(null);
    setProfile(null);
  }, []);

  // ── Context value ──────────────────────────────────
  const value = useMemo<AuthState>(
    () => ({
      isLoading,
      session,
      user,
      profile,
      signInWithEmail,
      signUpWithEmail,
      signInWithOAuth,
      signOut,
      refreshProfile,
    }),
    [
      isLoading,
      session,
      user,
      profile,
      signInWithEmail,
      signUpWithEmail,
      signInWithOAuth,
      signOut,
      refreshProfile,
    ]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}
