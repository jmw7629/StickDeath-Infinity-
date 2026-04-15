import { useNavigate, useLocation } from "react-router-dom";
import { Flame, Trophy, Pencil, User } from "lucide-react";

const NAV_ITEMS = [
  { path: "/home", icon: Flame, label: "Home" },
  { path: "/challenges", icon: Trophy, label: "Challenges" },
  { path: "/studio", icon: Pencil, label: "Studio", accent: true },
  { path: "/profile", icon: User, label: "Profile" },
];

export default function BottomNav() {
  const navigate = useNavigate();
  const location = useLocation();

  return (
    <nav className="fixed bottom-0 left-0 right-0 z-40 bg-[#111118]/95 backdrop-blur-xl border-t border-[#2a2a3a] safe-area-bottom">
      <div className="flex items-center justify-around h-14 max-w-lg mx-auto">
        {NAV_ITEMS.map((item) => {
          const isActive = location.pathname.startsWith(item.path);
          const Icon = item.icon;

          return (
            <button
              key={item.path}
              type="button"
              onClick={() => navigate(item.path)}
              className={`flex flex-col items-center justify-center gap-0.5 w-16 h-full transition-all ${
                isActive ? "text-white" : "text-[#5a5a6e] hover:text-[#9090a8]"
              }`}
            >
              {item.accent ? (
                <div
                  className={`w-10 h-7 rounded-lg flex items-center justify-center -mt-1 transition-all ${
                    isActive
                      ? "bg-red-600 shadow-lg shadow-red-600/30"
                      : "bg-[#1a1a24] border border-[#2a2a3a]"
                  }`}
                >
                  <Icon size={16} className={isActive ? "text-white" : ""} />
                </div>
              ) : (
                <Icon size={22} strokeWidth={isActive ? 2.5 : 2} />
              )}
              <span className={`text-[10px] ${item.accent && !isActive ? "mt-0" : ""} ${isActive ? "font-semibold" : "font-normal"}`}>
                {item.label}
              </span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}
