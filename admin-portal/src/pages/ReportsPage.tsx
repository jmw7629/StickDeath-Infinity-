import React, { useEffect, useState } from 'react';
import { useReports } from '../hooks/useAdmin';
import { useAuth } from '../components/AuthProvider';

export default function ReportsPage() {
  const { reports, total, loading, fetchReports, resolveReport, dismissReport } = useReports();
  const { admin } = useAuth();
  const [status, setStatus] = useState<'pending' | 'resolved' | 'dismissed' | 'all'>('pending');
  const [page, setPage] = useState(1);
  const perPage = 25;

  useEffect(() => {
    fetchReports(page, perPage, status);
  }, [page, status]);

  async function handleResolve(reportId: number) {
    const note = prompt('Resolution note:');
    if (!note || !admin) return;
    await resolveReport(reportId, admin.id, note);
    fetchReports(page, perPage, status);
  }

  async function handleDismiss(reportId: number) {
    if (!confirm('Dismiss this report?')) return;
    await dismissReport(reportId);
    fetchReports(page, perPage, status);
  }

  return (
    <div className="p-6 space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Reports</h1>
        <p className="text-sm text-gray-500">{total} reports</p>
      </div>

      {/* Status Filter */}
      <div className="flex gap-1 bg-gray-900 rounded-lg p-1 w-fit">
        {(['pending', 'resolved', 'dismissed', 'all'] as const).map((s) => (
          <button
            key={s}
            onClick={() => {
              setStatus(s);
              setPage(1);
            }}
            className={`px-3 py-1.5 rounded-md text-sm transition ${
              status === s
                ? 'bg-brand-600 text-white'
                : 'text-gray-400 hover:text-white'
            }`}
          >
            {s.charAt(0).toUpperCase() + s.slice(1)}
          </button>
        ))}
      </div>

      {/* Reports Table */}
      <div className="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
              <th className="text-left px-5 py-3">ID</th>
              <th className="text-left px-5 py-3">Type</th>
              <th className="text-left px-5 py-3">Reason</th>
              <th className="text-left px-5 py-3">Status</th>
              <th className="text-left px-5 py-3">Date</th>
              <th className="text-right px-5 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 3 }).map((_, i) => (
                <tr key={i} className="table-row">
                  <td colSpan={6} className="px-5 py-4">
                    <div className="h-4 bg-gray-800 rounded animate-pulse" />
                  </td>
                </tr>
              ))
            ) : reports.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-5 py-12 text-center text-gray-500">
                  {status === 'pending' ? '🎉 No pending reports!' : 'No reports found'}
                </td>
              </tr>
            ) : (
              reports.map((r) => (
                <tr key={r.id} className="table-row">
                  <td className="px-5 py-3 font-mono text-xs text-gray-400">#{r.id}</td>
                  <td className="px-5 py-3">
                    <span className="badge badge-blue">{r.target_type}</span>
                  </td>
                  <td className="px-5 py-3">
                    <p className="font-medium">{r.reason}</p>
                    {r.description && (
                      <p className="text-xs text-gray-500 mt-0.5 line-clamp-2">
                        {r.description}
                      </p>
                    )}
                  </td>
                  <td className="px-5 py-3">
                    <span
                      className={`badge ${
                        r.status === 'pending'
                          ? 'badge-yellow'
                          : r.status === 'resolved'
                            ? 'badge-green'
                            : 'badge-gray'
                      }`}
                    >
                      {r.status}
                    </span>
                  </td>
                  <td className="px-5 py-3 text-gray-400 text-xs">
                    {new Date(r.created_at).toLocaleString()}
                  </td>
                  <td className="px-5 py-3 text-right space-x-2">
                    {r.status === 'pending' && (
                      <>
                        <button
                          onClick={() => handleResolve(r.id)}
                          className="text-xs text-green-400 hover:text-green-300"
                        >
                          Resolve
                        </button>
                        <button
                          onClick={() => handleDismiss(r.id)}
                          className="text-xs text-gray-400 hover:text-gray-300"
                        >
                          Dismiss
                        </button>
                      </>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
