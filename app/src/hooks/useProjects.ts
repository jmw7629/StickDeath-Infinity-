/**
 * useProjects — CRUD hook for studio projects.
 *
 * Provides loading state, project list, and mutation helpers
 * backed by the Supabase `studio_projects` table.
 */

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from './useAuth';
import type { StudioProject, ProjectData, ProjectVisibility } from '../types/database';

// ── Default empty project data ─────────────────────────
const defaultProjectData: ProjectData = {
  version: 1,
  settings: {
    background_color: '#0A0A0F',
    grid_enabled: true,
    grid_size: 24,
    onion_skin_enabled: true,
    onion_skin_opacity: 0.3,
    onion_skin_frames: 2,
  },
  layers: [
    {
      id: 'layer-1',
      name: 'Layer 1',
      visible: true,
      locked: false,
      opacity: 1,
      order: 0,
      frames: [
        {
          id: 'frame-1',
          index: 0,
          duration_ms: 83, // ~12 fps
          elements: [],
        },
      ],
    },
  ],
  audio_tracks: [],
};

// ── Types ──────────────────────────────────────────────

export interface UseProjectsReturn {
  /** User's projects, newest first */
  projects: StudioProject[];
  /** True while initial fetch is in progress */
  isLoading: boolean;
  /** Last error, if any */
  error: string | null;
  /** Re-fetch project list */
  refresh: () => Promise<void>;
  /** Create a new blank project, returns its ID */
  createProject: (title?: string) => Promise<string>;
  /** Update an existing project (partial) */
  updateProject: (
    id: string,
    updates: Partial<
      Pick<
        StudioProject,
        | 'title'
        | 'description'
        | 'thumbnail_url'
        | 'visibility'
        | 'project_data'
        | 'canvas_width'
        | 'canvas_height'
        | 'fps'
        | 'frame_count'
        | 'duration_ms'
        | 'tags'
      >
    >
  ) => Promise<void>;
  /** Duplicate a project */
  duplicateProject: (id: string) => Promise<string>;
  /** Soft-delete a project */
  deleteProject: (id: string) => Promise<void>;
  /** Fetch a single project by ID */
  getProject: (id: string) => Promise<StudioProject | null>;
}

// ── Hook ───────────────────────────────────────────────

export function useProjects(): UseProjectsReturn {
  const { user } = useAuth();
  const [projects, setProjects] = useState<StudioProject[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // ── Fetch all projects for current user ────────────
  const refresh = useCallback(async () => {
    if (!user) {
      setProjects([]);
      setIsLoading(false);
      return;
    }

    try {
      setError(null);
      const { data, error: fetchError } = await supabase
        .from('studio_projects')
        .select('*')
        .eq('user_id', user.id)
        .order('updated_at', { ascending: false });

      if (fetchError) throw fetchError;
      setProjects((data as StudioProject[]) ?? []);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to load projects';
      setError(msg);
      console.error('[useProjects] refresh error:', msg);
    } finally {
      setIsLoading(false);
    }
  }, [user]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // ── Create ─────────────────────────────────────────
  const createProject = useCallback(
    async (title?: string): Promise<string> => {
      if (!user) throw new Error('Must be signed in to create a project');

      const newProject = {
        user_id: user.id,
        title: title || 'Untitled Animation',
        description: null,
        thumbnail_url: null,
        visibility: 'private' as ProjectVisibility,
        project_data: defaultProjectData,
        canvas_width: 1080,
        canvas_height: 1920,
        fps: 12,
        frame_count: 1,
        duration_ms: 83,
        is_template: false,
        forked_from: null,
        tags: [],
      };

      const { data, error: insertError } = await supabase
        .from('studio_projects')
        .insert(newProject)
        .select('id')
        .single();

      if (insertError) throw insertError;
      if (!data) throw new Error('No data returned from insert');

      await refresh();
      return data.id;
    },
    [user, refresh]
  );

  // ── Update ─────────────────────────────────────────
  const updateProject = useCallback(
    async (id: string, updates: Record<string, unknown>) => {
      if (!user) throw new Error('Must be signed in');

      const { error: updateError } = await supabase
        .from('studio_projects')
        .update({ ...updates, updated_at: new Date().toISOString() })
        .eq('id', id)
        .eq('user_id', user.id);

      if (updateError) throw updateError;

      // Optimistic update in local state
      setProjects((prev) =>
        prev.map((p) => (p.id === id ? { ...p, ...updates } as StudioProject : p))
      );
    },
    [user]
  );

  // ── Duplicate ──────────────────────────────────────
  const duplicateProject = useCallback(
    async (id: string): Promise<string> => {
      if (!user) throw new Error('Must be signed in');

      const original = projects.find((p) => p.id === id);
      if (!original) throw new Error('Project not found');

      const dup = {
        user_id: user.id,
        title: `${original.title} (copy)`,
        description: original.description,
        thumbnail_url: null,
        visibility: 'private' as ProjectVisibility,
        project_data: original.project_data,
        canvas_width: original.canvas_width,
        canvas_height: original.canvas_height,
        fps: original.fps,
        frame_count: original.frame_count,
        duration_ms: original.duration_ms,
        is_template: false,
        forked_from: original.id,
        tags: original.tags,
      };

      const { data, error: insertError } = await supabase
        .from('studio_projects')
        .insert(dup)
        .select('id')
        .single();

      if (insertError) throw insertError;
      if (!data) throw new Error('No data returned from insert');

      await refresh();
      return data.id;
    },
    [user, projects, refresh]
  );

  // ── Delete ─────────────────────────────────────────
  const deleteProject = useCallback(
    async (id: string) => {
      if (!user) throw new Error('Must be signed in');

      const { error: deleteError } = await supabase
        .from('studio_projects')
        .delete()
        .eq('id', id)
        .eq('user_id', user.id);

      if (deleteError) throw deleteError;

      setProjects((prev) => prev.filter((p) => p.id !== id));
    },
    [user]
  );

  // ── Get single ─────────────────────────────────────
  const getProject = useCallback(
    async (id: string): Promise<StudioProject | null> => {
      const { data, error: fetchError } = await supabase
        .from('studio_projects')
        .select('*')
        .eq('id', id)
        .single();

      if (fetchError) {
        console.error('[useProjects] getProject error:', fetchError.message);
        return null;
      }
      return data as StudioProject;
    },
    []
  );

  return {
    projects,
    isLoading,
    error,
    refresh,
    createProject,
    updateProject,
    duplicateProject,
    deleteProject,
    getProject,
  };
}

export default useProjects;
