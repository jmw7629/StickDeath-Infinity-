import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const getForPost = query({
  args: { postId: v.id("posts") },
  handler: async (ctx, { postId }) => {
    const comments = await ctx.db
      .query("comments")
      .withIndex("by_postId", (q) => q.eq("postId", postId))
      .order("desc")
      .collect();

    const enriched = await Promise.all(
      comments.map(async (comment) => {
        const profile = await ctx.db
          .query("profiles")
          .withIndex("by_userId", (q) => q.eq("userId", comment.userId))
          .first();
        return { ...comment, author: profile };
      }),
    );

    return enriched;
  },
});

export const create = mutation({
  args: {
    postId: v.id("posts"),
    body: v.string(),
  },
  handler: async (ctx, { postId, body }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    if (body.trim().length === 0) throw new Error("Comment cannot be empty");
    if (body.length > 500) throw new Error("Comment too long");

    const commentId = await ctx.db.insert("comments", {
      postId,
      userId,
      body: body.trim(),
      createdAt: Date.now(),
    });

    // Update post comment count
    const post = await ctx.db.get(postId);
    if (post) {
      await ctx.db.patch(postId, { commentCount: post.commentCount + 1 });
    }

    return commentId;
  },
});

export const remove = mutation({
  args: { commentId: v.id("comments") },
  handler: async (ctx, { commentId }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const comment = await ctx.db.get(commentId);
    if (!comment) throw new Error("Comment not found");
    if (comment.userId !== userId) throw new Error("Not authorized");

    const post = await ctx.db.get(comment.postId);
    if (post) {
      await ctx.db.patch(comment.postId, {
        commentCount: Math.max(0, post.commentCount - 1),
      });
    }

    await ctx.db.delete(commentId);
  },
});
