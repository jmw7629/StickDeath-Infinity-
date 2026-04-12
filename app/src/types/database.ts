/**
 * StickDeath Infinity — Database Types
 *
 * TypeScript types matching the Supabase schema.
 * Keep in sync with supabase/migrations/.
 */

// ── Enums ──────────────────────────────────────────────

export type SubscriptionTier = 'free' | 'pro';
export type ProjectVisibility = 'private' | 'public' | 'unlisted';
export type PostType = 'animation' | 'wip' | 'tutorial' | 'meme';
export type ReactionType = '🔥' | '💀' | '🤣' | '👑' | '💯';
export type MessageStatus = 'sent' | 'delivered' | 'read';

// ── Core Tables ────────────────────────────────────────

/** auth.users extension — public profile data */
export interface Profile {
  id: string; // FK → auth.users.id
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  website: string | null;
  subscription_tier: SubscriptionTier;
  subscription_expires_at: string | null; // ISO timestamp
  is_verified: boolean;
  follower_count: number;
  following_count: number;
  total_likes: number;
  created_at: string;
  updated_at: string;
}

/** A stick-figure animation project */
export interface StudioProject {
  id: string; // uuid
  user_id: string; // FK → auth.users.id
  title: string;
  description: string | null;
  thumbnail_url: string | null;
  visibility: ProjectVisibility;
  /** JSON blob: frames, layers, audio refs, settings */
  project_data: ProjectData;
  canvas_width: number;
  canvas_height: number;
  fps: number;
  frame_count: number;
  duration_ms: number;
  is_template: boolean;
  fork_count: number;
  forked_from: string | null; // FK → studio_projects.id
  tags: string[];
  created_at: string;
  updated_at: string;
}

/** Community feed post (published animation / WIP / tutorial) */
export interface CommunityPost {
  id: string;
  user_id: string;
  project_id: string | null; // FK → studio_projects.id
  post_type: PostType;
  caption: string | null;
  media_url: string; // rendered video/GIF URL
  thumbnail_url: string | null;
  like_count: number;
  comment_count: number;
  share_count: number;
  view_count: number;
  tags: string[];
  is_featured: boolean;
  created_at: string;
  updated_at: string;
}

/** Comment on a community post */
export interface PostComment {
  id: string;
  post_id: string; // FK → community_posts.id
  user_id: string;
  parent_comment_id: string | null; // for nested replies
  body: string;
  like_count: number;
  created_at: string;
  updated_at: string;
}

/** Reaction on a post */
export interface PostReaction {
  id: string;
  post_id: string;
  user_id: string;
  reaction: ReactionType;
  created_at: string;
}

/** DM thread (1-on-1 or group) */
export interface DmThread {
  id: string;
  created_by: string;
  is_group: boolean;
  group_name: string | null;
  group_avatar_url: string | null;
  last_message_at: string | null;
  last_message_preview: string | null;
  created_at: string;
  updated_at: string;
}

/** DM thread membership */
export interface DmThreadMember {
  id: string;
  thread_id: string; // FK → dm_threads.id
  user_id: string;
  last_read_at: string | null;
  is_muted: boolean;
  joined_at: string;
}

/** Individual DM message */
export interface DmMessage {
  id: string;
  thread_id: string;
  sender_id: string;
  body: string | null;
  media_url: string | null; // shared animation / image
  media_type: string | null; // 'image' | 'video' | 'animation'
  status: MessageStatus;
  created_at: string;
  updated_at: string;
}

/** User follow relationship */
export interface Follow {
  id: string;
  follower_id: string;
  following_id: string;
  created_at: string;
}

/** User notification */
export interface Notification {
  id: string;
  user_id: string;
  actor_id: string | null;
  type: 'like' | 'comment' | 'follow' | 'mention' | 'system';
  entity_type: string | null; // 'post' | 'comment' | 'project'
  entity_id: string | null;
  title: string;
  body: string | null;
  is_read: boolean;
  created_at: string;
}

// ── Project Data (JSON blob inside studio_projects.project_data) ──

export interface ProjectData {
  version: number;
  settings: ProjectSettings;
  layers: Layer[];
  audio_tracks: AudioTrack[];
}

export interface ProjectSettings {
  background_color: string;
  grid_enabled: boolean;
  grid_size: number;
  onion_skin_enabled: boolean;
  onion_skin_opacity: number;
  onion_skin_frames: number;
}

export interface Layer {
  id: string;
  name: string;
  visible: boolean;
  locked: boolean;
  opacity: number;
  order: number;
  frames: Frame[];
}

export interface Frame {
  id: string;
  index: number;
  duration_ms: number;
  elements: StickElement[];
}

export type StickElement =
  | StickFigure
  | FreehandPath
  | ShapeElement
  | TextElement;

export interface StickFigure {
  type: 'stickfigure';
  id: string;
  joints: Record<JointName, Point>;
  color: string;
  stroke_width: number;
  head_radius: number;
}

export type JointName =
  | 'head'
  | 'neck'
  | 'hip'
  | 'left_shoulder'
  | 'left_elbow'
  | 'left_hand'
  | 'right_shoulder'
  | 'right_elbow'
  | 'right_hand'
  | 'left_hip'
  | 'left_knee'
  | 'left_foot'
  | 'right_hip'
  | 'right_knee'
  | 'right_foot';

export interface Point {
  x: number;
  y: number;
}

export interface FreehandPath {
  type: 'freehand';
  id: string;
  points: Point[];
  color: string;
  stroke_width: number;
}

export interface ShapeElement {
  type: 'shape';
  id: string;
  shape: 'rect' | 'circle' | 'line' | 'polygon';
  position: Point;
  size: { width: number; height: number };
  rotation: number;
  color: string;
  fill_color: string | null;
  stroke_width: number;
}

export interface TextElement {
  type: 'text';
  id: string;
  position: Point;
  text: string;
  font_size: number;
  color: string;
  font_weight: 'normal' | 'bold';
}

export interface AudioTrack {
  id: string;
  name: string;
  uri: string;
  volume: number;
  start_ms: number;
  duration_ms: number;
}

// ── Database helper types ──────────────────────────────

export type Tables = {
  profiles: Profile;
  studio_projects: StudioProject;
  community_posts: CommunityPost;
  post_comments: PostComment;
  post_reactions: PostReaction;
  dm_threads: DmThread;
  dm_thread_members: DmThreadMember;
  dm_messages: DmMessage;
  follows: Follow;
  notifications: Notification;
};

export type TableName = keyof Tables;

/** Insert type: make id, created_at, updated_at, and computed columns optional */
export type InsertRow<T extends TableName> = Omit<
  Tables[T],
  'id' | 'created_at' | 'updated_at' | 'follower_count' | 'following_count' | 'total_likes' | 'like_count' | 'comment_count' | 'share_count' | 'view_count' | 'fork_count'
> &
  Partial<Pick<Tables[T], 'id' & keyof Tables[T]>>;

/** Update type: all fields optional except id */
export type UpdateRow<T extends TableName> = Partial<Tables[T]> & {
  id: string;
};
