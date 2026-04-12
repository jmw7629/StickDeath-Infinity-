import React, { useState } from 'react';
import { NavLink, useNavigate } from 'react-router-dom';
import { useAuth } from './AuthProvider';

const NAV = [
  { to: '/', label: 'Dashboard', icon: '📊' },
  { to: '/analytics', label: 'Analytics', icon: '📈' },
  { to: '/users', label: 'Users', icon: '👥' },
  { to: '/reports', label: 'Reports', icon: '🚩' },
  { to: '/projects', label: 'Projects', icon: '🎬' },
  { to: '/audit', label: 'Audit Log', icon: '📋' },
];

export default function Layout({ children }: { children: React.ReactNode }) {
  const { admin, logout } = useAuth();
  const navigate = useNavigate();
  const [collapsed, setCollapsed] = useState(false);

  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <aside
        className={`${
          collapsed ? 'w-16' : 'w-64'
        } bg-gray-900 border-r border-gray-800 flex flex-col transition-all duration-200`}
      >
        {/* Logo */}
        <div className="p-4 border-b border-gray-800 flex items-center gap-3">
          <div className="w-8 h-8 bg-brand-600 rounded-lg flex items-center justify-center text-white font-bold text-sm shrink-0">
            SD
          </div>
          {!collapsed && (
            <div>
              <h1 className="font-bold text-sm">StickDeath ∞</h1>
              <p className="text-xs text-gray-500">Admin Portal</p>
            </div>
          )}
        </div>

        {/* Nav */}
        <nav className="flex-1 p-2 space-y-1">
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.to === '/'}
              className={({ isActive }) =>
                `flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm transition ${
                  isActive
                    ? 'bg-brand-600/20 text-brand-400 font-medium'
                    : 'text-gray-400 hover:bg-gray-800 hover:text-white'
                }`
              }
            >
              <span className="text-lg">{item.icon}</span>
              {!collapsed && <span>{item.label}</span>}
            </NavLink>
          ))}
        </nav>

        {/* Footer */}
        <div className="p-3 border-t border-gray-800">
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-full text-gray-500 hover:text-gray-300 text-xs py-1 mb-2"
          >
            {collapsed ? '→' : '← Collapse'}
          </button>
          {!collapsed && admin && (
            <div className="flex items-center justify-between">
              <span className="text-xs text-gray-500 truncate">{admin.email}</span>
              <button
                onClick={async () => {
                  await logout();
                  navigate('/login');
                }}
                className="text-xs text-red-400 hover:text-red-300"
              >
                Logout
              </button>
            </div>
          )}
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-auto">{children}</main>
    </div>
  );
}
