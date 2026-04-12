import React, { useEffect, useState } from 'react';
import { useUsers, type UserRow } from '../hooks/useAdmin';

export default function UsersPage() {
  const { users, total, loading, fetchUsers, banUser, unbanUser, setRole } = useUsers();
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<'all' | 'banned' | 'pro' | 'admin'>('all');
  const [page, setPage] = useState(1);
  const perPage = 25;

  useEffect(() => {
    fetchUsers(page, perPage, search, filter);
  }, [page, filter]);

  function handleSearch() {
    setPage(1);
    fetchUsers(1, perPage, search, filter);
  }

  async function handleBan(user: UserRow) {
    const reason = prompt('Ban reason:');
    if (!reason) return;
    await banUser(user.id, reason);
    fetchUsers(page, perPage, search, filter);
  }

  async function handleUnban(user: UserRow) {
    await unbanUser(user.id);
    fetchUsers(page, perPage, search, filter);
  }

  async function handleRoleChange(user: UserRow, newRole: string) {
    await setRole(user.id, newRole);
    fetchUsers(page, perPage, search, filter);
  }

  const totalPages = Math.ceil(total / perPage);

  return (
    <div className="p-6 space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Users</h1>
        <p className="text-sm text-gray-500">{total.toLocaleString()} total users</p>
      </div>

      {/* Search + Filters */}
      <div className="flex flex-wrap gap-3">
        <div className="flex-1 min-w-[200px]">
          <form
            onSubmit={(e) => {
              e.preventDefault();
              handleSearch();
            }}
            className="flex gap-2"
          >
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search by username or email..."
              className="input-dark flex-1"
            />
            <button type="submit" className="btn-primary">
              Search
            </button>
          </form>
        </div>
        <div className="flex gap-1 bg-gray-900 rounded-lg p-1">
          {(['all', 'pro', 'admin', 'banned'] as const).map((f) => (
            <button
              key={f}
              onClick={() => {
                setFilter(f);
                setPage(1);
              }}
              className={`px-3 py-1.5 rounded-md text-sm transition ${
                filter === f
                  ? 'bg-brand-600 text-white'
                  : 'text-gray-400 hover:text-white'
              }`}
            >
              {f.charAt(0).toUpperCase() + f.slice(1)}
            </button>
          ))}
        </div>
      </div>

      {/* Table */}
      <div className="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
                <th className="text-left px-5 py-3">User</th>
                <th className="text-left px-5 py-3">Role</th>
                <th className="text-left px-5 py-3">Subscription</th>
                <th className="text-left px-5 py-3">Status</th>
                <th className="text-left px-5 py-3">Joined</th>
                <th className="text-right px-5 py-3">Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <tr key={i} className="table-row">
                    <td colSpan={6} className="px-5 py-4">
                      <div className="h-4 bg-gray-800 rounded animate-pulse w-3/4" />
                    </td>
                  </tr>
                ))
              ) : users.length === 0 ? (
                <tr>
                  <td colSpan={6} className="px-5 py-12 text-center text-gray-500">
                    No users found
                  </td>
                </tr>
              ) : (
                users.map((u) => (
                  <tr key={u.id} className="table-row">
                    <td className="px-5 py-3">
                      <p className="font-medium">{u.username || '—'}</p>
                      <p className="text-xs text-gray-500">{u.email}</p>
                      <p className="text-xs text-gray-600 font-mono">{u.id.slice(0, 8)}…</p>
                    </td>
                    <td className="px-5 py-3">
                      <select
                        value={u.role}
                        onChange={(e) => handleRoleChange(u, e.target.value)}
                        className="bg-transparent border border-gray-700 rounded px-2 py-1 text-xs"
                      >
                        <option value="free">Free</option>
                        <option value="pro">Pro</option>
                        <option value="creator">Creator</option>
                        <option value="moderator">Moderator</option>
                        <option value="admin">Admin</option>
                        <option value="superadmin">Superadmin</option>
                      </select>
                    </td>
                    <td className="px-5 py-3">
                      {u.subscription_tier ? (
                        <span className="badge badge-yellow">
                          {u.subscription_tier} ({u.subscription_status})
                        </span>
                      ) : (
                        <span className="badge badge-gray">Free</span>
                      )}
                    </td>
                    <td className="px-5 py-3">
                      {u.banned ? (
                        <span className="badge badge-red">Banned</span>
                      ) : u.shadowbanned ? (
                        <span className="badge badge-yellow">Shadowbanned</span>
                      ) : (
                        <span className="badge badge-green">Active</span>
                      )}
                    </td>
                    <td className="px-5 py-3 text-gray-400 text-xs">
                      {new Date(u.created_at).toLocaleDateString()}
                    </td>
                    <td className="px-5 py-3 text-right">
                      {u.banned ? (
                        <button onClick={() => handleUnban(u)} className="text-xs text-green-400 hover:text-green-300">
                          Unban
                        </button>
                      ) : (
                        <button onClick={() => handleBan(u)} className="text-xs text-red-400 hover:text-red-300">
                          Ban
                        </button>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {totalPages > 1 && (
          <div className="px-5 py-3 border-t border-gray-800 flex items-center justify-between text-sm">
            <span className="text-gray-500">
              Page {page} of {totalPages}
            </span>
            <div className="flex gap-2">
              <button
                onClick={() => setPage(Math.max(1, page - 1))}
                disabled={page <= 1}
                className="btn-ghost text-xs disabled:opacity-30"
              >
                ← Prev
              </button>
              <button
                onClick={() => setPage(Math.min(totalPages, page + 1))}
                disabled={page >= totalPages}
                className="btn-ghost text-xs disabled:opacity-30"
              >
                Next →
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
