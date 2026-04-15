import { useState, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { Send, Heart, Flame, MessageCircle, Play, Trophy, User, ChevronRight } from "lucide-react";
import BottomNav from "@/components/BottomNav";

// Simulated community messages
const SEED_MESSAGES = [
  {
    id: "1",
    user: { name: "Spatter", avatar: "🩸", isBot: true, verified: true },
    text: "Welcome to StickDeath ∞! 🎨 Share your animations, get feedback, and connect with other creators. The bloodier the better. 💀",
    time: "2m ago",
    likes: 12,
    replies: 3,
    type: "text" as const,
  },
  {
    id: "2",
    user: { name: "StickMaster99", avatar: "💀", isBot: false, verified: false },
    text: "Just finished my first fight scene! 6 frames of pure chaos. How do you guys do smooth walk cycles?",
    time: "5m ago",
    likes: 8,
    replies: 5,
    type: "text" as const,
  },
  {
    id: "3",
    user: { name: "Spatter", avatar: "🩸", isBot: true, verified: true },
    text: "🔥 Weekly Challenge is LIVE: \"Epic Death Scene\" — Create the most creative death animation. Winner gets featured! Ends in 3 days.",
    time: "15m ago",
    likes: 24,
    replies: 11,
    type: "announcement" as const,
  },
  {
    id: "4",
    user: { name: "AnimateOrDie", avatar: "⚔️", isBot: false, verified: false },
    text: "Pro tip: use onion skinning set to 2 frames before/after for fight scenes. Changes everything.",
    time: "22m ago",
    likes: 31,
    replies: 7,
    type: "text" as const,
  },
  {
    id: "5",
    user: { name: "BoneBreaker", avatar: "🦴", isBot: false, verified: false },
    text: "Anyone else obsessed with the stick figure tool? I've been posing for like an hour 😂",
    time: "45m ago",
    likes: 15,
    replies: 4,
    type: "text" as const,
  },
];

const FEATURED_CHALLENGE = {
  title: "Epic Death Scene",
  entries: 47,
  timeLeft: "3 days left",
  prize: "Featured Creator",
};

export default function HomePage() {
  const navigate = useNavigate();
  const [messages] = useState(SEED_MESSAGES);
  const [newMessage, setNewMessage] = useState("");
  const [likedMessages, setLikedMessages] = useState<Set<string>>(new Set());
  const chatEndRef = useRef<HTMLDivElement>(null);

  const toggleLike = (id: string) => {
    setLikedMessages((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  return (
    <div className="min-h-screen bg-[#0a0a0f] flex flex-col">
      {/* Header */}
      <div className="sticky top-0 z-30 bg-[#0a0a0f]/90 backdrop-blur-xl border-b border-[#2a2a3a]">
        <div className="px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-1">
            <span className="text-red-600 text-base font-black tracking-tighter font-['Special_Elite']">STICK</span>
            <span className="text-white text-base font-black tracking-tighter font-['Special_Elite']">DEATH</span>
            <span className="text-red-500 text-xs ml-0.5">∞</span>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => navigate("/profile")}
              className="w-8 h-8 rounded-full bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center"
            >
              <User size={14} className="text-[#72728a]" />
            </button>
          </div>
        </div>
      </div>

      {/* Featured Challenge Banner */}
      <div className="px-4 pt-3">
        <button
          type="button"
          onClick={() => navigate("/challenges")}
          className="w-full bg-gradient-to-r from-red-600/20 to-red-900/10 border border-red-600/30 rounded-xl p-3 flex items-center gap-3 hover:border-red-500/50 transition-all"
        >
          <div className="w-10 h-10 rounded-lg bg-red-600/20 flex items-center justify-center shrink-0">
            <Trophy size={18} className="text-red-500" />
          </div>
          <div className="flex-1 text-left">
            <p className="text-xs font-bold text-white">{FEATURED_CHALLENGE.title}</p>
            <p className="text-[10px] text-[#9090a8]">{FEATURED_CHALLENGE.entries} entries · {FEATURED_CHALLENGE.timeLeft} · Prize: {FEATURED_CHALLENGE.prize}</p>
          </div>
          <ChevronRight size={16} className="text-[#5a5a6e]" />
        </button>
      </div>

      {/* Continue Project (if exists) */}
      <div className="px-4 pt-3">
        <button
          type="button"
          onClick={() => navigate("/studio")}
          className="w-full bg-[#111118] border border-[#2a2a3a] rounded-xl p-3 flex items-center gap-3 hover:border-[#3a3a4a] transition-all"
        >
          <div className="w-10 h-10 rounded-lg bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center shrink-0">
            <Play size={16} className="text-[#72728a]" />
          </div>
          <div className="flex-1 text-left">
            <p className="text-xs font-bold text-white">Continue creating</p>
            <p className="text-[10px] text-[#72728a]">Jump back into the studio</p>
          </div>
          <ChevronRight size={16} className="text-[#5a5a6e]" />
        </button>
      </div>

      {/* Community Feed — Messaging Group */}
      <div className="px-4 pt-4 pb-1">
        <div className="flex items-center justify-between mb-2">
          <h2 className="text-xs font-bold text-white uppercase tracking-wide">Community</h2>
          <span className="text-[10px] text-green-400 flex items-center gap-1">
            <span className="w-1.5 h-1.5 bg-green-400 rounded-full animate-pulse" />
            142 online
          </span>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 space-y-1 pb-36">
        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`rounded-xl p-3 transition-all ${
              msg.type === "announcement"
                ? "bg-red-600/10 border border-red-600/20"
                : "bg-[#111118] border border-[#1a1a24] hover:border-[#2a2a3a]"
            }`}
          >
            {/* User line */}
            <div className="flex items-center gap-2 mb-1.5">
              <div className={`w-7 h-7 rounded-full flex items-center justify-center text-sm ${
                msg.user.isBot ? "bg-red-600/20" : "bg-[#1a1a24] border border-[#2a2a3a]"
              }`}>
                {msg.user.avatar}
              </div>
              <div className="flex items-center gap-1.5">
                <span className={`text-xs font-bold ${msg.user.isBot ? "text-red-400" : "text-white"}`}>
                  {msg.user.name}
                </span>
                {msg.user.isBot && (
                  <span className="text-[8px] bg-red-600/20 text-red-400 px-1.5 py-0.5 rounded-full font-medium">AI</span>
                )}
              </div>
              <span className="text-[10px] text-[#5a5a6e] ml-auto">{msg.time}</span>
            </div>

            {/* Message text */}
            <p className="text-xs text-[#c0c0d0] leading-relaxed pl-9">{msg.text}</p>

            {/* Actions */}
            <div className="flex items-center gap-4 mt-2 pl-9">
              <button
                type="button"
                onClick={() => toggleLike(msg.id)}
                className={`flex items-center gap-1 text-[10px] transition-colors ${
                  likedMessages.has(msg.id) ? "text-red-500" : "text-[#5a5a6e] hover:text-red-400"
                }`}
              >
                <Heart size={12} fill={likedMessages.has(msg.id) ? "currentColor" : "none"} />
                {msg.likes + (likedMessages.has(msg.id) ? 1 : 0)}
              </button>
              <button type="button" className="flex items-center gap-1 text-[10px] text-[#5a5a6e] hover:text-[#9090a8] transition-colors">
                <MessageCircle size={12} />
                {msg.replies}
              </button>
              {msg.type === "announcement" && (
                <button type="button" className="flex items-center gap-1 text-[10px] text-red-500 hover:text-red-400 font-medium ml-auto">
                  <Flame size={12} />
                  Join Challenge
                </button>
              )}
            </div>
          </div>
        ))}
        <div ref={chatEndRef} />
      </div>

      {/* Message Input */}
      <div className="fixed bottom-14 left-0 right-0 z-30 bg-[#0a0a0f]/95 backdrop-blur-xl border-t border-[#2a2a3a] px-4 py-2">
        <div className="flex gap-2 bg-[#111118] border border-[#2a2a3a] rounded-xl px-3 py-2.5 max-w-lg mx-auto">
          <input
            type="text"
            value={newMessage}
            onChange={(e) => setNewMessage(e.target.value)}
            placeholder="Message the community..."
            className="flex-1 bg-transparent text-xs text-white placeholder:text-[#5a5a6e] outline-none"
          />
          <button
            type="button"
            className="text-red-500 disabled:text-[#3a3a4a] transition-colors"
            disabled={!newMessage.trim()}
          >
            <Send size={16} />
          </button>
        </div>
      </div>

      <BottomNav />
    </div>
  );
}
