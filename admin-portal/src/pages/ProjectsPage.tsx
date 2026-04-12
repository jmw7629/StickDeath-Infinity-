import React, { useEffect, useState } from 'react';
import { useProjects } from '../hooks/useAdmin';

export default function ProjectsPage() {
  const { projects, total, loading, fetchProjects, deleteProject, featureProject } = useProjects();
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(1);
  const perPage = 25;

  useEffect(() => {
    fetchProjects(page, perPage, search);
  }, [page]);

  function handleSearch() {
    setPage(1);
    fetchProjects(1, perPage, search);
  }

  async function handleDelete(projectId: number) {
    if (!confirm('Delete this project? This soft-deletes it.')) return;
    await deleteProject(projectId);
    fetchProjects(page, perPage, search);
  }

  async function handleFeature(projectId: number) {
    await featureProject(projectId);
    fetchProjects(page, perPage, search);
  }

  const totalPages = Math.ceil(total / perPage);

  return (
    <div className="p-6 space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Projects</h1>
        <p className="text-sm text-gray-500">{total.toLocaleString()} total projects</p>
      </div>

      {/* Search */}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          handleSearch();
        }}
        className="flex gap-2 max-w-md"
      >
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search by title..."
          className="input-dark flex-1"
        />
        <button type="submit" className="btn-primary">
          Search
        </button>
      </form>

      {/* Table */}
      <div className="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
              <th className="text-left px-5 py-3">ID</th>
              <th className="text-left px-5 py-3">Title</th>
              <th className="text-left px-5 py-3">Canvas</th>
              <th className="text-left px-5 py-3">FPS</th>
              <th className="text-left px-5 py-3">Status</th>
              <th className="text-left px-5 py-3">Created</th>
              <th className="text-right px-5 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <tr key={i} className="table-row">
                  <td colSpan={7} className="px-5 py-4">
                    <div className="h-4 bg-gray-800 rounded animate-pulse" />
                  </td>
                </tr>
              ))
            ) : projects.length === 0 ? (
              <tr>
                <td colSpan={7} className="px-5 py-12 text-center text-gray-500">
                  No projects found
                </td>
              </tr>
            ) : (
              projects.map((p) => (
                <tr key={p.id} className="table-row">
                  <td className="px-5 py-3 font-mono text-xs text-gray-400">#{p.id}</td>
                  <td className="px-5 py-3 font-medium">{p.title}</td>
                  <td className="px-5 py-3 text-gray-400 text-xs">
                    {p.canvas_width}×{p.canvas_height}
                  </td>
                  <td className="px-5 py-3 text-gray-400">{p.fps}</td>
                  <td className="px-5 py-3">
                    <span
                      className={`badge ${
                        p.status === 'published'
                          ? 'badge-green'
                          : p.status === 'featured'
                            ? 'badge-yellow'
                            : p.status === 'deleted'
                              ? 'badge-red'
                              : 'badge-gray'
                      }`}
                    >
                      {p.status}
                    </span>
                  </td>
                  <td className="px-5 py-3 text-gray-400 text-xs">
                    {new Date(p.created_at).toLocaleDateString()}
                  </td>
                  <td className="px-5 py-3 text-right space-x-2">
                    {p.status !== 'featured' && (
                      <button
                        onClick={() => handleFeature(p.id)}
                        className="text-xs text-yellow-400 hover:text-yellow-300"
                      >
                        ⭐ Feature
                      </button>
                    )}
                    {p.status !== 'deleted' && (
                      <button
                        onClick={() => handleDelete(p.id)}
                        className="text-xs text-red-400 hover:text-red-300"
                      >
                        Delete
                      </button>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>

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
