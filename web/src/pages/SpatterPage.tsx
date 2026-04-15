import { useState, useRef, useEffect, useCallback } from "react";
import { useAction, useMutation, useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { Droplets, Send, Globe, Lock, Sparkles, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import BottomNav from "@/components/BottomNav";

interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

const SPATTER_AVATAR = (
  <div className="w-8 h-8 rounded-full bg-red-600/20 border border-red-600/30 flex items-center justify-center shrink-0">
    <Droplets size={16} className="text-red-500 fill-red-500/30" />
  </div>
);

const QUICK_ACTIONS = [
  { icon: "🦾", text: "Suggest a pose" },
  { icon: "👍", text: "Review my animation" },
  { icon: "✨", text: "How does auto-tween work?" },
  { icon: "💡", text: "Give me an animation tip" },
  { icon: "🥊", text: "Help me create a fight scene" },
  { icon: "🎬", text: "How do I export my animation?" },
  { icon: "🎨", text: "What tools does the studio have?" },
  { icon: "🔥", text: "How do I go viral on the feed?" },
];

// Generate a persistent session ID
function getSessionId(): string {
  const key = "spatter-dm-session";
  let id = localStorage.getItem(key);
  if (!id) {
    id = `dm-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    localStorage.setItem(key, id);
  }
  return id;
}

export default function SpatterPage() {
  const sessionId = useRef(getSessionId()).current;
  const dbMessages = useQuery(api.spatter.getHistory, { sessionId });
  const chatAction = useAction(api.spatter.chat);
  const saveMessage = useMutation(api.spatter.saveMessage);
  const clearHistory = useMutation(api.spatter.clearHistory);

  const [localMessages, setLocalMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [isPublic, setIsPublic] = useState(false);
  const [isTyping, setIsTyping] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Sync DB messages to local state on load
  useEffect(() => {
    if (dbMessages && localMessages.length === 0) {
      setLocalMessages(
        dbMessages.map((m) => ({
          id: m._id,
          role: m.role,
          content: m.content,
        })),
      );
    }
  }, [dbMessages]);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [localMessages, isTyping]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || isTyping) return;

      const userMsg: ChatMessage = {
        id: `user-${Date.now()}`,
        role: "user",
        content: text.trim(),
      };

      setLocalMessages((prev) => [...prev, userMsg]);
      setInput("");
      setIsTyping(true);

      // Save user message to DB
      saveMessage({
        sessionId,
        role: "user",
        content: text.trim(),
        context: "spatter-dm",
      });

      // Build conversation history for AI
      const history = localMessages.map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.content,
      }));

      try {
        const response = await chatAction({
          message: text.trim(),
          conversationHistory: history,
          context: { page: "/spatter" },
        });

        const spatterMsg: ChatMessage = {
          id: `spatter-${Date.now()}`,
          role: "assistant",
          content: response,
        };
        setLocalMessages((prev) => [...prev, spatterMsg]);

        // Save Spatter's response
        saveMessage({
          sessionId,
          role: "assistant",
          content: response,
          context: "spatter-dm",
        });
      } catch (err) {
        console.error("Spatter error:", err);
        const errorMsg: ChatMessage = {
          id: `error-${Date.now()}`,
          role: "assistant",
          content: "My connection glitched 💀 Try again?",
        };
        setLocalMessages((prev) => [...prev, errorMsg]);
      } finally {
        setIsTyping(false);
      }
    },
    [localMessages, isTyping, chatAction, saveMessage, sessionId],
  );

  const handleClear = async () => {
    await clearHistory({ sessionId });
    setLocalMessages([]);
  };

  const showQuickActions = localMessages.length === 0;

  return (
    <div className="min-h-screen bg-[#0a0a0f] flex flex-col pb-14">
      {/* Header */}
      <div className="sticky top-0 z-30 bg-[#0a0a0f]/90 backdrop-blur-xl border-b border-[#2a2a3a]">
        <div className="px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            {SPATTER_AVATAR}
            <div>
              <h1 className="text-sm font-bold text-white flex items-center gap-1.5">
                Spatter
                <Sparkles size={12} className="text-red-500" />
              </h1>
              <div className="flex items-center gap-1.5">
                <div className="w-1.5 h-1.5 rounded-full bg-green-500" />
                <p className="text-[10px] text-green-500">online</p>
              </div>
            </div>
          </div>

          <div className="flex items-center gap-2">
            {/* Clear chat */}
            {localMessages.length > 0 && (
              <button
                type="button"
                onClick={handleClear}
                className="p-2 rounded-full text-[#72728a] hover:text-white hover:bg-[#1a1a24] transition-all"
                title="Clear chat"
              >
                <Trash2 size={14} />
              </button>
            )}

            {/* Public/Private toggle */}
            <button
              type="button"
              onClick={() => setIsPublic(!isPublic)}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-medium transition-all border ${
                isPublic
                  ? "bg-red-600/10 border-red-600/30 text-red-400"
                  : "bg-[#111118] border-[#2a2a3a] text-[#72728a]"
              }`}
            >
              {isPublic ? (
                <>
                  <Globe size={12} />
                  Public
                </>
              ) : (
                <>
                  <Lock size={12} />
                  Private
                </>
              )}
            </button>
          </div>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 py-4 space-y-4">
        {/* Welcome message (always shown) */}
        <div className="flex gap-2">
          {SPATTER_AVATAR}
          <div className="max-w-[80%] rounded-2xl px-4 py-2.5 text-sm whitespace-pre-line bg-[#111118] border border-[#2a2a3a] text-[#d0d0dc] rounded-tl-md">
            Yo! I&apos;m Spatter 🎨 Your animation assistant, creative coach,
            and stick figure expert. Ask me anything — poses, fight scenes,
            animation tips, how to use the studio tools, or just brainstorm
            ideas. What&apos;re you working on?
          </div>
        </div>

        {localMessages.map((msg) => (
          <div
            key={msg.id}
            className={`flex gap-2 ${msg.role === "user" ? "flex-row-reverse" : ""}`}
          >
            {msg.role === "assistant" && SPATTER_AVATAR}
            <div
              className={`max-w-[80%] rounded-2xl px-4 py-2.5 text-sm whitespace-pre-line ${
                msg.role === "user"
                  ? "bg-red-600 text-white rounded-tr-md"
                  : "bg-[#111118] border border-[#2a2a3a] text-[#d0d0dc] rounded-tl-md"
              }`}
            >
              {msg.content}
            </div>
          </div>
        ))}

        {isTyping && (
          <div className="flex gap-2">
            {SPATTER_AVATAR}
            <div className="bg-[#111118] border border-[#2a2a3a] rounded-2xl rounded-tl-md px-4 py-3">
              <div className="flex gap-1">
                <div
                  className="w-2 h-2 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "0ms" }}
                />
                <div
                  className="w-2 h-2 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "150ms" }}
                />
                <div
                  className="w-2 h-2 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "300ms" }}
                />
              </div>
            </div>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Quick Actions */}
      {showQuickActions && (
        <div className="px-4 pb-2">
          <div className="flex gap-2 overflow-x-auto pb-2 scrollbar-none">
            {QUICK_ACTIONS.map((action) => (
              <button
                key={action.text}
                type="button"
                onClick={() => sendMessage(action.text)}
                className="flex items-center gap-1.5 px-3 py-2 rounded-full border border-[#2a2a3a] bg-[#111118] hover:bg-[#1a1a24] text-xs text-[#d0d0dc] whitespace-nowrap transition-colors shrink-0"
              >
                <span>{action.icon}</span>
                {action.text}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Input area */}
      <div className="sticky bottom-14 bg-[#0a0a0f] border-t border-[#2a2a3a] p-3">
        <div className="flex gap-2 items-center max-w-2xl mx-auto">
          <input
            ref={inputRef}
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && sendMessage(input)}
            placeholder={
              isPublic
                ? "Ask Spatter publicly..."
                : "Ask Spatter anything..."
            }
            className="flex-1 bg-[#111118] border border-[#2a2a3a] rounded-full px-4 py-2.5 text-sm text-white placeholder-[#5a5a6e] focus:outline-none focus:border-red-600/50 transition-colors"
            disabled={isTyping}
          />
          <Button
            size="icon"
            onClick={() => sendMessage(input)}
            disabled={!input.trim() || isTyping}
            className="bg-red-600 hover:bg-red-700 text-white rounded-full w-10 h-10 shrink-0 disabled:opacity-30"
          >
            <Send size={16} />
          </Button>
        </div>
      </div>

      <BottomNav />
    </div>
  );
}
