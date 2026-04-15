import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { SUPERUSER_EMAILS } from "./constants";

export const getMyProfile = query({
  args: {},
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return null;
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    return profile;
  },
});

export const getByUsername = query({
  args: { username: v.string() },
  handler: async (ctx, { username }) => {
    return await ctx.db
      .query("profiles")
      .withIndex("by_username", (q) => q.eq("username", username))
      .first();
  },
});

export const getByUserId = query({
  args: { userId: v.id("users") },
  handler: async (ctx, { userId }) => {
    return await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
  },
});

export const createProfile = mutation({
  args: {
    username: v.string(),
    displayName: v.string(),
    bio: v.optional(v.string()),
  },
  handler: async (ctx, { username, displayName, bio }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    // Check if profile exists
    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (existing) throw new Error("Profile already exists");

    // Check username uniqueness
    const usernameExists = await ctx.db
      .query("profiles")
      .withIndex("by_username", (q) => q.eq("username", username.toLowerCase()))
      .first();
    if (usernameExists) throw new Error("Username taken");

    // Check if this user's email is a superuser
    const user = await ctx.db.get(userId);
    const userEmail = user?.email?.toLowerCase() ?? "";
    const isSuperuser = SUPERUSER_EMAILS.some(
      (e) => e.toLowerCase() === userEmail,
    );

    const profileId = await ctx.db.insert("profiles", {
      userId,
      username: username.toLowerCase(),
      displayName,
      bio,
      role: isSuperuser ? "admin" : "user",
      subscription: isSuperuser ? "pro" : "free",
      superAdmin: isSuperuser,
      banned: false,
      createdAt: Date.now(),
    });

    // Create initial stats
    await ctx.db.insert("userStats", {
      userId,
      followersCount: 0,
      followingCount: 0,
      postsCount: 0,
      projectsCount: 0,
      reactionsReceived: 0,
    });

    return profileId;
  },
});

export const updateProfile = mutation({
  args: {
    displayName: v.optional(v.string()),
    bio: v.optional(v.string()),
    avatarUrl: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (!profile) throw new Error("Profile not found");

    const updates: Record<string, string | undefined> = {};
    if (args.displayName !== undefined) updates.displayName = args.displayName;
    if (args.bio !== undefined) updates.bio = args.bio;
    if (args.avatarUrl !== undefined) updates.avatarUrl = args.avatarUrl;

    await ctx.db.patch(profile._id, updates);
  },
});
