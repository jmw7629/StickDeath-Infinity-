import { useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { useNavigate } from "react-router-dom";
import { Trophy, Clock, Users, ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import BottomNav from "@/components/BottomNav";

function formatTimeLeft(endAt: number): string {
  const diff = endAt - Date.now();
  if (diff <= 0) return "Ended";
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
  if (days > 0) return `${days}d ${hours}h left`;
  return `${hours}h left`;
}

const statusColors = {
  active: "bg-red-600 text-white",
  upcoming: "bg-white/10 text-[#72728a]",
  voting: "bg-purple-600 text-white",
  completed: "bg-[#72728a]/20 text-[#72728a]",
};

const statusLabels = {
  active: "🔴 LIVE",
  upcoming: "Coming Soon",
  voting: "Voting Open",
  completed: "Completed",
};

export default function ChallengesPage() {
  const challenges = useQuery(api.challenges.list, {});
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-[#0a0a0f] pb-14">
      {/* Header */}
      <div className="bg-gradient-to-b from-red-600/10 to-transparent">
        <div className="container mx-auto px-4 py-12 text-center">
          <Trophy className="mx-auto text-red-600 mb-4" size={48} />
          <h1 className="text-4xl font-black text-white mb-2">Challenges</h1>
          <p className="text-[#72728a] max-w-md mx-auto">
            Compete with the community. Create epic animations. Win bragging rights.
          </p>
        </div>
      </div>

      {/* Challenge list */}
      <div className="container mx-auto max-w-3xl px-4 pb-12">
        {challenges === undefined ? (
          <div className="space-y-4">
            {Array.from({ length: 3 }).map((_, i) => (
              <div key={i} className="animate-pulse bg-[#111118] rounded-2xl h-40 border border-white/5" />
            ))}
          </div>
        ) : challenges.length === 0 ? (
          <div className="text-center py-20">
            <div className="text-6xl mb-4">🏆</div>
            <h2 className="text-2xl font-black text-white mb-2">No Challenges Yet</h2>
            <p className="text-[#72728a]">First challenges dropping soon. Stay tuned.</p>
          </div>
        ) : (
          <div className="space-y-4">
            {challenges.map((challenge) => (
              <div
                key={challenge._id}
                className={`group relative bg-[#111118] rounded-2xl border overflow-hidden transition-all hover:shadow-lg ${
                  challenge.status === "active"
                    ? "border-red-600/30 hover:border-red-600/50 hover:shadow-red-600/5"
                    : "border-white/5 hover:border-white/10"
                }`}
              >
                <div className="p-6">
                  <div className="flex items-start justify-between mb-3">
                    <div>
                      <span
                        className={`inline-block text-[10px] font-bold uppercase tracking-wider px-2 py-1 rounded-full mb-2 ${
                          statusColors[challenge.status]
                        }`}
                      >
                        {statusLabels[challenge.status]}
                      </span>
                      <h2 className="text-xl font-black text-white">{challenge.title}</h2>
                    </div>
                    {challenge.status === "active" && (
                      <div className="flex items-center gap-1 text-red-500 text-xs font-bold">
                        <Clock size={14} />
                        {formatTimeLeft(challenge.endAt)}
                      </div>
                    )}
                  </div>

                  <p className="text-sm text-[#72728a] mb-4 leading-relaxed">
                    {challenge.description}
                  </p>

                  {challenge.rules && (
                    <div className="text-xs text-[#72728a]/60 bg-white/3 rounded-lg p-3 mb-4">
                      <span className="font-bold text-[#72728a]">Rules:</span> {challenge.rules}
                    </div>
                  )}

                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-1 text-xs text-[#72728a]">
                      <Users size={14} />
                      {challenge.submissionCount} submissions
                    </div>
                    {challenge.status === "active" && (
                      <Button
                        className="bg-red-600 hover:bg-red-700 text-white text-xs font-bold gap-1"
                        size="sm"
                        onClick={() => navigate("/studio")}
                      >
                        Enter Challenge
                        <ArrowRight size={14} />
                      </Button>
                    )}
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
