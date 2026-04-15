import { authTables } from "@convex-dev/auth/server";
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const schema = defineSchema({
  ...authTables,

  // ── User Profiles ──
  profiles: defineTable({
    userId: v.id("users"),
    username: v.string(),
    displayName: v.string(),
    bio: v.optional(v.string()),
    avatarUrl: v.optional(v.string()),
    role: v.union(v.literal("user"), v.literal("admin"), v.literal("bot")),
    subscription: v.union(
      v.literal("free"),
      v.literal("pro"),
      v.literal("creator"),
    ),
    superAdmin: v.boolean(),
    banned: v.boolean(),
    createdAt: v.number(),
  })
    .index("by_userId", ["userId"])
    .index("by_username", ["username"])
    .index("by_role", ["role"]),

  // ── User Stats (denormalized for fast display) ──
  userStats: defineTable({
    userId: v.id("users"),
    followersCount: v.number(),
    followingCount: v.number(),
    postsCount: v.number(),
    projectsCount: v.number(),
    reactionsReceived: v.number(),
  }).index("by_userId", ["userId"]),

  // ── Follows ──
  follows: defineTable({
    followerId: v.id("users"),
    followingId: v.id("users"),
    createdAt: v.number(),
  })
    .index("by_follower", ["followerId"])
    .index("by_following", ["followingId"])
    .index("by_pair", ["followerId", "followingId"]),

  // ── Studio Projects ──
  projects: defineTable({
    userId: v.id("users"),
    name: v.string(),
    description: v.optional(v.string()),
    thumbnailUrl: v.optional(v.string()),
    canvasWidth: v.number(),
    canvasHeight: v.number(),
    fps: v.number(),
    backgroundColor: v.string(),
    status: v.union(
      v.literal("draft"),
      v.literal("published"),
      v.literal("archived"),
    ),
    frameCount: v.number(),
    layerCount: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_userId", ["userId"])
    .index("by_status", ["status"])
    .index("by_userId_updatedAt", ["userId", "updatedAt"]),

  // ── Project Layers ──
  layers: defineTable({
    projectId: v.id("projects"),
    name: v.string(),
    type: v.union(
      v.literal("draw"),
      v.literal("rig"),
      v.literal("image"),
      v.literal("text"),
    ),
    orderIndex: v.number(),
    visible: v.boolean(),
    opacity: v.number(),
    locked: v.boolean(),
  }).index("by_projectId", ["projectId"]),

  // ── Frames (stores drawing data per layer per frame) ──
  frames: defineTable({
    projectId: v.id("projects"),
    layerId: v.id("layers"),
    frameIndex: v.number(),
    imageData: v.optional(v.string()), // base64 canvas data or storage ref
    storageId: v.optional(v.id("_storage")),
    isEmpty: v.boolean(),
  })
    .index("by_project_layer_frame", ["projectId", "layerId", "frameIndex"])
    .index("by_projectId", ["projectId"])
    .index("by_layerId", ["layerId"]),

  // ── Posts (published animations) ──
  posts: defineTable({
    userId: v.id("users"),
    projectId: v.optional(v.id("projects")),
    title: v.string(),
    description: v.optional(v.string()),
    thumbnailUrl: v.optional(v.string()),
    animationData: v.optional(v.string()), // JSON frames for playback
    storageId: v.optional(v.id("_storage")),
    duration: v.number(), // seconds
    width: v.number(),
    height: v.number(),
    visibility: v.union(
      v.literal("public"),
      v.literal("unlisted"),
      v.literal("private"),
    ),
    featured: v.boolean(),
    viewCount: v.number(),
    reactionCount: v.number(),
    commentCount: v.number(),
    tags: v.array(v.string()),
    challengeId: v.optional(v.id("challenges")),
    createdAt: v.number(),
  })
    .index("by_userId", ["userId"])
    .index("by_createdAt", ["createdAt"])
    .index("by_visibility_createdAt", ["visibility", "createdAt"])
    .index("by_featured", ["featured"])
    .index("by_challengeId", ["challengeId"])
    .index("by_reactionCount", ["reactionCount"]),

  // ── Reactions ──
  reactions: defineTable({
    postId: v.id("posts"),
    userId: v.id("users"),
    type: v.union(
      v.literal("fire"),
      v.literal("skull"),
      v.literal("laugh"),
      v.literal("support"),
    ),
    createdAt: v.number(),
  })
    .index("by_postId", ["postId"])
    .index("by_userId", ["userId"])
    .index("by_post_user", ["postId", "userId"]),

  // ── Comments ──
  comments: defineTable({
    postId: v.id("posts"),
    userId: v.id("users"),
    body: v.string(),
    createdAt: v.number(),
  })
    .index("by_postId", ["postId"])
    .index("by_userId", ["userId"]),

  // ── Challenges ──
  challenges: defineTable({
    title: v.string(),
    slug: v.string(),
    description: v.string(),
    rules: v.optional(v.string()),
    startAt: v.number(),
    endAt: v.number(),
    status: v.union(
      v.literal("upcoming"),
      v.literal("active"),
      v.literal("voting"),
      v.literal("completed"),
    ),
    imageUrl: v.optional(v.string()),
    submissionCount: v.number(),
    createdAt: v.number(),
  })
    .index("by_status", ["status"])
    .index("by_slug", ["slug"])
    .index("by_endAt", ["endAt"]),

  // ── Spatter AI Chat Messages ──
  spatterMessages: defineTable({
    userId: v.optional(v.id("users")),
    sessionId: v.string(),
    role: v.union(v.literal("user"), v.literal("assistant")),
    content: v.string(),
    context: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_sessionId", ["sessionId"])
    .index("by_userId", ["userId"]),

  // ── Notifications ──
  notifications: defineTable({
    userId: v.id("users"),
    type: v.union(
      v.literal("reaction"),
      v.literal("comment"),
      v.literal("follow"),
      v.literal("challenge"),
      v.literal("featured"),
      v.literal("spatter"), // from Spatter bot
    ),
    actorId: v.optional(v.id("users")),
    entityType: v.optional(v.string()),
    entityId: v.optional(v.string()),
    message: v.optional(v.string()),
    read: v.boolean(),
    createdAt: v.number(),
  })
    .index("by_userId", ["userId"])
    .index("by_userId_read", ["userId", "read"]),
});

export default schema;
