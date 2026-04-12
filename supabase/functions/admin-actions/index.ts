/**
 * admin-actions — Supabase Edge Function
 *
 * Admin-only endpoints for managing the StickDeath Infinity platform:
 *   - Ban/unban users
 *   - Delete content (projects/posts)
 *   - Feature/unfeature posts
 *   - View and resolve reports
 *   - Manage challenges
 *
 * All actions require admin role verification.
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { verifyAuth, requireAdmin, AuthError } from '../_shared/auth.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

type AdminAction =
  | 'ban_user'
  | 'unban_user'
  | 'delete_content'
  | 'feature_post'
  | 'unfeature_post'
  | 'view_reports'
  | 'resolve_report'
  | 'create_challenge'
  | 'update_challenge'
  | 'delete_challenge'
  | 'view_stats';

interface AdminRequest {
  action: AdminAction;
  target_user_id?: string;
  target_content_id?: string;
  target_report_id?: string;
  ban_reason?: string;
  ban_duration_days?: number;
  challenge?: ChallengeData;
  resolution_note?: string;
  page?: number;
  limit?: number;
}

interface ChallengeData {
  id?: string;
  title: string;
  description: string;
  theme: string;
  starts_at: string;
  ends_at: string;
  prize_description?: string;
  rules?: string[];
  featured?: boolean;
}

// ─── Action Handlers ─────────────────────────────────────────────────────────

async function banUser(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  targetUserId: string,
  reason: string,
  durationDays?: number,
): Promise<Record<string, unknown>> {
  // Update user's profile
  const bannedUntil = durationDays
    ? new Date(Date.now() + durationDays * 86400000).toISOString()
    : null; // null = permanent

  await adminClient
    .from('users')
    .update({ banned: true })
    .eq('id', targetUserId);

  // Log the admin action
  await adminClient.from('admin_actions').insert({
    admin_user_id: adminUserId,
    action: 'ban_user',
    target_user_id: targetUserId,
    details: { reason, duration_days: durationDays, banned_until: bannedUntil },
    created_at: new Date().toISOString(),
  });

  // Send notification to the banned user
  await adminClient.from('notifications').insert({
    user_id: targetUserId,
    type: 'account_banned',
    title: 'Account suspended',
    body: `Your account has been suspended${durationDays ? ` for ${durationDays} days` : ''}. Reason: ${reason}`,
    data: { reason, banned_until: bannedUntil },
  });

  return { banned: true, banned_until: bannedUntil };
}

async function unbanUser(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  targetUserId: string,
): Promise<Record<string, unknown>> {
  await adminClient
    .from('users')
    .update({ banned: false })
    .eq('id', targetUserId);

  await adminClient.from('admin_actions').insert({
    admin_user_id: adminUserId,
    action: 'unban_user',
    target_user_id: targetUserId,
    created_at: new Date().toISOString(),
  });

  await adminClient.from('notifications').insert({
    user_id: targetUserId,
    type: 'account_unbanned',
    title: 'Account restored',
    body: 'Your account has been restored. Welcome back!',
  });

  return { unbanned: true };
}

async function deleteContent(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  contentId: string,
): Promise<Record<string, unknown>> {
  // Soft delete — mark as deleted but keep for audit
  const { data: project } = await adminClient
    .from('studio_projects')
    .select('id, user_id, title')
    .eq('id', contentId)
    .single();

  if (!project) {
    throw new Error('Content not found');
  }

  await adminClient
    .from('studio_projects')
    .update({
      is_deleted: true,
      deleted_at: new Date().toISOString(),
      deleted_by: adminUserId,
    })
    .eq('id', contentId);

  // Also soft-delete associated posts
  await adminClient
    .from('posts')
    .update({ is_deleted: true, deleted_at: new Date().toISOString() })
    .eq('project_id', contentId);

  await adminClient.from('admin_actions').insert({
    admin_user_id: adminUserId,
    action: 'delete_content',
    target_content_id: contentId,
    target_user_id: project.user_id,
    details: { title: project.title },
    created_at: new Date().toISOString(),
  });

  // Notify the content owner
  await adminClient.from('notifications').insert({
    user_id: project.user_id,
    type: 'content_removed',
    title: 'Content removed',
    body: `Your project "${project.title}" was removed for violating community guidelines.`,
    data: { project_id: contentId },
  });

  return { deleted: true, project_id: contentId };
}

async function featurePost(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  contentId: string,
  featured: boolean,
): Promise<Record<string, unknown>> {
  await adminClient
    .from('posts')
    .update({
      is_featured: featured,
      featured_at: featured ? new Date().toISOString() : null,
      featured_by: featured ? adminUserId : null,
    })
    .eq('id', contentId);

  await adminClient.from('admin_actions').insert({
    admin_user_id: adminUserId,
    action: featured ? 'feature_post' : 'unfeature_post',
    target_content_id: contentId,
    created_at: new Date().toISOString(),
  });

  // Notify the post owner if featured
  if (featured) {
    const { data: post } = await adminClient
      .from('posts')
      .select('user_id')
      .eq('id', contentId)
      .single();

    if (post) {
      await adminClient.from('notifications').insert({
        user_id: post.user_id,
        type: 'post_featured',
        title: '🌟 Your post was featured!',
        body: 'Your animation has been selected as a featured post. Congratulations!',
        data: { post_id: contentId },
      });
    }
  }

  return { featured, content_id: contentId };
}

async function viewReports(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  page: number,
  limit: number,
): Promise<Record<string, unknown>> {
  const offset = (page - 1) * limit;

  const { data: reports, count } = await adminClient
    .from('reports')
    .select(
      `
      id,
      reporter_id,
      target_type,
      target_id,
      reason,
      description,
      status,
      created_at,
      reporter:users!reporter_id(username, email)
    `,
      { count: 'exact' },
    )
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);

  return {
    reports: reports ?? [],
    total: count ?? 0,
    page,
    limit,
    pages: Math.ceil((count ?? 0) / limit),
  };
}

async function resolveReport(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  reportId: string,
  resolutionNote: string,
): Promise<Record<string, unknown>> {
  await adminClient
    .from('reports')
    .update({
      status: 'resolved',
      resolved_by: adminUserId,
      resolution_note: resolutionNote,
      resolved_at: new Date().toISOString(),
    })
    .eq('id', reportId);

  await adminClient.from('admin_actions').insert({
    admin_user_id: adminUserId,
    action: 'resolve_report',
    details: { report_id: reportId, note: resolutionNote },
    created_at: new Date().toISOString(),
  });

  return { resolved: true, report_id: reportId };
}

async function manageChallenges(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
  adminUserId: string,
  action: 'create' | 'update' | 'delete',
  challenge: ChallengeData,
): Promise<Record<string, unknown>> {
  switch (action) {
    case 'create': {
      const { data, error } = await adminClient
        .from('challenges')
        .insert({
          title: challenge.title,
          description: challenge.description,
          theme: challenge.theme,
          starts_at: challenge.starts_at,
          ends_at: challenge.ends_at,
          prize_description: challenge.prize_description,
          rules: challenge.rules ?? [],
          featured: challenge.featured ?? false,
          created_by: adminUserId,
          created_at: new Date().toISOString(),
        })
        .select()
        .single();

      if (error) throw new Error(error.message);

      await adminClient.from('admin_actions').insert({
        admin_user_id: adminUserId,
        action: 'create_challenge',
        details: { challenge_id: data.id, title: challenge.title },
        created_at: new Date().toISOString(),
      });

      return { created: true, challenge: data };
    }

    case 'update': {
      if (!challenge.id) throw new Error('Challenge ID required for update');

      const { data, error } = await adminClient
        .from('challenges')
        .update({
          title: challenge.title,
          description: challenge.description,
          theme: challenge.theme,
          starts_at: challenge.starts_at,
          ends_at: challenge.ends_at,
          prize_description: challenge.prize_description,
          rules: challenge.rules,
          featured: challenge.featured,
          updated_at: new Date().toISOString(),
        })
        .eq('id', challenge.id)
        .select()
        .single();

      if (error) throw new Error(error.message);

      await adminClient.from('admin_actions').insert({
        admin_user_id: adminUserId,
        action: 'update_challenge',
        details: { challenge_id: challenge.id },
        created_at: new Date().toISOString(),
      });

      return { updated: true, challenge: data };
    }

    case 'delete': {
      if (!challenge.id) throw new Error('Challenge ID required for delete');

      await adminClient.from('challenges').delete().eq('id', challenge.id);

      await adminClient.from('admin_actions').insert({
        admin_user_id: adminUserId,
        action: 'delete_challenge',
        details: { challenge_id: challenge.id },
        created_at: new Date().toISOString(),
      });

      return { deleted: true, challenge_id: challenge.id };
    }
  }
}

async function viewStats(
  adminClient: ReturnType<typeof import('../_shared/supabase.ts').createAdminClient>,
): Promise<Record<string, unknown>> {
  // Gather platform statistics
  const [users, projects, posts, reports, subs] = await Promise.all([
    adminClient.from('users').select('*', { count: 'exact', head: true }),
    adminClient.from('studio_projects').select('*', { count: 'exact', head: true }),
    adminClient.from('posts').select('*', { count: 'exact', head: true }),
    adminClient
      .from('reports')
      .select('*', { count: 'exact', head: true })
      .eq('status', 'pending'),
    adminClient
      .from('subscriptions')
      .select('*', { count: 'exact', head: true })
      .in('status', ['active', 'trialing']),
  ]);

  return {
    total_users: users.count ?? 0,
    total_projects: projects.count ?? 0,
    total_posts: posts.count ?? 0,
    pending_reports: reports.count ?? 0,
    active_subscriptions: subs.count ?? 0,
  };
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  if (req.method !== 'POST') {
    return errorResponse('Method not allowed', 405);
  }

  try {
    const { user, adminClient } = await verifyAuth(req);

    // Enforce admin-only access
    requireAdmin(user);

    const body: AdminRequest = await req.json();
    const { action } = body;

    if (!action) {
      return errorResponse('action is required');
    }

    let result: Record<string, unknown>;

    switch (action) {
      case 'ban_user': {
        if (!body.target_user_id) return errorResponse('target_user_id is required');
        if (!body.ban_reason) return errorResponse('ban_reason is required');
        result = await banUser(
          adminClient,
          user.id,
          body.target_user_id,
          body.ban_reason,
          body.ban_duration_days,
        );
        break;
      }

      case 'unban_user': {
        if (!body.target_user_id) return errorResponse('target_user_id is required');
        result = await unbanUser(adminClient, user.id, body.target_user_id);
        break;
      }

      case 'delete_content': {
        if (!body.target_content_id) return errorResponse('target_content_id is required');
        result = await deleteContent(adminClient, user.id, body.target_content_id);
        break;
      }

      case 'feature_post': {
        if (!body.target_content_id) return errorResponse('target_content_id is required');
        result = await featurePost(adminClient, user.id, body.target_content_id, true);
        break;
      }

      case 'unfeature_post': {
        if (!body.target_content_id) return errorResponse('target_content_id is required');
        result = await featurePost(adminClient, user.id, body.target_content_id, false);
        break;
      }

      case 'view_reports': {
        result = await viewReports(adminClient, body.page ?? 1, body.limit ?? 20);
        break;
      }

      case 'resolve_report': {
        if (!body.target_report_id) return errorResponse('target_report_id is required');
        result = await resolveReport(
          adminClient,
          user.id,
          body.target_report_id,
          body.resolution_note ?? 'Resolved by admin',
        );
        break;
      }

      case 'create_challenge': {
        if (!body.challenge) return errorResponse('challenge data is required');
        result = await manageChallenges(adminClient, user.id, 'create', body.challenge);
        break;
      }

      case 'update_challenge': {
        if (!body.challenge?.id) return errorResponse('challenge.id is required');
        result = await manageChallenges(adminClient, user.id, 'update', body.challenge);
        break;
      }

      case 'delete_challenge': {
        if (!body.challenge?.id) return errorResponse('challenge.id is required');
        result = await manageChallenges(adminClient, user.id, 'delete', body.challenge);
        break;
      }

      case 'view_stats': {
        result = await viewStats(adminClient);
        break;
      }

      default:
        return errorResponse(`Unknown action: ${action}`);
    }

    return jsonResponse({ action, ...result });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.message, err.status);
    }
    console.error('admin-actions error:', err);
    const message = err instanceof Error ? err.message : 'Internal server error';
    return errorResponse(message, 500);
  }
});
