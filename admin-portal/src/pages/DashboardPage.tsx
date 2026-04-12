import React, { useEffect, useState } from 'react';
import { useDashboardStats } from '../hooks/useAdmin';
import { supabase } from '../lib/supabase';

interface RecentUser {
  id: string;
  username: string;
  email: string;
  role: string;
  created_at: string;
}

export default function DashboardPage() {
  const { stats, loading, refresh } = useDashboardStats();
  const [recentUsers, setRecentUsers] = useState<RecentUser[]>([]);

  useEffect(() => {
    supabase
      .from('users')
      .select('id, username, email, role, created_at')
      .order('created_at', { ascending: false })
      .limit(5)
      .then(({ data }) => setRecentUsers((data as RecentUser[]) ?? []));
  }, []);

  const cards = stats
    ? [
        { label: 'Total Users', value: stats.totalUsers.toLocaleString(), icon: '👥', color: 'text-blue-400' },
        { label: 'Projects', value: stats.totalProjects.toLocaleString(), icon: '🎬', color: 'text-purple-400' },
        { label: 'Posts', value: stats.totalPosts.toLocaleString(), icon: '📸', color: 'text-green-400' },
        { label: 'Pro Subscribers', value: stats.activeSubscriptions.toLocaleString(), icon: '⭐', color: 'text-yellow-400' },
        { label: 'Pending Reports', value: stats.pendingReports.toLocaleString(), icon: '🚩', color: stats.pendingReports > 0 ? 'text-red-400' : 'text-gray-400' },
        { label: 'Signups Today', value: stats.dailySignups.toLocaleString(), icon: '📈', color: 'text-cyan-400' },
        { label: 'Est. MRR', value: `$${stats.revenue.toFixed(2)}`, icon: '💰', color: 'text-emerald-400' },
      ]
    : [];

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Dashboard</h1>
          <p className="text-sm text-gray-500">Platform overview</p>
        </div>
        <button onClick={refresh} className="btn-ghost text-sm" disabled={loading}>
          {loading ? 'Loading...' : '↻ Refresh'}
        </button>
      </div>

      {/* Stat Cards */}
      {loading ? (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {Array.from({ length: 7 }).map((_, i) => (
            <div key={i} className="stat-card animate-pulse">
              <div className="h-4 bg-gray-800 rounded w-20 mb-3" />
              <div className="h-8 bg-gray-800 rounded w-16" />
            </div>
          ))}
        </div>
      ) : (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {cards.map((c) => (
            <div key={c.label} className="stat-card">
              <div className="flex items-center gap-2 text-sm text-gray-400 mb-1">
                <span>{c.icon}</span>
                <span>{c.label}</span>
              </div>
              <p className={`text-2xl font-bold ${c.color}`}>{c.value}</p>
            </div>
          ))}
        </div>
      )}

      {/* Recent Users */}
      <div className="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
        <div className="px-5 py-4 border-b border-gray-800">
          <h2 className="font-semibold">Recent Signups</h2>
        </div>
        <table className="w-full text-sm">
          <thead>
            <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
              <th className="text-left px-5 py-3">User</th>
              <th className="text-left px-5 py-3">Role</th>
              <th className="text-left px-5 py-3">Joined</th>
            </tr>
          </thead>
          <tbody>
            {recentUsers.map((u) => (
              <tr key={u.id} className="table-row">
                <td className="px-5 py-3">
                  <p className="font-medium">{u.username || 'No username'}</p>
                  <p className="text-xs text-gray-500">{u.email}</p>
                </td>
                <td className="px-5 py-3">
                  <span
                    className={`badge ${
                      u.role === 'admin' || u.role === 'superadmin'
                        ? 'badge-red'
                        : u.role === 'pro'
                          ? 'badge-yellow'
                          : 'badge-gray'
                    }`}
                  >
                    {u.role}
                  </span>
                </td>
                <td className="px-5 py-3 text-gray-400">
                  {new Date(u.created_at).toLocaleDateString()}
                </td>
              </tr>
            ))}
            {recentUsers.length === 0 && (
              <tr>
                <td colSpan={3} className="px-5 py-8 text-center text-gray-500">
                  No users yet
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
