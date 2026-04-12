import { useState, useEffect, useCallback } from 'react';
import { supabase, authClient } from '../lib/supabase';

// ─── Types ───────────────────────────────────────────────────────

export interface DashboardStats {
  totalUsers: number;
  totalProjects: number;
  totalPosts: number;
  activeSubscriptions: number;
  pendingReports: number;
  dailySignups: number;
  revenue: number;
}

export interface UserRow {
  id: string;
  username: string;
  email: string;
  role: string;
  banned: boolean;
  shadowbanned: boolean;
  subscription_status: string | null;
  subscription_tier: string | null;
  created_at: string;
  onboarded: boolean;
}

export interface ReportRow {
  id: number;
  reporter_id: string;
  reported_user_id: string | null;
  reported_content_id: number | null;
  target_type: string;
  reason: string;
  description: string | null;
  status: string;
  created_at: string;
  resolved_by: string | null;
  resolved_at: string | null;
}

export interface ProjectRow {
  id: number;
  user_id: string;
  title: string;
  status: string;
  canvas_width: number;
  canvas_height: number;
  fps: number;
  created_at: string;
  updated_at: string;
}

export interface AdminAction {
  id: number;
  admin_id: string;
  action_type: string;
  target_type: string;
  target_id: string;
  details: Record<string, unknown>;
  created_at: string;
}

// ─── Auth Hook ───────────────────────────────────────────────────

export function useAdminAuth() {
  const [admin, setAdmin] = useState<{ id: string; email: string } | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    authClient.auth.getSession().then(({ data }) => {
      if (data.session?.user) {
        verifyAdmin(data.session.user.id).then((isAdmin) => {
          if (isAdmin) {
            setAdmin({ id: data.session!.user.id, email: data.session!.user.email ?? '' });
          }
          setLoading(false);
        });
      } else {
        setLoading(false);
      }
    });
  }, []);

  async function verifyAdmin(userId: string): Promise<boolean> {
    const { data } = await supabase
      .from('users')
      .select('role')
      .eq('id', userId)
      .single();
    return data?.role === 'admin' || data?.role === 'superadmin';
  }

  async function login(email: string, password: string): Promise<boolean> {
    const { data, error } = await authClient.auth.signInWithPassword({ email, password });
    if (error || !data.user) return false;

    const isAdmin = await verifyAdmin(data.user.id);
    if (isAdmin) {
      setAdmin({ id: data.user.id, email: data.user.email ?? '' });
      return true;
    }
    await authClient.auth.signOut();
    return false;
  }

  async function logout() {
    await authClient.auth.signOut();
    setAdmin(null);
  }

  return { admin, loading, login, logout };
}

// ─── Dashboard Stats ─────────────────────────────────────────────

export function useDashboardStats() {
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    const [users, projects, posts, subs, reports, today] = await Promise.all([
      supabase.from('users').select('*', { count: 'exact', head: true }),
      supabase.from('studio_projects').select('*', { count: 'exact', head: true }),
      supabase.from('posts').select('*', { count: 'exact', head: true }),
      supabase
        .from('subscriptions')
        .select('*', { count: 'exact', head: true })
        .in('status', ['active', 'trialing']),
      supabase
        .from('reports')
        .select('*', { count: 'exact', head: true })
        .eq('status', 'pending'),
      supabase
        .from('users')
        .select('*', { count: 'exact', head: true })
        .gte('created_at', new Date(Date.now() - 86400000).toISOString()),
    ]);

    setStats({
      totalUsers: users.count ?? 0,
      totalProjects: projects.count ?? 0,
      totalPosts: posts.count ?? 0,
      activeSubscriptions: subs.count ?? 0,
      pendingReports: reports.count ?? 0,
      dailySignups: today.count ?? 0,
      revenue: (subs.count ?? 0) * 4.99,
    });
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return { stats, loading, refresh };
}

// ─── Users Management ────────────────────────────────────────────

export function useUsers() {
  const [users, setUsers] = useState<UserRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);

  async function fetchUsers(
    page = 1,
    perPage = 25,
    search = '',
    filter: 'all' | 'banned' | 'pro' | 'admin' = 'all',
  ) {
    setLoading(true);
    let query = supabase
      .from('users')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range((page - 1) * perPage, page * perPage - 1);

    if (search) query = query.or(`username.ilike.%${search}%,email.ilike.%${search}%`);
    if (filter === 'banned') query = query.eq('banned', true);
    if (filter === 'pro') query = query.eq('subscription_tier', 'pro');
    if (filter === 'admin') query = query.in('role', ['admin', 'superadmin']);

    const { data, count } = await query;
    setUsers((data as UserRow[]) ?? []);
    setTotal(count ?? 0);
    setLoading(false);
  }

  async function banUser(userId: string, reason: string) {
    await supabase.from('users').update({ banned: true }).eq('id', userId);
    await supabase.from('admin_actions').insert({
      admin_id: null,
      action_type: 'ban_user',
      target_type: 'user',
      target_id: userId,
      details: { reason },
    });
  }

  async function unbanUser(userId: string) {
    await supabase.from('users').update({ banned: false }).eq('id', userId);
    await supabase.from('admin_actions').insert({
      admin_id: null,
      action_type: 'unban_user',
      target_type: 'user',
      target_id: userId,
    });
  }

  async function setRole(userId: string, role: string) {
    await supabase.from('users').update({ role }).eq('id', userId);
  }

  return { users, total, loading, fetchUsers, banUser, unbanUser, setRole };
}

// ─── Reports ─────────────────────────────────────────────────────

export function useReports() {
  const [reports, setReports] = useState<ReportRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);

  async function fetchReports(page = 1, perPage = 25, status = 'pending') {
    setLoading(true);
    let query = supabase
      .from('reports')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range((page - 1) * perPage, page * perPage - 1);

    if (status !== 'all') query = query.eq('status', status);

    const { data, count } = await query;
    setReports((data as ReportRow[]) ?? []);
    setTotal(count ?? 0);
    setLoading(false);
  }

  async function resolveReport(reportId: number, adminId: string, note: string) {
    await supabase
      .from('reports')
      .update({
        status: 'resolved',
        resolved_by: adminId,
        resolved_at: new Date().toISOString(),
      })
      .eq('id', reportId);
  }

  async function dismissReport(reportId: number) {
    await supabase.from('reports').update({ status: 'dismissed' }).eq('id', reportId);
  }

  return { reports, total, loading, fetchReports, resolveReport, dismissReport };
}

// ─── Projects ────────────────────────────────────────────────────

export function useProjects() {
  const [projects, setProjects] = useState<ProjectRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);

  async function fetchProjects(page = 1, perPage = 25, search = '') {
    setLoading(true);
    let query = supabase
      .from('studio_projects')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range((page - 1) * perPage, page * perPage - 1);

    if (search) query = query.ilike('title', `%${search}%`);

    const { data, count } = await query;
    setProjects((data as ProjectRow[]) ?? []);
    setTotal(count ?? 0);
    setLoading(false);
  }

  async function deleteProject(projectId: number) {
    await supabase.from('studio_projects').update({ status: 'deleted' }).eq('id', projectId);
  }

  async function featureProject(projectId: number) {
    await supabase.from('studio_projects').update({ status: 'featured' }).eq('id', projectId);
  }

  return { projects, total, loading, fetchProjects, deleteProject, featureProject };
}

// ─── Audit Log ───────────────────────────────────────────────────

export function useAuditLog() {
  const [actions, setActions] = useState<AdminAction[]>([]);
  const [loading, setLoading] = useState(true);

  async function fetchActions(page = 1, perPage = 50) {
    setLoading(true);
    const { data } = await supabase
      .from('admin_actions')
      .select('*')
      .order('created_at', { ascending: false })
      .range((page - 1) * perPage, page * perPage - 1);
    setActions((data as AdminAction[]) ?? []);
    setLoading(false);
  }

  return { actions, loading, fetchActions };
}
