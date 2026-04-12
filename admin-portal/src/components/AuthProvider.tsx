import React, { createContext, useContext } from 'react';
import { useAdminAuth } from '../hooks/useAdmin';

interface AuthCtx {
  admin: { id: string; email: string } | null;
  loading: boolean;
  login: (email: string, password: string) => Promise<boolean>;
  logout: () => Promise<void>;
}

const Ctx = createContext<AuthCtx>({
  admin: null,
  loading: true,
  login: async () => false,
  logout: async () => {},
});

export function AdminAuthProvider({ children }: { children: React.ReactNode }) {
  const auth = useAdminAuth();
  return <Ctx.Provider value={auth}>{children}</Ctx.Provider>;
}

export const useAuth = () => useContext(Ctx);
