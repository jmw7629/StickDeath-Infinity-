import { useNavigate } from "react-router-dom";
import { Plus, Clock, Layout, Music, Image, ChevronRight, Play } from "lucide-react";
import { Button } from "@/components/ui/button";
import BottomNav from "@/components/BottomNav";

interface Project {
  id: string;
  name: string;
  frames: number;
  lastEdited: string;
  thumbnail: string | null;
}

// Placeholder projects
const RECENT_PROJECTS: Project[] = [];

const TEMPLATES = [
  { id: "walk", name: "Walk Cycle", frames: 8, desc: "Basic walking animation" },
  { id: "fight", name: "Fight Combo", frames: 12, desc: "3-hit attack sequence" },
  { id: "death", name: "Death Scene", frames: 6, desc: "Classic stick death" },
  { id: "dance", name: "Dance Loop", frames: 16, desc: "Looping dance moves" },
  { id: "run", name: "Run Cycle", frames: 6, desc: "Smooth running loop" },
  { id: "jump", name: "Jump Arc", frames: 8, desc: "Jump with squash & stretch" },
];

export default function StudioHubPage() {
  const navigate = useNavigate();
  // activeSection for future use — tabs for recent/templates/drafts

  const handleNewProject = () => {
    navigate("/studio/project/new");
  };

  const handleOpenProject = (id: string) => {
    navigate(`/studio/project/${id}`);
  };

  return (
    <div className="min-h-screen bg-[#0a0a0f] pb-16">
      {/* Header */}
      <div className="sticky top-0 z-30 bg-[#0a0a0f]/90 backdrop-blur-xl border-b border-[#2a2a3a]">
        <div className="px-4 py-3 flex items-center justify-between">
          <h1 className="text-lg font-bold text-white font-['Special_Elite']">Studio</h1>
          <Button
            className="bg-red-600 hover:bg-red-700 text-white text-xs font-bold h-8 px-3"
            size="sm"
            onClick={handleNewProject}
          >
            <Plus size={14} className="mr-1" />
            New Project
          </Button>
        </div>
      </div>

      {/* Continue Last Project */}
      {RECENT_PROJECTS.length > 0 && (
        <div className="px-4 pt-4">
          <button
            type="button"
            onClick={() => handleOpenProject(RECENT_PROJECTS[0].id)}
            className="w-full bg-gradient-to-r from-[#1a1a24] to-[#111118] border border-[#2a2a3a] rounded-xl p-4 flex items-center gap-4 hover:border-[#3a3a4a] transition-all"
          >
            <div className="w-16 h-12 rounded-lg bg-[#0a0a0f] border border-[#2a2a3a] flex items-center justify-center">
              <Play size={18} className="text-red-500" />
            </div>
            <div className="flex-1 text-left">
              <p className="text-xs font-bold text-white">{RECENT_PROJECTS[0].name}</p>
              <p className="text-[10px] text-[#72728a]">
                {RECENT_PROJECTS[0].frames} frames · Edited {RECENT_PROJECTS[0].lastEdited}
              </p>
            </div>
            <ChevronRight size={16} className="text-[#5a5a6e]" />
          </button>
        </div>
      )}

      {/* Empty state — no projects yet */}
      {RECENT_PROJECTS.length === 0 && (
        <div className="px-4 pt-8 text-center">
          <div className="w-20 h-20 mx-auto mb-4 rounded-2xl bg-[#111118] border border-[#2a2a3a] flex items-center justify-center">
            <span className="text-4xl">🎬</span>
          </div>
          <h2 className="text-base font-bold text-white mb-1">No projects yet</h2>
          <p className="text-xs text-[#72728a] mb-4 max-w-xs mx-auto">
            Create your first stick figure animation. Start from scratch or pick a template below.
          </p>
          <Button
            className="bg-red-600 hover:bg-red-700 text-white font-bold px-6"
            onClick={handleNewProject}
          >
            <Plus size={16} className="mr-2" />
            Create Animation
          </Button>
        </div>
      )}

      {/* Recent Projects */}
      {RECENT_PROJECTS.length > 0 && (
        <div className="px-4 pt-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-xs font-bold text-white uppercase tracking-wide flex items-center gap-1.5">
              <Clock size={12} className="text-[#72728a]" />
              Recent Projects
            </h2>
          </div>
          <div className="grid grid-cols-2 gap-2">
            {RECENT_PROJECTS.map((project) => (
              <button
                key={project.id}
                type="button"
                onClick={() => handleOpenProject(project.id)}
                className="bg-[#111118] border border-[#2a2a3a] rounded-xl p-3 text-left hover:border-[#3a3a4a] transition-all"
              >
                <div className="w-full aspect-video rounded-lg bg-[#0a0a0f] border border-[#1a1a24] mb-2 flex items-center justify-center">
                  <Play size={16} className="text-[#3a3a4a]" />
                </div>
                <p className="text-xs font-medium text-white truncate">{project.name}</p>
                <p className="text-[10px] text-[#5a5a6e]">{project.frames} frames · {project.lastEdited}</p>
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Templates */}
      <div className="px-4 pt-5">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-xs font-bold text-white uppercase tracking-wide flex items-center gap-1.5">
            <Layout size={12} className="text-[#72728a]" />
            Templates
          </h2>
        </div>
        <div className="grid grid-cols-2 gap-2">
          {TEMPLATES.map((tpl) => (
            <button
              key={tpl.id}
              type="button"
              onClick={handleNewProject}
              className="bg-[#111118] border border-[#2a2a3a] rounded-xl p-3 text-left hover:border-red-600/30 transition-all group"
            >
              <div className="w-full aspect-video rounded-lg bg-[#0a0a0f] border border-[#1a1a24] mb-2 flex items-center justify-center">
                <span className="text-2xl opacity-40 group-hover:opacity-70 transition-opacity">💀</span>
              </div>
              <p className="text-xs font-medium text-white">{tpl.name}</p>
              <p className="text-[10px] text-[#5a5a6e]">{tpl.frames} frames · {tpl.desc}</p>
            </button>
          ))}
        </div>
      </div>

      {/* Asset Packs */}
      <div className="px-4 pt-5 pb-4">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-xs font-bold text-white uppercase tracking-wide">Asset Packs</h2>
        </div>
        <div className="space-y-2">
          <button
            type="button"
            className="w-full bg-[#111118] border border-[#2a2a3a] rounded-xl p-3 flex items-center gap-3 hover:border-[#3a3a4a] transition-all"
          >
            <div className="w-10 h-10 rounded-lg bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center">
              <Image size={16} className="text-[#72728a]" />
            </div>
            <div className="flex-1 text-left">
              <p className="text-xs font-medium text-white">Background Packs</p>
              <p className="text-[10px] text-[#5a5a6e]">Arenas, cities, landscapes</p>
            </div>
            <span className="text-[10px] text-[#5a5a6e]">Coming soon</span>
          </button>
          <button
            type="button"
            className="w-full bg-[#111118] border border-[#2a2a3a] rounded-xl p-3 flex items-center gap-3 hover:border-[#3a3a4a] transition-all"
          >
            <div className="w-10 h-10 rounded-lg bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center">
              <Music size={16} className="text-[#72728a]" />
            </div>
            <div className="flex-1 text-left">
              <p className="text-xs font-medium text-white">Sound Packs</p>
              <p className="text-[10px] text-[#5a5a6e]">Punches, slashes, explosions</p>
            </div>
            <span className="text-[10px] text-[#5a5a6e]">Coming soon</span>
          </button>
        </div>
      </div>

      <BottomNav />
    </div>
  );
}
