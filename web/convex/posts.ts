import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const feed = query({
  args: {
    sort: v.optional(
      v.union(v.literal("trending"), v.literal("new"), v.literal("top")),
    ),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { sort = "new", limit = 20 }) => {
    let posts;
    if (sort === "trending" || sort === "top") {
      posts = await ctx.db
        .query("posts")
        .withIndex("by_visibility_createdAt", (q) => q.eq("visibility", "public"))
        .order("desc")
        .take(100);
      posts.sort((a, b) => b.reactionCount - a.reactionCount);
      posts = posts.slice(0, limit);
    } else {
      posts = await ctx.db
        .query("posts")
        .withIndex("by_visibility_createdAt", (q) => q.eq("visibility", "public"))
        .order("desc")
        .take(limit);
    }

    // Enrich with creator profiles
    const enriched = await Promise.all(
      posts.map(async (post) => {
        const profile = await ctx.db
          .query("profiles")
          .withIndex("by_userId", (q) => q.eq("userId", post.userId))
          .first();
        return { ...post, creator: profile };
      }),
    );

    return enriched;
  },
});

export const getByUser = query({
  args: { userId: v.id("users") },
  handler: async (ctx, { userId }) => {
    return await ctx.db
      .query("posts")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .order("desc")
      .collect();
  },
});

export const get = query({
  args: { postId: v.id("posts") },
  handler: async (ctx, { postId }) => {
    const post = await ctx.db.get(postId);
    if (!post) return null;
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", post.userId))
      .first();
    return { ...post, creator: profile };
  },
});

export const getByChallenge = query({
  args: { challengeId: v.id("challenges") },
  handler: async (ctx, { challengeId }) => {
    const posts = await ctx.db
      .query("posts")
      .withIndex("by_challengeId", (q) => q.eq("challengeId", challengeId))
      .order("desc")
      .collect();

    const enriched = await Promise.all(
      posts.map(async (post) => {
        const profile = await ctx.db
          .query("profiles")
          .withIndex("by_userId", (q) => q.eq("userId", post.userId))
          .first();
        return { ...post, creator: profile };
      }),
    );
    return enriched;
  },
});

export const create = mutation({
  args: {
    title: v.string(),
    description: v.optional(v.string()),
    projectId: v.optional(v.id("projects")),
    animationData: v.optional(v.string()),
    thumbnailUrl: v.optional(v.string()),
    duration: v.number(),
    width: v.number(),
    height: v.number(),
    tags: v.array(v.string()),
    challengeId: v.optional(v.id("challenges")),
    visibility: v.optional(
      v.union(v.literal("public"), v.literal("unlisted"), v.literal("private")),
    ),
  },
  handler: async (ctx, args) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const postId = await ctx.db.insert("posts", {
      userId,
      projectId: args.projectId,
      title: args.title,
      description: args.description,
      animationData: args.animationData,
      thumbnailUrl: args.thumbnailUrl,
      duration: args.duration,
      width: args.width,
      height: args.height,
      visibility: args.visibility ?? "public",
      featured: false,
      viewCount: 0,
      reactionCount: 0,
      commentCount: 0,
      tags: args.tags,
      challengeId: args.challengeId,
      createdAt: Date.now(),
    });

    // Update project status
    if (args.projectId) {
      await ctx.db.patch(args.projectId, { status: "published" });
    }

    // Update challenge submission count
    if (args.challengeId) {
      const challenge = await ctx.db.get(args.challengeId);
      if (challenge) {
        await ctx.db.patch(args.challengeId, {
          submissionCount: challenge.submissionCount + 1,
        });
      }
    }

    // Update user stats
    const stats = await ctx.db
      .query("userStats")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (stats) {
      await ctx.db.patch(stats._id, { postsCount: stats.postsCount + 1 });
    }

    return postId;
  },
});

export const incrementView = mutation({
  args: { postId: v.id("posts") },
  handler: async (ctx, { postId }) => {
    const post = await ctx.db.get(postId);
    if (post) {
      await ctx.db.patch(postId, { viewCount: post.viewCount + 1 });
    }
  },
});
