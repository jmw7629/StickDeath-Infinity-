import { useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";

export function Header() {
  const navigate = useNavigate();

  return (
    <header className="fixed top-0 left-0 right-0 z-50 bg-[#0a0a0f]/80 backdrop-blur-xl border-b border-white/5">
      <div className="container mx-auto flex items-center justify-between h-14 px-4">
        <div
          className="flex items-center gap-1.5 cursor-pointer"
          onClick={() => navigate("/")}
        >
          <span className="text-red-600 text-lg font-black tracking-tighter">
            STICK
          </span>
          <span className="text-white text-lg font-black tracking-tighter">
            DEATH
          </span>
          <span className="text-[9px] font-bold text-red-600/60 uppercase tracking-widest ml-0.5">
            ∞
          </span>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="ghost"
            size="sm"
            className="text-white/60 hover:text-white text-xs"
            onClick={() => navigate("/login")}
          >
            Log in
          </Button>
          <Button
            size="sm"
            className="bg-red-600 hover:bg-red-700 text-white font-bold text-xs"
            onClick={() => navigate("/signup")}
          >
            Sign Up
          </Button>
        </div>
      </div>
    </header>
  );
}
