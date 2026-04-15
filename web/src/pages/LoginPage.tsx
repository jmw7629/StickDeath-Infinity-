import { Link } from "react-router-dom";
import { SignIn } from "@/components/SignIn";
import { Button } from "@/components/ui/button";
import { Skull } from "lucide-react";

export function LoginPage() {
  return (
    <div className="flex-1 flex items-center justify-center p-4 relative min-h-screen bg-[#0a0a0f]">
      {/* Background effects */}
      <div className="absolute inset-0 -z-10 overflow-hidden">
        <div className="absolute top-1/4 left-1/4 w-96 h-96 rounded-full bg-red-600/5 blur-[120px]" />
        <div className="absolute bottom-1/4 right-1/4 w-96 h-96 rounded-full bg-red-600/3 blur-[120px]" />
      </div>

      <div className="w-full max-w-sm space-y-8">
        {/* Branding */}
        <div className="text-center space-y-3">
          <div className="mx-auto w-16 h-16 rounded-2xl bg-red-600/10 border border-red-600/20 flex items-center justify-center mb-4">
            <Skull className="w-9 h-9 text-red-500" />
          </div>
          <h1 className="text-3xl font-bold tracking-tight text-white font-['Special_Elite']">
            STICKDEATH <span className="text-red-500">∞</span>
          </h1>
          <p className="text-[#72728a] text-sm">
            Create. Animate. Annihilate.
          </p>
        </div>

        {/* Sign In form */}
        <div className="bg-[#111118] border border-[#2a2a3a] rounded-xl p-6 shadow-2xl">
          <SignIn />
        </div>

        <p className="text-center text-sm text-[#72728a]">
          New here?{" "}
          <Button variant="link" className="p-0 h-auto font-medium text-red-500 hover:text-red-400" asChild>
            <Link to="/signup">Create an account</Link>
          </Button>
        </p>
      </div>
    </div>
  );
}
