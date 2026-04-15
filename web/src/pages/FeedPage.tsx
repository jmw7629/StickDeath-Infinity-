import { useState } from "react";
import { useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { useNavigate } from "react-router-dom";
import { Flame, Skull, Laugh, Heart, MessageCircle, Eye, TrendingUp, Clock, Award } from "lucide-react";
import { Button } from "@/components/ui/button";
import BottomNav from "@/components/BottomNav";

const REACTION_MAP = {
  fire: { icon: <Flame size={16} />, emoji: "🔥", label: "Fire" },
  skull: { icon: <Skull size={16} />, emoji: "💀", label: "Dead" },
  laugh: { icon: <Laugh size={16} />, emoji: "😂", label: "LOL" },
  support: { icon: <Heart size={16} />, emoji: "💪", label: "Support" },
} as const;

type SortOption = "trending" | "new" | "top";

const sortOptions: { value: SortOption; icon: React.ReactNode; label: string }[] = [
  { value: "trending", icon: <TrendingUp size={14} />, label: "Trending" },
  { value: "new", icon: <Clock size={14} />, label: "New" },
  { value: "top", icon: <Award size={14} />, label: "Top" },
];

export default function FeedPage() {
  const [sort, setSort] = useState<SortOption>("trending");
  const posts = useQuery(api.posts.feed, { sort, limit: 20 });
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-[#0a0a0f] pb-14">
      {/* Header */}
      <div className="sticky top-0 z-30 bg-[#0a0a0f]/90 backdrop-blur-xl border-b border-[#2a2a3a]">
        <div className="px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-0.5 shrink-0">
            <span className="text-red-600 text-base font-black tracking-tighter font-['Special_Elite']">STICK</span>
            <span className="text-white text-base font-black tracking-tighter font-['Special_Elite']">DEATH</span>
            <span className="text-red-500 text-xs ml-0.5">∞</span>
          </div>

          {/* Sort tabs */}
          <div className="flex gap-0.5 bg-[#111118] rounded-lg p-0.5 mx-2">
            {sortOptions.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setSort(opt.value)}
                className={`flex items-center gap-1 px-2.5 py-1.5 rounded-md text-[11px] font-medium transition-all ${
                  sort === opt.value
                    ? "bg-red-600 text-white"
                    : "text-[#72728a] hover:text-white"
                }`}
              >
                {opt.icon}
                {opt.label}
              </button>
            ))}
          </div>

          <Button
            className="bg-red-600 hover:bg-red-700 text-white text-[11px] font-bold shrink-0 h-8 px-3"
            size="sm"
            onClick={() => navigate("/studio")}
          >
            + Create
          </Button>
        </div>
      </div>

      {/* Feed content */}
      <div className="container mx-auto max-w-2xl px-4 py-6">
        {posts === undefined ? (
          // Loading skeleton
          <div className="space-y-4">
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="animate-pulse bg-[#111118] rounded-2xl h-80 border border-white/5" />
            ))}
          </div>
        ) : posts.length === 0 ? (
          // Empty state
          <div className="text-center py-20">
            <div className="text-6xl mb-4">💀</div>
            <h2 className="text-2xl font-black text-white mb-2">Feed's Dead</h2>
            <p className="text-[#72728a] mb-6">
              No animations yet. Be the first to create something legendary.
            </p>
            <Button
              className="bg-red-600 hover:bg-red-700 text-white font-bold"
              onClick={() => navigate("/studio")}
            >
              Open Studio
            </Button>
          </div>
        ) : (
          <div className="space-y-4">
            {posts.map((post) => (
              <div
                key={post._id}
                className="bg-[#111118] rounded-2xl border border-white/5 overflow-hidden hover:border-white/10 transition-colors"
              >
                {/* Creator header */}
                <div className="flex items-center gap-3 p-4 pb-2">
                  <div className="w-8 h-8 rounded-full bg-red-600/20 flex items-center justify-center text-xs font-bold text-red-500">
                    {post.creator?.displayName?.[0]?.toUpperCase() ?? "?"}
                  </div>
                  <div className="flex-1">
                    <div className="text-sm font-bold text-white">
                      {post.creator?.displayName ?? "Unknown"}
                    </div>
                    <div className="text-[10px] text-[#72728a]">
                      @{post.creator?.username ?? "anon"}
                    </div>
                  </div>
                  {post.challengeId && (
                    <span className="text-[10px] font-bold text-red-500 bg-red-500/10 px-2 py-1 rounded-full">
                      🏆 Challenge
                    </span>
                  )}
                </div>

                {/* Animation preview area */}
                <div className="aspect-video bg-[#0d0d14] flex items-center justify-center">
                  {post.thumbnailUrl ? (
                    <img
                      src={post.thumbnailUrl}
                      alt={post.title}
                      className="w-full h-full object-contain"
                    />
                  ) : (
                    <div className="text-[#72728a] text-sm">
                      🎬 {post.title}
                    </div>
                  )}
                </div>

                {/* Title & interactions */}
                <div className="p-4 pt-3">
                  <h3 className="text-sm font-bold text-white mb-2">{post.title}</h3>
                  {post.description && (
                    <p className="text-xs text-[#72728a] mb-3 line-clamp-2">
                      {post.description}
                    </p>
                  )}

                  {/* Reaction bar */}
                  <div className="flex items-center justify-between">
                    <div className="flex gap-2">
                      {Object.entries(REACTION_MAP).map(([key, val]) => (
                        <button
                          key={key}
                          type="button"
                          className="flex items-center gap-1 px-2.5 py-1.5 rounded-full bg-white/5 hover:bg-white/10 text-[#72728a] hover:text-white transition-all text-xs"
                        >
                          <span>{val.emoji}</span>
                        </button>
                      ))}
                    </div>
                    <div className="flex items-center gap-3 text-[#72728a]">
                      <span className="flex items-center gap-1 text-xs">
                        <MessageCircle size={13} />
                        {post.commentCount}
                      </span>
                      <span className="flex items-center gap-1 text-xs">
                        <Eye size={13} />
                        {post.viewCount}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <BottomNav />
    </div>
  );
}
