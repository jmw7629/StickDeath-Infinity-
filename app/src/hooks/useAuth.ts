/**
 * useAuth — convenience hook for consuming the AuthContext.
 *
 * Throws if used outside <AuthProvider> so you always get a typed value.
 */

import { useContext } from 'react';
import { AuthContext, type AuthState } from '../lib/auth';

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (ctx === undefined) {
    throw new Error('useAuth must be used within an <AuthProvider>');
  }
  return ctx;
}

export default useAuth;
