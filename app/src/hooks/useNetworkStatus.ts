/**
 * useNetworkStatus — Simple connectivity check.
 *
 * Polls a lightweight endpoint every 15s to determine
 * if the device can reach Supabase. Exposes `isOnline`.
 */

import { useEffect, useRef, useState } from 'react';
import { AppState, type AppStateStatus } from 'react-native';

const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL!;
const POLL_INTERVAL_MS = 15_000;

export function useNetworkStatus() {
  const [isOnline, setIsOnline] = useState(true);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    const check = async () => {
      try {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 5000);
        await fetch(`${SUPABASE_URL}/rest/v1/`, {
          method: 'HEAD',
          signal: controller.signal,
          headers: { apikey: process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY! },
        });
        clearTimeout(timeout);
        setIsOnline(true);
      } catch {
        setIsOnline(false);
      }
    };

    check();
    intervalRef.current = setInterval(check, POLL_INTERVAL_MS);

    const handleAppState = (state: AppStateStatus) => {
      if (state === 'active') check();
    };

    const sub = AppState.addEventListener('change', handleAppState);

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
      sub.remove();
    };
  }, []);

  return { isOnline };
}

export default useNetworkStatus;
