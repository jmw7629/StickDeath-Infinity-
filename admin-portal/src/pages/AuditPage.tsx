import React, { useEffect, useState } from 'react';
import { useAuditLog } from '../hooks/useAdmin';

export default function AuditPage() {
  const { actions, loading, fetchActions } = useAuditLog();
  const [page, setPage] = useState(1);

  useEffect(() => {
    fetchActions(page);
  }, [page]);

  return (
    <div className="p-6 space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Audit Log</h1>
        <p className="text-sm text-gray-500">All admin actions recorded</p>
      </div>

      <div className="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
              <th className="text-left px-5 py-3">Time</th>
              <th className="text-left px-5 py-3">Action</th>
              <th className="text-left px-5 py-3">Target</th>
              <th className="text-left px-5 py-3">Details</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <tr key={i} className="table-row">
                  <td colSpan={4} className="px-5 py-4">
                    <div className="h-4 bg-gray-800 rounded animate-pulse" />
                  </td>
                </tr>
              ))
            ) : actions.length === 0 ? (
              <tr>
                <td colSpan={4} className="px-5 py-12 text-center text-gray-500">
                  No admin actions recorded yet
                </td>
              </tr>
            ) : (
              actions.map((a) => (
                <tr key={a.id} className="table-row">
                  <td className="px-5 py-3 text-gray-400 text-xs whitespace-nowrap">
                    {new Date(a.created_at).toLocaleString()}
                  </td>
                  <td className="px-5 py-3">
                    <span
                      className={`badge ${
                        a.action_type.includes('ban')
                          ? 'badge-red'
                          : a.action_type.includes('feature')
                            ? 'badge-yellow'
                            : a.action_type.includes('resolve')
                              ? 'badge-green'
                              : 'badge-blue'
                      }`}
                    >
                      {a.action_type}
                    </span>
                  </td>
                  <td className="px-5 py-3 font-mono text-xs text-gray-400">
                    {a.target_type}: {a.target_id?.slice(0, 8)}…
                  </td>
                  <td className="px-5 py-3 text-gray-500 text-xs max-w-xs truncate">
                    {a.details ? JSON.stringify(a.details) : '—'}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>

        <div className="px-5 py-3 border-t border-gray-800 flex gap-2 justify-end">
          <button
            onClick={() => setPage(Math.max(1, page - 1))}
            disabled={page <= 1}
            className="btn-ghost text-xs disabled:opacity-30"
          >
            ← Older
          </button>
          <button
            onClick={() => setPage(page + 1)}
            disabled={actions.length < 50}
            className="btn-ghost text-xs disabled:opacity-30"
          >
            Newer →
          </button>
        </div>
      </div>
    </div>
  );
}
