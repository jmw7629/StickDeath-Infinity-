import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const getForPost = query({
  args: { postId: v.id("posts") },
  handler: async (ctx, { postId }) => {
    const reactions = await ctx.db
      .query("reactions")
      .withIndex("by_postId", (q) => q.eq("postId", postId))
      .collect();

    // Group by type
    const counts: Record<string, number> = {
      fire: 0,
      skull: 0,
      laugh: 0,
      support: 0,
    };
    for (const r of reactions) {
      counts[r.type] = (counts[r.type] || 0) + 1;
    }

    // Check current user's reactions
    const userId = await getAuthUserId(ctx);
    const userReactions: string[] = [];
    if (userId) {
      const userR = reactions.filter((r) => r.userId === userId);
      for (const r of userR) {
        userReactions.push(r.type);
      }
    }

    return { counts, userReactions, total: reactions.length };
  },
});

export const toggle = mutation({
  args: {
    postId: v.id("posts"),
    type: v.union(
      v.literal("fire"),
      v.literal("skull"),
      v.literal("laugh"),
      v.literal("support"),
    ),
  },
  handler: async (ctx, { postId, type }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const existing = await ctx.db
      .query("reactions")
      .withIndex("by_post_user", (q) => q.eq("postId", postId).eq("userId", userId))
      .collect();

    const existingOfType = existing.find((r) => r.type === type);

    const post = await ctx.db.get(postId);
    if (!post) throw new Error("Post not found");

    if (existingOfType) {
      // Remove reaction
      await ctx.db.delete(existingOfType._id);
      await ctx.db.patch(postId, {
        reactionCount: Math.max(0, post.reactionCount - 1),
      });
      return { added: false };
    }
    // Add reaction
    await ctx.db.insert("reactions", {
      postId,
      userId,
      type,
      createdAt: Date.now(),
    });
    await ctx.db.patch(postId, {
      reactionCount: post.reactionCount + 1,
    });
    return { added: true };
  },
});
