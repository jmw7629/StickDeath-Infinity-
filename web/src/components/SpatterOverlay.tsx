import { useState, useRef, useEffect, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { useAction } from "convex/react";
import { api } from "../../convex/_generated/api";
import { X, Send, Sparkles, Lightbulb, Palette, History } from "lucide-react";

// Blood drop SVG icon
const BloodDropIcon = ({
  size = 24,
  className = "",
}: {
  size?: number;
  className?: string;
}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    className={className}
  >
    <path
      d="M12 2.5C12 2.5 5 11 5 15.5C5 19.366 8.134 22.5 12 22.5C15.866 22.5 19 19.366 19 15.5C19 11 12 2.5 12 2.5Z"
      fill="currentColor"
      fillOpacity="0.3"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

// Context-aware greeting based on current screen
function getContextGreeting(path: string): string {
  if (path.startsWith("/home"))
    return "Need inspiration? Ask me about trending styles, animation ideas, or how to grow your audience.";
  if (path.startsWith("/challenges"))
    return "Looking at challenges? I can help with concepts, techniques, or planning your entry.";
  if (path.startsWith("/studio/project"))
    return "I'm your studio assistant — poses, tips, fight choreography, tool help, anything. What do you need?";
  if (path.startsWith("/studio"))
    return "Need help picking a project or getting started? Ask me anything about animation!";
  if (path.startsWith("/profile"))
    return "I can help you grow your audience, optimize your profile, or plan your next content.";
  return "Yo! I'm Spatter 🎨 Ask me anything about animation, the studio tools, or creative ideas.";
}

// Context-aware quick chips
function getContextChips(path: string): string[] {
  if (path.startsWith("/home"))
    return [
      "What's trending?",
      "Content ideas",
      "How to go viral",
      "Inspiration",
    ];
  if (path.startsWith("/challenges"))
    return [
      "Challenge tips",
      "How to win",
      "Brainstorm ideas",
      "Remix strategy",
    ];
  if (path.startsWith("/studio/project"))
    return [
      "Suggest a pose",
      "Animation tip",
      "Fight scene help",
      "How to use onion skinning",
    ];
  if (path.startsWith("/studio"))
    return [
      "Start a project",
      "What should I animate?",
      "Template ideas",
      "Studio shortcuts",
    ];
  if (path.startsWith("/profile"))
    return [
      "Grow followers",
      "Best post times",
      "Profile tips",
      "Content ideas",
    ];
  return [
    "Suggest a pose",
    "Animation tip",
    "Fight scene",
    "Studio tools help",
  ];
}

type SpatterTab = "chat" | "generate" | "assets" | "history";

export default function SpatterOverlay() {
  const [isOpen, setIsOpen] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState("");
  const [isTyping, setIsTyping] = useState(false);
  const [activeTab, setActiveTab] = useState<SpatterTab>("chat");
  const chatEndRef = useRef<HTMLDivElement>(null);
  const location = useLocation();
  const chatAction = useAction(api.spatter.chat);

  const contextGreeting = getContextGreeting(location.pathname);
  const contextChips = getContextChips(location.pathname);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, isTyping]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || isTyping) return;

      const userMsg: ChatMessage = {
        id: `user-${Date.now()}`,
        role: "user",
        content: text.trim(),
      };
      setMessages((prev) => [...prev, userMsg]);
      setInput("");
      setIsTyping(true);

      const history = messages.map((m) => ({
        role: m.role as "user" | "assistant",
        content: m.content,
      }));

      try {
        const response = await chatAction({
          message: text.trim(),
          conversationHistory: history,
          context: { page: location.pathname },
        });

        setMessages((prev) => [
          ...prev,
          {
            id: `spatter-${Date.now()}`,
            role: "assistant",
            content: response,
          },
        ]);
      } catch (err) {
        console.error("Spatter overlay error:", err);
        setMessages((prev) => [
          ...prev,
          {
            id: `error-${Date.now()}`,
            role: "assistant",
            content: "Connection hiccup 💀 Try again?",
          },
        ]);
      } finally {
        setIsTyping(false);
      }
    },
    [messages, isTyping, chatAction, location.pathname],
  );

  const TABS: { id: SpatterTab; icon: typeof Sparkles; label: string }[] = [
    { id: "chat", icon: Sparkles, label: "Chat" },
    { id: "generate", icon: Lightbulb, label: "Generate" },
    { id: "assets", icon: Palette, label: "Assets" },
    { id: "history", icon: History, label: "History" },
  ];

  return (
    <>
      {/* Floating Blood Drop Button */}
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        className={`fixed z-50 w-14 h-14 rounded-full flex items-center justify-center transition-all duration-300 shadow-lg ${
          isOpen
            ? "bg-[#2a2a3a] bottom-20 right-4 scale-90"
            : "bg-red-600 hover:bg-red-700 bottom-20 right-4 hover:scale-110 shadow-red-600/40"
        }`}
        aria-label="Open Spatter AI"
      >
        {isOpen ? (
          <X size={22} className="text-white" />
        ) : (
          <BloodDropIcon size={26} className="text-white" />
        )}
      </button>

      {/* Overlay Panel */}
      {isOpen && (
        <>
          {/* Backdrop */}
          <div
            className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm"
            onClick={() => setIsOpen(false)}
          />

          {/* Panel */}
          <div className="fixed z-50 bottom-0 left-0 right-0 max-h-[80vh] bg-[#111118] border-t border-[#2a2a3a] rounded-t-2xl flex flex-col animate-in slide-in-from-bottom duration-300">
            {/* Handle bar */}
            <div className="flex justify-center pt-2 pb-1">
              <div className="w-10 h-1 bg-[#3a3a4a] rounded-full" />
            </div>

            {/* Header */}
            <div className="flex items-center justify-between px-4 pb-2 border-b border-[#2a2a3a]">
              <div className="flex items-center gap-2">
                <BloodDropIcon size={20} className="text-red-500" />
                <span className="text-sm font-bold text-white font-['Special_Elite']">
                  Spatter
                </span>
                <span className="text-[10px] text-green-400 flex items-center gap-1">
                  <span className="w-1.5 h-1.5 bg-green-400 rounded-full inline-block" />
                  online
                </span>
              </div>

              {/* Mode tabs */}
              <div className="flex gap-0.5 bg-[#0a0a0f] rounded-lg p-0.5">
                {TABS.map((tab) => (
                  <button
                    key={tab.id}
                    type="button"
                    onClick={() => setActiveTab(tab.id)}
                    className={`flex items-center gap-1 px-2 py-1 rounded-md text-[10px] font-medium transition-all ${
                      activeTab === tab.id
                        ? "bg-red-600 text-white"
                        : "text-[#72728a] hover:text-white"
                    }`}
                  >
                    <tab.icon size={12} />
                    {tab.label}
                  </button>
                ))}
              </div>
            </div>

            {/* Chat area */}
            <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3 min-h-[200px] max-h-[50vh]">
              {/* Context greeting */}
              <div className="flex gap-2">
                <div className="w-7 h-7 rounded-full bg-red-600/20 flex items-center justify-center shrink-0">
                  <BloodDropIcon size={14} className="text-red-500" />
                </div>
                <div className="bg-[#1a1a24] border border-[#2a2a3a] rounded-xl rounded-tl-sm px-3 py-2 max-w-[85%]">
                  <p className="text-xs text-[#c0c0d0]">{contextGreeting}</p>
                </div>
              </div>

              {/* Messages */}
              {messages.map((msg) => (
                <div
                  key={msg.id}
                  className={`flex gap-2 ${msg.role === "user" ? "justify-end" : ""}`}
                >
                  {msg.role === "assistant" && (
                    <div className="w-7 h-7 rounded-full bg-red-600/20 flex items-center justify-center shrink-0">
                      <BloodDropIcon size={14} className="text-red-500" />
                    </div>
                  )}
                  <div
                    className={`rounded-xl px-3 py-2 max-w-[85%] ${
                      msg.role === "user"
                        ? "bg-red-600 text-white rounded-tr-sm"
                        : "bg-[#1a1a24] border border-[#2a2a3a] text-[#c0c0d0] rounded-tl-sm"
                    }`}
                  >
                    <p className="text-xs whitespace-pre-line">{msg.content}</p>
                  </div>
                </div>
              ))}

              {/* Typing indicator */}
              {isTyping && (
                <div className="flex gap-2">
                  <div className="w-7 h-7 rounded-full bg-red-600/20 flex items-center justify-center shrink-0">
                    <BloodDropIcon size={14} className="text-red-500" />
                  </div>
                  <div className="bg-[#1a1a24] border border-[#2a2a3a] rounded-xl rounded-tl-sm px-4 py-3">
                    <div className="flex gap-1">
                      <div
                        className="w-1.5 h-1.5 bg-[#72728a] rounded-full animate-bounce"
                        style={{ animationDelay: "0ms" }}
                      />
                      <div
                        className="w-1.5 h-1.5 bg-[#72728a] rounded-full animate-bounce"
                        style={{ animationDelay: "150ms" }}
                      />
                      <div
                        className="w-1.5 h-1.5 bg-[#72728a] rounded-full animate-bounce"
                        style={{ animationDelay: "300ms" }}
                      />
                    </div>
                  </div>
                </div>
              )}

              <div ref={chatEndRef} />
            </div>

            {/* Quick chips */}
            <div className="px-4 pb-2 flex gap-1.5 overflow-x-auto no-scrollbar">
              {contextChips.map((chip) => (
                <button
                  key={chip}
                  type="button"
                  onClick={() => sendMessage(chip)}
                  disabled={isTyping}
                  className="shrink-0 px-3 py-1.5 rounded-full bg-[#1a1a24] border border-[#2a2a3a] text-[10px] text-[#9090a8] hover:text-white hover:border-[#3a3a4a] transition-all disabled:opacity-50"
                >
                  {chip}
                </button>
              ))}
            </div>

            {/* Input */}
            <div className="px-4 pb-4 pt-1">
              <div className="flex gap-2 bg-[#0a0a0f] border border-[#2a2a3a] rounded-xl px-3 py-2">
                <input
                  type="text"
                  value={input}
                  onChange={(e) => setInput(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && sendMessage(input)}
                  placeholder="Ask Spatter anything..."
                  className="flex-1 bg-transparent text-xs text-white placeholder:text-[#5a5a6e] outline-none"
                  disabled={isTyping}
                />
                <button
                  type="button"
                  onClick={() => sendMessage(input)}
                  disabled={!input.trim() || isTyping}
                  className="text-red-500 disabled:text-[#3a3a4a] transition-colors"
                >
                  <Send size={16} />
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </>
  );
}
