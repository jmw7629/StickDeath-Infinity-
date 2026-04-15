import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const list = query({
  args: {
    status: v.optional(
      v.union(
        v.literal("upcoming"),
        v.literal("active"),
        v.literal("voting"),
        v.literal("completed"),
      ),
    ),
  },
  handler: async (ctx, { status }) => {
    if (status) {
      return await ctx.db
        .query("challenges")
        .withIndex("by_status", (q) => q.eq("status", status))
        .order("desc")
        .collect();
    }
    return await ctx.db.query("challenges").order("desc").collect();
  },
});

export const get = query({
  args: { challengeId: v.id("challenges") },
  handler: async (ctx, { challengeId }) => {
    return await ctx.db.get(challengeId);
  },
});

export const getBySlug = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    return await ctx.db
      .query("challenges")
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .first();
  },
});

export const create = mutation({
  args: {
    title: v.string(),
    slug: v.string(),
    description: v.string(),
    rules: v.optional(v.string()),
    startAt: v.number(),
    endAt: v.number(),
    imageUrl: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    let status: "upcoming" | "active" | "voting" | "completed" = "upcoming";
    if (now >= args.startAt && now < args.endAt) status = "active";
    else if (now >= args.endAt) status = "completed";

    return await ctx.db.insert("challenges", {
      ...args,
      status,
      submissionCount: 0,
      createdAt: now,
    });
  },
});

// Seed initial challenges for demo
export const seed = mutation({
  args: {},
  handler: async (ctx) => {
    const existing = await ctx.db.query("challenges").first();
    if (existing) return;

    const now = Date.now();
    const week = 7 * 24 * 60 * 60 * 1000;

    await ctx.db.insert("challenges", {
      title: "Best Death by Explosion",
      slug: "best-explosion-death",
      description:
        "Create the most epic explosion death scene. Bonus points for chain reactions and creative destruction!",
      rules:
        "Animation must be 5-30 seconds. Must feature a stick figure. Must include an explosion.",
      startAt: now - 2 * 24 * 60 * 60 * 1000,
      endAt: now + 5 * 24 * 60 * 60 * 1000,
      status: "active",
      submissionCount: 0,
      createdAt: now,
    });

    await ctx.db.insert("challenges", {
      title: "Funniest Fail",
      slug: "funniest-fail",
      description:
        "Make us laugh! Create the most hilarious stick figure fail. Physical comedy, slapstick, unexpected endings — anything goes.",
      rules: "Keep it under 30 seconds. The funnier the better.",
      startAt: now + 5 * 24 * 60 * 60 * 1000,
      endAt: now + 5 * 24 * 60 * 60 * 1000 + week,
      status: "upcoming",
      submissionCount: 0,
      createdAt: now,
    });

    await ctx.db.insert("challenges", {
      title: "Most Creative Trap",
      slug: "most-creative-trap",
      description:
        "Design an elaborate Rube Goldberg-style death trap. The more creative and unexpected, the better!",
      rules:
        "Animation must show the full trap sequence. Minimum 3 steps in the chain reaction.",
      startAt: now + week + 5 * 24 * 60 * 60 * 1000,
      endAt: now + 2 * week + 5 * 24 * 60 * 60 * 1000,
      status: "upcoming",
      submissionCount: 0,
      createdAt: now,
    });
  },
});
