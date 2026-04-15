import { useState, useRef, useEffect, useCallback } from "react";
import { useAction } from "convex/react";
import { api } from "../../../convex/_generated/api";
import { Droplets, Send, X, Sparkles } from "lucide-react";

interface ChatBubble {
  id: string;
  role: "user" | "assistant";
  content: string;
}

const QUICK_CHIPS = [
  {
    icon: "🦾",
    text: "Suggest a pose",
    color: "bg-red-500/12 text-red-400 border-red-500/20",
  },
  {
    icon: "👍",
    text: "Review my work",
    color: "bg-green-500/12 text-green-400 border-green-500/20",
  },
  {
    icon: "✨",
    text: "Auto-tween tips",
    color: "bg-purple-500/12 text-purple-400 border-purple-500/20",
  },
  {
    icon: "💡",
    text: "Animation tip",
    color: "bg-yellow-500/12 text-yellow-400 border-yellow-500/20",
  },
  {
    icon: "🥊",
    text: "Fight scene",
    color: "bg-red-500/12 text-red-400 border-red-500/20",
  },
];

interface Props {
  frameCount: number;
  currentFrameIndex: number;
  layerCount: number;
  fps: number;
  onClose: () => void;
}

export default function SpatterStudioPanel({
  frameCount,
  currentFrameIndex,
  layerCount,
  fps,
  onClose,
}: Props) {
  const [messages, setMessages] = useState<ChatBubble[]>([]);
  const [prompt, setPrompt] = useState("");
  const [isTyping, setIsTyping] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const chatAction = useAction(api.spatter.chat);

  useEffect(() => {
    scrollRef.current?.scrollTo({
      top: scrollRef.current.scrollHeight,
      behavior: "smooth",
    });
  }, [messages, isTyping]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || isTyping) return;
      setPrompt("");

      const userMsg: ChatBubble = {
        id: `u-${Date.now()}`,
        role: "user",
        content: text.trim(),
      };
      setMessages((prev) => [...prev, userMsg]);
      setIsTyping(true);

      const history = messages.map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.content,
      }));

      try {
        const response = await chatAction({
          message: text.trim(),
          conversationHistory: history,
          context: {
            page: "/studio/project",
            frameCount,
            currentFrame: currentFrameIndex,
            layerCount,
            fps,
          },
        });

        setMessages((prev) => [
          ...prev,
          { id: `s-${Date.now()}`, role: "assistant", content: response },
        ]);
      } catch (err) {
        console.error("Studio Spatter error:", err);
        setMessages((prev) => [
          ...prev,
          {
            id: `e-${Date.now()}`,
            role: "assistant",
            content: "Brain glitch 💀 Try again?",
          },
        ]);
      } finally {
        setIsTyping(false);
      }
    },
    [
      messages,
      isTyping,
      chatAction,
      frameCount,
      currentFrameIndex,
      layerCount,
      fps,
    ],
  );

  const showQuickActions = messages.length === 0;

  return (
    <div className="w-72 bg-[#111118] border-l border-[#2a2a3a] flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-2 border-b border-[#2a2a3a]">
        <div className="flex items-center gap-2">
          <div className="w-6 h-6 rounded-full bg-red-600/20 flex items-center justify-center">
            <Droplets size={12} className="text-red-500 fill-red-500/30" />
          </div>
          <span className="text-xs font-bold text-white">Spatter AI</span>
          <Sparkles size={10} className="text-red-500" />
          <div className="flex items-center gap-1">
            <div className="w-1.5 h-1.5 rounded-full bg-green-500" />
            <span className="text-[9px] text-green-500">online</span>
          </div>
        </div>
        <button
          onClick={onClose}
          className="text-[#72728a] hover:text-white transition-colors"
        >
          <X size={14} />
        </button>
      </div>

      {/* Studio context badge */}
      <div className="px-3 py-1.5 border-b border-[#2a2a3a]/50 bg-[#0a0a0f]/50">
        <div className="flex items-center gap-2 text-[9px] text-[#72728a]">
          <span>🎬 {frameCount} frames</span>
          <span>•</span>
          <span>📐 {layerCount} layers</span>
          <span>•</span>
          <span>⏱ {fps}fps</span>
        </div>
      </div>

      {/* Chat area */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto px-3 py-3 space-y-3 min-h-0"
      >
        {/* Welcome message */}
        {messages.length === 0 && (
          <div className="flex gap-2">
            <div className="w-5 h-5 rounded-full bg-red-600/20 flex items-center justify-center shrink-0 mt-0.5">
              <span className="text-[8px]">🎨</span>
            </div>
            <div className="bg-[#0a0a0f] border border-[#2a2a3a] rounded-xl rounded-tl-sm px-3 py-2 text-xs text-[#d0d0dc] leading-relaxed">
              I can see your project — {frameCount} frame
              {frameCount !== 1 ? "s" : ""} at {fps}fps. Need a pose, timing
              advice, or help with a scene? 🩸
            </div>
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`flex gap-2 ${msg.role === "user" ? "flex-row-reverse" : ""}`}
          >
            {msg.role === "assistant" && (
              <div className="w-5 h-5 rounded-full bg-red-600/20 flex items-center justify-center shrink-0 mt-0.5">
                <span className="text-[8px]">🎨</span>
              </div>
            )}
            <div
              className={`max-w-[90%] rounded-xl px-3 py-2 text-xs leading-relaxed whitespace-pre-line ${
                msg.role === "user"
                  ? "bg-red-600 text-white rounded-tr-sm"
                  : "bg-[#0a0a0f] border border-[#2a2a3a] text-[#d0d0dc] rounded-tl-sm"
              }`}
            >
              {msg.content}
            </div>
          </div>
        ))}

        {isTyping && (
          <div className="flex gap-2">
            <div className="w-5 h-5 rounded-full bg-red-600/20 flex items-center justify-center shrink-0">
              <span className="text-[8px]">🎨</span>
            </div>
            <div className="bg-[#0a0a0f] border border-[#2a2a3a] rounded-xl rounded-tl-sm px-3 py-2">
              <div className="flex gap-1">
                <div
                  className="w-1.5 h-1.5 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "0ms" }}
                />
                <div
                  className="w-1.5 h-1.5 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "150ms" }}
                />
                <div
                  className="w-1.5 h-1.5 rounded-full bg-red-500/60 animate-bounce"
                  style={{ animationDelay: "300ms" }}
                />
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Quick action chips */}
      {showQuickActions && (
        <div className="px-3 pb-2">
          <div className="flex flex-wrap gap-1.5">
            {QUICK_CHIPS.map((chip) => (
              <button
                key={chip.text}
                type="button"
                onClick={() => sendMessage(chip.text)}
                disabled={isTyping}
                className={`flex items-center gap-1 px-2.5 py-1.5 rounded-full border text-[10px] font-medium transition-colors hover:brightness-125 disabled:opacity-50 ${chip.color}`}
              >
                <span>{chip.icon}</span>
                {chip.text}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Input */}
      <div className="border-t border-[#2a2a3a] p-2">
        <div className="flex gap-1.5 items-center">
          <input
            type="text"
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && sendMessage(prompt)}
            placeholder="Ask Spatter anything..."
            className="flex-1 bg-[#0a0a0f] border border-[#2a2a3a] rounded-lg px-3 py-1.5 text-xs text-white placeholder-[#5a5a6e] focus:outline-none focus:border-red-600/50 transition-colors"
            disabled={isTyping}
          />
          <button
            onClick={() => sendMessage(prompt)}
            disabled={!prompt.trim() || isTyping}
            className="text-red-500 hover:text-red-400 disabled:text-[#5a5a6e] transition-colors p-1"
          >
            <Send size={14} />
          </button>
        </div>
      </div>
    </div>
  );
}
