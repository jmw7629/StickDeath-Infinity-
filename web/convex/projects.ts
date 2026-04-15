import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const list = query({
  args: {},
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return [];
    return await ctx.db
      .query("projects")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .order("desc")
      .collect();
  },
});

export const get = query({
  args: { projectId: v.id("projects") },
  handler: async (ctx, { projectId }) => {
    return await ctx.db.get(projectId);
  },
});

export const create = mutation({
  args: {
    name: v.string(),
    canvasWidth: v.optional(v.number()),
    canvasHeight: v.optional(v.number()),
    fps: v.optional(v.number()),
    backgroundColor: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const now = Date.now();
    const projectId = await ctx.db.insert("projects", {
      userId,
      name: args.name,
      canvasWidth: args.canvasWidth ?? 1280,
      canvasHeight: args.canvasHeight ?? 720,
      fps: args.fps ?? 12,
      backgroundColor: args.backgroundColor ?? "#1a1a2e",
      status: "draft",
      frameCount: 1,
      layerCount: 1,
      createdAt: now,
      updatedAt: now,
    });

    // Create default drawing layer
    const layerId = await ctx.db.insert("layers", {
      projectId,
      name: "Layer 1",
      type: "draw",
      orderIndex: 0,
      visible: true,
      opacity: 1,
      locked: false,
    });

    // Create first empty frame
    await ctx.db.insert("frames", {
      projectId,
      layerId,
      frameIndex: 0,
      isEmpty: true,
    });

    // Update user stats
    const stats = await ctx.db
      .query("userStats")
      .withIndex("by_userId", (q) => q.eq("userId", userId))
      .first();
    if (stats) {
      await ctx.db.patch(stats._id, {
        projectsCount: stats.projectsCount + 1,
      });
    }

    return projectId;
  },
});

export const update = mutation({
  args: {
    projectId: v.id("projects"),
    name: v.optional(v.string()),
    fps: v.optional(v.number()),
    backgroundColor: v.optional(v.string()),
  },
  handler: async (ctx, { projectId, ...updates }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");

    const patch: Record<string, unknown> = { updatedAt: Date.now() };
    if (updates.name !== undefined) patch.name = updates.name;
    if (updates.fps !== undefined) patch.fps = updates.fps;
    if (updates.backgroundColor !== undefined)
      patch.backgroundColor = updates.backgroundColor;

    await ctx.db.patch(projectId, patch);
  },
});

export const remove = mutation({
  args: { projectId: v.id("projects") },
  handler: async (ctx, { projectId }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");

    // Delete all frames
    const frames = await ctx.db
      .query("frames")
      .withIndex("by_projectId", (q) => q.eq("projectId", projectId))
      .collect();
    for (const frame of frames) {
      await ctx.db.delete(frame._id);
    }

    // Delete all layers
    const layers = await ctx.db
      .query("layers")
      .withIndex("by_projectId", (q) => q.eq("projectId", projectId))
      .collect();
    for (const layer of layers) {
      await ctx.db.delete(layer._id);
    }

    await ctx.db.delete(projectId);
  },
});
