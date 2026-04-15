import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import { SUPERUSER_EMAILS } from "./constants";

// Helper: ensure caller is admin or superAdmin
async function requireAdmin(ctx: any) {
  const userId = await getAuthUserId(ctx);
  if (!userId) throw new Error("Not authenticated");
  const profile = await ctx.db
    .query("profiles")
    .withIndex("by_userId", (q: any) => q.eq("userId", userId))
    .first();
  if (!profile) throw new Error("No profile");
  if (profile.role !== "admin" && !profile.superAdmin) {
    throw new Error("Admin access required");
  }
  return { userId, profile };
}

// ── Get my admin status ──
export const getMyAdminStatus = query({
  args: {},
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return null;
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (!profile) return null;
    return {
      isAdmin: profile.role === "admin",
      isSuperAdmin: profile.superAdmin,
      subscription: profile.subscription,
      role: profile.role,
    };
  },
});

// ── Promote a user to Pro ──
export const setSubscription = mutation({
  args: {
    targetUserId: v.id("users"),
    subscription: v.union(
      v.literal("free"),
      v.literal("pro"),
      v.literal("creator"),
    ),
  },
  handler: async (ctx, { targetUserId, subscription }) => {
    await requireAdmin(ctx);
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", targetUserId))
      .first();
    if (!profile) throw new Error("User not found");
    await ctx.db.patch(profile._id, { subscription });
  },
});

// ── Set a user's role ──
export const setRole = mutation({
  args: {
    targetUserId: v.id("users"),
    role: v.union(v.literal("user"), v.literal("admin"), v.literal("bot")),
  },
  handler: async (ctx, { targetUserId, role }) => {
    await requireAdmin(ctx);
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", targetUserId))
      .first();
    if (!profile) throw new Error("User not found");
    await ctx.db.patch(profile._id, { role });
  },
});

// ── Ban / unban a user ──
export const setBanned = mutation({
  args: {
    targetUserId: v.id("users"),
    banned: v.boolean(),
  },
  handler: async (ctx, { targetUserId, banned }) => {
    await requireAdmin(ctx);
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", targetUserId))
      .first();
    if (!profile) throw new Error("User not found");
    await ctx.db.patch(profile._id, { banned });
  },
});

// ── List all users (admin view) ──
export const listAllUsers = query({
  args: {},
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return [];
    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (!profile || (profile.role !== "admin" && !profile.superAdmin)) return [];
    
    const profiles = await ctx.db.query("profiles").collect();
    return profiles;
  },
});

// ── Seed Joe's superuser account (run once, idempotent) ──
export const seedSuperuser = mutation({
  args: {
    email: v.string(),
    username: v.string(),
    displayName: v.string(),
  },
  handler: async (ctx, { email, username, displayName }) => {
    // Only allow superuser emails
    if (!SUPERUSER_EMAILS.some((e) => e.toLowerCase() === email.toLowerCase())) {
      throw new Error("Not a superuser email");
    }

    // Find the user by email from the auth tables
    const users = await ctx.db.query("users").collect();
    const user = users.find(
      (u: any) => u.email?.toLowerCase() === email.toLowerCase(),
    );
    if (!user) {
      return { success: false, message: "User not found — sign up first, then this will auto-promote." };
    }

    // Check if profile exists
    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_userId", (q) => q.eq("userId", user._id))
      .first();
    
    if (existing) {
      // Upgrade existing profile
      await ctx.db.patch(existing._id, {
        role: "admin",
        subscription: "pro",
        superAdmin: true,
      });
      return { success: true, message: "Existing profile upgraded to superuser + pro." };
    }

    // Create new profile
    await ctx.db.insert("profiles", {
      userId: user._id,
      username: username.toLowerCase(),
      displayName,
      bio: "Creator of StickDeath Infinity",
      role: "admin",
      subscription: "pro",
      superAdmin: true,
      banned: false,
      createdAt: Date.now(),
    });

    // Create initial stats
    await ctx.db.insert("userStats", {
      userId: user._id,
      followersCount: 0,
      followingCount: 0,
      postsCount: 0,
      projectsCount: 0,
      reactionsReceived: 0,
    });

    return { success: true, message: "Superuser profile created with admin + pro." };
  },
});
