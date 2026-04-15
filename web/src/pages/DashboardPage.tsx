import { useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { useNavigate } from "react-router-dom";
import {
  Plus,
  Flame,
  Trophy,
  Layers,
  Clock,
  ArrowRight,
} from "lucide-react";
import { Button } from "@/components/ui/button";

export default function DashboardPage() {
  const profile = useQuery(api.profiles.getMyProfile);
  const projects = useQuery(api.projects.list);
  const challenges = useQuery(api.challenges.list, { status: "active" });
  const navigate = useNavigate();

  return (
    <div className="space-y-8">
      {/* Welcome header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-black text-white">
            {profile ? `Hey, ${profile.displayName}` : "Welcome back"} 💀
          </h1>
          <p className="text-[#72728a] text-sm mt-1">
            Ready to create some chaos?
          </p>
        </div>
        <Button
          className="bg-red-600 hover:bg-red-700 text-white font-bold gap-2"
          onClick={() => navigate("/studio")}
        >
          <Plus size={18} />
          New Animation
        </Button>
      </div>

      {/* Quick stats */}
      {profile && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div className="bg-[#111118] rounded-xl p-4 border border-white/5">
            <div className="text-2xl font-black text-white">{projects?.length ?? 0}</div>
            <div className="text-xs text-[#72728a] flex items-center gap-1 mt-1">
              <Layers size={12} />
              Projects
            </div>
          </div>
          <div className="bg-[#111118] rounded-xl p-4 border border-white/5">
            <div className="text-2xl font-black text-red-500">0</div>
            <div className="text-xs text-[#72728a] flex items-center gap-1 mt-1">
              <Flame size={12} />
              Reactions
            </div>
          </div>
          <div className="bg-[#111118] rounded-xl p-4 border border-white/5">
            <div className="text-2xl font-black text-white">0</div>
            <div className="text-xs text-[#72728a] flex items-center gap-1 mt-1">
              Followers
            </div>
          </div>
          <div className="bg-[#111118] rounded-xl p-4 border border-white/5">
            <div className="text-2xl font-black text-white">{challenges?.length ?? 0}</div>
            <div className="text-xs text-[#72728a] flex items-center gap-1 mt-1">
              <Trophy size={12} />
              Active Challenges
            </div>
          </div>
        </div>
      )}

      {/* Active challenge promo */}
      {challenges && challenges.length > 0 && (
        <div className="bg-gradient-to-r from-red-600/10 via-red-600/5 to-transparent rounded-2xl border border-red-600/20 p-6">
          <div className="flex items-center gap-2 mb-2">
            <Trophy className="text-red-500" size={20} />
            <span className="text-xs font-bold text-red-500 uppercase tracking-wider">
              Active Challenge
            </span>
          </div>
          <h3 className="text-xl font-black text-white mb-1">
            {challenges[0].title}
          </h3>
          <p className="text-sm text-[#72728a] mb-4">
            {challenges[0].description}
          </p>
          <Button
            variant="outline"
            className="border-red-600/30 text-red-500 hover:bg-red-600/10 gap-1 text-xs"
            onClick={() => navigate("/challenges")}
          >
            Enter Challenge
            <ArrowRight size={14} />
          </Button>
        </div>
      )}

      {/* Projects grid */}
      <div>
        <h2 className="text-lg font-bold text-white mb-4">Your Projects</h2>
        {projects === undefined ? (
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="animate-pulse bg-[#111118] rounded-xl aspect-video border border-white/5" />
            ))}
          </div>
        ) : projects.length === 0 ? (
          <div
            className="bg-[#111118] rounded-2xl border border-dashed border-white/10 p-12 text-center cursor-pointer hover:border-red-600/30 transition-colors"
            onClick={() => navigate("/studio")}
          >
            <div className="text-4xl mb-3">✨</div>
            <h3 className="text-lg font-bold text-white mb-1">Create your first animation</h3>
            <p className="text-sm text-[#72728a]">
              Open the studio and start drawing — it's that simple.
            </p>
          </div>
        ) : (
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
            {/* New project card */}
            <div
              className="bg-[#111118] rounded-xl border border-dashed border-white/10 aspect-video flex flex-col items-center justify-center cursor-pointer hover:border-red-600/30 transition-colors"
              onClick={() => navigate("/studio")}
            >
              <Plus size={24} className="text-[#72728a] mb-1" />
              <span className="text-xs text-[#72728a]">New Project</span>
            </div>

            {projects.map((project) => (
              <div
                key={project._id}
                className="bg-[#111118] rounded-xl border border-white/5 aspect-video overflow-hidden cursor-pointer hover:border-white/15 transition-colors group"
              >
                <div className="w-full h-full flex flex-col">
                  <div className="flex-1 bg-[#0d0d14] flex items-center justify-center">
                    {project.thumbnailUrl ? (
                      <img
                        src={project.thumbnailUrl}
                        alt={project.name}
                        className="w-full h-full object-contain"
                      />
                    ) : (
                      <span className="text-2xl opacity-20">🎬</span>
                    )}
                  </div>
                  <div className="px-3 py-2">
                    <div className="text-xs font-bold text-white truncate">
                      {project.name}
                    </div>
                    <div className="text-[10px] text-[#72728a] flex items-center gap-2 mt-0.5">
                      <span>{project.frameCount} frames</span>
                      <span>·</span>
                      <span>{project.fps} fps</span>
                      <span>·</span>
                      <span className="flex items-center gap-0.5">
                        <Clock size={9} />
                        {new Date(project.updatedAt).toLocaleDateString()}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
