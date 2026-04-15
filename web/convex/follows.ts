import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const isFollowing = query({
  args: { targetUserId: v.id("users") },
  handler: async (ctx, { targetUserId }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return false;

    const follow = await ctx.db
      .query("follows")
      .withIndex("by_pair", (q) =>
        q.eq("followerId", userId).eq("followingId", targetUserId),
      )
      .first();

    return !!follow;
  },
});

export const toggle = mutation({
  args: { targetUserId: v.id("users") },
  handler: async (ctx, { targetUserId }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");
    if (userId === targetUserId) throw new Error("Cannot follow yourself");

    const existing = await ctx.db
      .query("follows")
      .withIndex("by_pair", (q) =>
        q.eq("followerId", userId).eq("followingId", targetUserId),
      )
      .first();

    const myStats = await ctx.db
      .query("userStats")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    const theirStats = await ctx.db
      .query("userStats")
      .withIndex("by_userId", (q) => q.eq("userId", targetUserId))
      .first();

    if (existing) {
      await ctx.db.delete(existing._id);
      if (myStats)
        await ctx.db.patch(myStats._id, {
          followingCount: Math.max(0, myStats.followingCount - 1),
        });
      if (theirStats)
        await ctx.db.patch(theirStats._id, {
          followersCount: Math.max(0, theirStats.followersCount - 1),
        });
      return { following: false };
    }
    await ctx.db.insert("follows", {
      followerId: userId,
      followingId: targetUserId,
      createdAt: Date.now(),
    });
    if (myStats)
      await ctx.db.patch(myStats._id, {
        followingCount: myStats.followingCount + 1,
      });
    if (theirStats)
      await ctx.db.patch(theirStats._id, {
        followersCount: theirStats.followersCount + 1,
      });
    return { following: true };
  },
});

export const getStats = query({
  args: { userId: v.id("users") },
  handler: async (ctx, { userId }) => {
    return await ctx.db
      .query("userStats")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
  },
});
