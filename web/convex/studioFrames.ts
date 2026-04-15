import { getAuthUserId } from "@convex-dev/auth/server";
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const getFrames = query({
  args: { projectId: v.id("projects"), layerId: v.id("layers") },
  handler: async (ctx, { projectId, layerId }) => {
    return await ctx.db
      .query("frames")
      .withIndex("by_project_layer_frame", (q) =>
        q.eq("projectId", projectId).eq("layerId", layerId),
      )
      .collect();
  },
});

export const getAllProjectFrames = query({
  args: { projectId: v.id("projects") },
  handler: async (ctx, { projectId }) => {
    return await ctx.db
      .query("frames")
      .withIndex("by_projectId", (q) => q.eq("projectId", projectId))
      .collect();
  },
});

export const getLayers = query({
  args: { projectId: v.id("projects") },
  handler: async (ctx, { projectId }) => {
    return await ctx.db
      .query("layers")
      .withIndex("by_projectId", (q) => q.eq("projectId", projectId))
      .collect();
  },
});

export const saveFrame = mutation({
  args: {
    projectId: v.id("projects"),
    layerId: v.id("layers"),
    frameIndex: v.number(),
    imageData: v.string(),
  },
  handler: async (ctx, { projectId, layerId, frameIndex, imageData }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");

    // Find existing frame
    const existing = await ctx.db
      .query("frames")
      .withIndex("by_project_layer_frame", (q) =>
        q
          .eq("projectId", projectId)
          .eq("layerId", layerId)
          .eq("frameIndex", frameIndex),
      )
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        imageData,
        isEmpty: false,
      });
      return existing._id;
    }
    return await ctx.db.insert("frames", {
      projectId,
      layerId,
      frameIndex,
      imageData,
      isEmpty: false,
    });
  },
});

export const addFrame = mutation({
  args: {
    projectId: v.id("projects"),
    layerId: v.id("layers"),
    frameIndex: v.number(),
    duplicateFrom: v.optional(v.number()),
  },
  handler: async (ctx, { projectId, layerId, frameIndex, duplicateFrom }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");

    let imageData: string | undefined;
    if (duplicateFrom !== undefined) {
      const sourceFrame = await ctx.db
        .query("frames")
        .withIndex("by_project_layer_frame", (q) =>
          q
            .eq("projectId", projectId)
            .eq("layerId", layerId)
            .eq("frameIndex", duplicateFrom),
        )
        .first();
      if (sourceFrame?.imageData) {
        imageData = sourceFrame.imageData;
      }
    }

    // Shift existing frames at and after this index
    const allFrames = await ctx.db
      .query("frames")
      .withIndex("by_project_layer_frame", (q) =>
        q.eq("projectId", projectId).eq("layerId", layerId),
      )
      .collect();

    const framesToShift = allFrames
      .filter((f) => f.frameIndex >= frameIndex)
      .sort((a, b) => b.frameIndex - a.frameIndex);

    for (const frame of framesToShift) {
      await ctx.db.patch(frame._id, { frameIndex: frame.frameIndex + 1 });
    }

    // Insert new frame
    const frameId = await ctx.db.insert("frames", {
      projectId,
      layerId,
      frameIndex,
      imageData,
      isEmpty: !imageData,
    });

    // Update project frame count
    await ctx.db.patch(projectId, {
      frameCount: project.frameCount + 1,
      updatedAt: Date.now(),
    });

    return frameId;
  },
});

export const deleteFrame = mutation({
  args: {
    projectId: v.id("projects"),
    layerId: v.id("layers"),
    frameIndex: v.number(),
  },
  handler: async (ctx, { projectId, layerId, frameIndex }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");
    if (project.frameCount <= 1) throw new Error("Cannot delete the last frame");

    const frame = await ctx.db
      .query("frames")
      .withIndex("by_project_layer_frame", (q) =>
        q
          .eq("projectId", projectId)
          .eq("layerId", layerId)
          .eq("frameIndex", frameIndex),
      )
      .first();

    if (frame) {
      await ctx.db.delete(frame._id);
    }

    // Shift subsequent frames down
    const allFrames = await ctx.db
      .query("frames")
      .withIndex("by_project_layer_frame", (q) =>
        q.eq("projectId", projectId).eq("layerId", layerId),
      )
      .collect();

    const framesToShift = allFrames
      .filter((f) => f.frameIndex > frameIndex)
      .sort((a, b) => a.frameIndex - b.frameIndex);

    for (const f of framesToShift) {
      await ctx.db.patch(f._id, { frameIndex: f.frameIndex - 1 });
    }

    await ctx.db.patch(projectId, {
      frameCount: project.frameCount - 1,
      updatedAt: Date.now(),
    });
  },
});

export const addLayer = mutation({
  args: {
    projectId: v.id("projects"),
    name: v.string(),
    type: v.union(
      v.literal("draw"),
      v.literal("rig"),
      v.literal("image"),
      v.literal("text"),
    ),
  },
  handler: async (ctx, { projectId, name, type }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");

    const layers = await ctx.db
      .query("layers")
      .withIndex("by_projectId", (q) => q.eq("projectId", projectId))
      .collect();

    const layerId = await ctx.db.insert("layers", {
      projectId,
      name,
      type,
      orderIndex: layers.length,
      visible: true,
      opacity: 1,
      locked: false,
    });

    // Create frames for this layer matching existing frame count
    for (let i = 0; i < project.frameCount; i++) {
      await ctx.db.insert("frames", {
        projectId,
        layerId,
        frameIndex: i,
        isEmpty: true,
      });
    }

    await ctx.db.patch(projectId, {
      layerCount: project.layerCount + 1,
      updatedAt: Date.now(),
    });

    return layerId;
  },
});

export const deleteLayer = mutation({
  args: { projectId: v.id("projects"), layerId: v.id("layers") },
  handler: async (ctx, { projectId, layerId }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const project = await ctx.db.get(projectId);
    if (!project || project.userId !== userId) throw new Error("Not authorized");
    if (project.layerCount <= 1) throw new Error("Cannot delete the last layer");

    // Delete all frames for this layer
    const frames = await ctx.db
      .query("frames")
      .withIndex("by_layerId", (q) => q.eq("layerId", layerId))
      .collect();
    for (const frame of frames) {
      await ctx.db.delete(frame._id);
    }

    await ctx.db.delete(layerId);

    await ctx.db.patch(projectId, {
      layerCount: project.layerCount - 1,
      updatedAt: Date.now(),
    });
  },
});

export const updateLayer = mutation({
  args: {
    layerId: v.id("layers"),
    name: v.optional(v.string()),
    visible: v.optional(v.boolean()),
    opacity: v.optional(v.number()),
    locked: v.optional(v.boolean()),
  },
  handler: async (ctx, { layerId, ...updates }) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) throw new Error("Not authenticated");

    const layer = await ctx.db.get(layerId);
    if (!layer) throw new Error("Layer not found");

    const patch: Record<string, unknown> = {};
    if (updates.name !== undefined) patch.name = updates.name;
    if (updates.visible !== undefined) patch.visible = updates.visible;
    if (updates.opacity !== undefined) patch.opacity = updates.opacity;
    if (updates.locked !== undefined) patch.locked = updates.locked;

    await ctx.db.patch(layerId, patch);
  },
});
