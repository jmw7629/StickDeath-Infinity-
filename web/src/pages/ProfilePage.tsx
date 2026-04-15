import { useNavigate } from "react-router-dom";
import { Settings, Film, Trophy, Grid3X3, Edit2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import BottomNav from "@/components/BottomNav";

export default function ProfilePage() {
  const navigate = useNavigate();
  // In the future, this would use the current user's profile
  // For now, show a setup screen

  return (
    <div className="min-h-screen bg-[#0a0a0f] pb-14">
      {/* Header */}
      <div className="sticky top-0 z-30 bg-[#0a0a0f]/90 backdrop-blur-xl border-b border-[#2a2a3a]">
        <div className="px-4 py-3 flex items-center justify-between">
          <h1 className="text-sm font-bold text-white">Profile</h1>
          <button
            onClick={() => navigate("/settings")}
            className="text-[#72728a] hover:text-white transition-colors"
          >
            <Settings size={20} />
          </button>
        </div>
      </div>

      {/* Profile Header */}
      <div className="px-4 py-8 text-center">
        <div className="w-20 h-20 mx-auto rounded-full bg-red-600/20 border-2 border-red-600/30 flex items-center justify-center mb-4">
          <span className="text-3xl">💀</span>
        </div>
        <h2 className="text-xl font-black text-white mb-1">Your Profile</h2>
        <p className="text-sm text-[#72728a] mb-4">@username</p>
        <Button
          className="bg-[#111118] border border-[#2a2a3a] text-white hover:bg-[#1a1a24] gap-1.5 text-xs"
          size="sm"
        >
          <Edit2 size={12} />
          Edit Profile
        </Button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-3 border-y border-[#2a2a3a] divide-x divide-[#2a2a3a]">
        <div className="py-4 text-center">
          <div className="text-lg font-black text-white">0</div>
          <div className="text-[10px] text-[#72728a] uppercase tracking-wider">Animations</div>
        </div>
        <div className="py-4 text-center">
          <div className="text-lg font-black text-white">0</div>
          <div className="text-[10px] text-[#72728a] uppercase tracking-wider">Followers</div>
        </div>
        <div className="py-4 text-center">
          <div className="text-lg font-black text-white">0</div>
          <div className="text-[10px] text-[#72728a] uppercase tracking-wider">Following</div>
        </div>
      </div>

      {/* Content tabs */}
      <div className="flex border-b border-[#2a2a3a]">
        <button className="flex-1 py-3 flex items-center justify-center gap-1.5 text-xs font-medium text-white border-b-2 border-red-600">
          <Grid3X3 size={14} />
          Animations
        </button>
        <button className="flex-1 py-3 flex items-center justify-center gap-1.5 text-xs font-medium text-[#72728a]">
          <Trophy size={14} />
          Challenges
        </button>
        <button className="flex-1 py-3 flex items-center justify-center gap-1.5 text-xs font-medium text-[#72728a]">
          <Film size={14} />
          Liked
        </button>
      </div>

      {/* Empty state */}
      <div className="text-center py-16">
        <div className="text-5xl mb-4">🎬</div>
        <h3 className="text-lg font-bold text-white mb-2">No Animations Yet</h3>
        <p className="text-sm text-[#72728a] mb-6">Create your first stick figure animation</p>
        <Button
          className="bg-red-600 hover:bg-red-700 text-white font-bold"
          onClick={() => navigate("/studio")}
        >
          Open Studio
        </Button>
      </div>

      <BottomNav />
    </div>
  );
}
