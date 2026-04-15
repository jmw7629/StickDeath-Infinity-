import { useNavigate } from "react-router-dom";

/* Skull icon matching the prototype branding */
function SkullIcon({ className = "w-10 h-10" }: { className?: string }) {
  return (
    <svg viewBox="0 0 64 64" className={className} fill="none">
      <circle cx="32" cy="28" r="22" stroke="#dc2626" strokeWidth="3" />
      <circle cx="24" cy="24" r="5" fill="#dc2626" />
      <circle cx="40" cy="24" r="5" fill="#dc2626" />
      <path d="M24 38 L28 34 L32 38 L36 34 L40 38" stroke="#dc2626" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
      <line x1="26" y1="50" x2="26" y2="56" stroke="#dc2626" strokeWidth="2.5" strokeLinecap="round" />
      <line x1="32" y1="50" x2="32" y2="58" stroke="#dc2626" strokeWidth="2.5" strokeLinecap="round" />
      <line x1="38" y1="50" x2="38" y2="56" stroke="#dc2626" strokeWidth="2.5" strokeLinecap="round" />
    </svg>
  );
}

function FeatureCard({ icon, title, desc, onClick }: { icon: React.ReactNode; title: string; desc: string; onClick?: () => void }) {
  return (
    <div
      onClick={onClick}
      className="p-6 md:p-8 rounded-xl bg-[#13131d] border border-[#2a2a3a] shadow-[0_2px_12px_rgba(0,0,0,0.5),inset_0_1px_0_rgba(255,255,255,0.04)] hover:border-red-600/40 hover:shadow-[0_4px_24px_rgba(220,38,38,0.15)] transition-all duration-300 cursor-pointer"
    >
      <div className="w-14 h-14 rounded-lg bg-[#1c1c2c] border border-[#333348] flex items-center justify-center mb-5 shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]">
        {icon}
      </div>
      <h3 className="font-grunge text-lg md:text-xl text-white uppercase tracking-wide mb-3">{title}</h3>
      <p className="text-sm text-[#9090a8] leading-relaxed">{desc}</p>
    </div>
  );
}

export default function LandingPage() {
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-[#0a0a0f] text-white overflow-x-hidden">
      {/* Nav */}
      <nav className="sticky top-0 z-50 bg-[#0e0e16]/95 backdrop-blur-xl border-b border-[#252535]">
        <div className="flex items-center justify-between h-14 px-4 md:px-6 max-w-7xl mx-auto">
          <div className="flex items-center gap-2">
            <SkullIcon className="w-8 h-8" />
            <span className="font-grunge text-lg tracking-wide">
              <span className="text-white">STICK</span>
              <span className="text-red-600">DEATH</span>
              <span className="text-white ml-0.5">∞</span>
            </span>
          </div>
          <button
            onClick={() => navigate("/login")}
            className="w-9 h-9 rounded-full bg-[#1a1a28] border border-[#333348] flex items-center justify-center text-sm font-bold text-white/80 hover:bg-white/10 hover:border-white/30 transition shadow-[0_1px_4px_rgba(0,0,0,0.4)]"
          >
            ME
          </button>
        </div>
      </nav>

      {/* Hero — "Create. Animate. Annihilate." */}
      <section className="relative px-4 md:px-6 pt-16 pb-20 md:pt-24 md:pb-28 flex flex-col items-center text-center">
        {/* Red glow behind hero */}
        <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[700px] h-[500px] bg-gradient-radial from-red-900/15 via-transparent to-transparent pointer-events-none" />

        <h1 className="font-grunge text-[3rem] md:text-[5rem] lg:text-[6rem] leading-[1.05] tracking-wide uppercase drop-shadow-[0_2px_20px_rgba(220,38,38,0.15)]">
          Create.<br />
          Animate.<br />
          <span className="text-red-600 drop-shadow-[0_0_30px_rgba(220,38,38,0.4)]">Annihilate.</span>
        </h1>

        <p className="text-base md:text-lg text-[#9090a8] max-w-lg mt-8 leading-relaxed">
          The ultimate platform for stick figure combat animations. Join a community of creators, share your brutality, and rise to the top of the leaderboard.
        </p>

        <div className="flex flex-col sm:flex-row gap-4 mt-10 w-full sm:w-auto">
          <button
            onClick={() => navigate("/feed")}
            className="font-grunge text-lg uppercase tracking-wider bg-red-600 hover:bg-red-700 text-white px-10 py-4 rounded-lg flex items-center justify-center gap-3 transition-all shadow-[0_4px_20px_rgba(220,38,38,0.35),inset_0_1px_0_rgba(255,255,255,0.1)] hover:shadow-[0_6px_30px_rgba(220,38,38,0.5)] border border-red-500/30"
          >
            Start Watching <span className="text-xl">→</span>
          </button>
          <button
            onClick={() => navigate("/studio")}
            className="font-grunge text-lg uppercase tracking-wider border-2 border-[#404058] hover:border-white/50 text-white px-10 py-4 rounded-lg transition-all hover:bg-white/5 shadow-[0_2px_8px_rgba(0,0,0,0.3)]"
          >
            Enter Studio
          </button>
        </div>
      </section>

      {/* Divider line */}
      <div className="max-w-5xl mx-auto border-t border-[#252535]" />

      {/* Features — Brutal Animations, Active Community, Instant Studio */}
      <section className="px-4 md:px-6 py-16 md:py-20">
        <div className="max-w-5xl mx-auto grid grid-cols-1 md:grid-cols-3 gap-5">
          <FeatureCard
            icon={<SkullIcon className="w-8 h-8" />}
            title="Brutal Animations"
            desc="Upload and watch high-octane stick figure combat. Frame by frame perfection."
            onClick={() => navigate("/studio")}
          />
          <FeatureCard
            icon={
              <svg viewBox="0 0 32 32" className="w-8 h-8" fill="none">
                <circle cx="12" cy="12" r="5" stroke="#dc2626" strokeWidth="2" />
                <circle cx="22" cy="12" r="5" stroke="#dc2626" strokeWidth="2" />
                <path d="M8 24 Q16 18 24 24" stroke="#dc2626" strokeWidth="2" strokeLinecap="round" />
              </svg>
            }
            title="Active Community"
            desc="Comment, rate, and battle other animators for supremacy on the feed."
            onClick={() => navigate("/feed")}
          />
          <FeatureCard
            icon={
              <svg viewBox="0 0 32 32" className="w-8 h-8" fill="none">
                <path d="M6 22 L16 6 L26 22 Z" stroke="#dc2626" strokeWidth="2.5" strokeLinejoin="round" />
                <line x1="16" y1="14" x2="16" y2="18" stroke="#dc2626" strokeWidth="2.5" strokeLinecap="round" />
              </svg>
            }
            title="Instant Studio"
            desc="Create animations directly in your browser with our powerful web-based tools."
            onClick={() => navigate("/studio")}
          />
        </div>
      </section>

      {/* Divider */}
      <div className="max-w-5xl mx-auto border-t border-[#252535]" />

      {/* Featured Creators section */}
      <section className="px-4 md:px-6 py-12">
        <div className="max-w-5xl mx-auto">
          <h2 className="font-grunge text-2xl md:text-3xl uppercase tracking-wide flex items-center gap-3 mb-8">
            <span className="text-yellow-500">☆</span> Featured Creators
          </h2>
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-4">
            {["xDeathStroke", "BoneSnap", "StickLegend"].map((name) => (
              <div key={name} className="p-4 rounded-xl bg-[#13131d] border border-[#2a2a3a] shadow-[0_2px_10px_rgba(0,0,0,0.4)] hover:border-[#404058] transition-all text-center">
                <div className="w-16 h-16 rounded-full bg-[#1c1c2c] border-2 border-[#333348] mx-auto mb-3 flex items-center justify-center text-xl font-bold text-red-500 shadow-[inset_0_2px_6px_rgba(0,0,0,0.4)]">
                  {name[0]}
                </div>
                <div className="font-grunge text-sm text-white tracking-wide">{name}</div>
                <span className="inline-block text-[10px] font-semibold text-yellow-400 border border-yellow-500/50 bg-yellow-500/10 rounded px-1.5 py-0.5 mt-2 uppercase">Featured</span>
                <div className="flex justify-center gap-3 mt-2 text-xs text-[#9090a8]">
                  <span>👥 0</span>
                  <span>🎬 0</span>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Divider */}
      <div className="max-w-5xl mx-auto border-t border-[#252535]" />

      {/* Latest Uploads / Feed Preview */}
      <section className="px-4 md:px-6 py-12">
        <div className="max-w-5xl mx-auto">
          {/* Sort tabs */}
          <div className="flex flex-wrap gap-3 mb-6">
            <button className="font-grunge text-sm uppercase tracking-wider bg-red-600/15 border border-red-500/40 text-red-400 rounded-full px-4 py-1.5 flex items-center gap-2 shadow-[0_0_8px_rgba(220,38,38,0.15)]">
              🕐 New
            </button>
            <button className="font-grunge text-sm uppercase tracking-wider text-[#9090a8] border border-[#2a2a3a] hover:border-[#404058] hover:text-white rounded-full px-4 py-1.5 flex items-center gap-2 transition">
              🔥 Trending
            </button>
            <button className="font-grunge text-sm uppercase tracking-wider text-[#9090a8] border border-[#2a2a3a] hover:border-[#404058] hover:text-white rounded-full px-4 py-1.5 flex items-center gap-2 transition">
              👥 Following
            </button>
          </div>

          <button
            onClick={() => navigate("/signup")}
            className="font-grunge text-sm uppercase tracking-wider bg-red-600 hover:bg-red-700 text-white rounded-lg px-5 py-2.5 flex items-center gap-2 mb-8 transition shadow-[0_2px_10px_rgba(220,38,38,0.3)] border border-red-500/30"
          >
            + Create Post
          </button>

          <h2 className="font-grunge text-2xl md:text-3xl uppercase tracking-wide mb-2">Latest Uploads</h2>
          <p className="text-sm text-[#9090a8] mb-6 italic">Fresh from the studio.</p>

          {/* Empty state preview cards */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {[1, 2].map((i) => (
              <div key={i} className="rounded-xl bg-[#13131d] border border-[#2a2a3a] shadow-[0_2px_12px_rgba(0,0,0,0.5)] overflow-hidden hover:border-[#404058] transition-all">
                <div className="aspect-video bg-[#0c0c14] border-b border-[#2a2a3a] flex items-center justify-center">
                  <span className="text-[#606078] text-sm font-medium">No animations yet</span>
                </div>
                <div className="p-4">
                  <div className="font-grunge text-base text-white tracking-wide">Coming Soon</div>
                  <div className="text-xs text-[#9090a8] mt-1">Be the first to create something legendary.</div>
                  <div className="flex gap-2 mt-3">
                    <span className="text-[10px] font-semibold text-[#9090a8] border border-[#333348] bg-[#1a1a28] rounded px-2 py-0.5">#loop</span>
                    <span className="text-[10px] font-semibold text-[#9090a8] border border-[#333348] bg-[#1a1a28] rounded px-2 py-0.5">#combat</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Divider */}
      <div className="max-w-5xl mx-auto border-t border-[#252535]" />

      {/* CTA */}
      <section className="px-4 md:px-6 py-20 text-center">
        <div className="max-w-2xl mx-auto p-10 rounded-2xl bg-[#13131d] border border-[#2a2a3a] shadow-[0_4px_24px_rgba(0,0,0,0.5)]">
          <h2 className="font-grunge text-3xl md:text-4xl uppercase tracking-wide mb-4">
            Ready to <span className="text-red-600 drop-shadow-[0_0_20px_rgba(220,38,38,0.4)]">Annihilate?</span>
          </h2>
          <p className="text-[#9090a8] mb-8 max-w-md mx-auto">
            Join the new generation of stick figure combat animators. It&apos;s free.
          </p>
          <button
            onClick={() => navigate("/signup")}
            className="font-grunge text-lg uppercase tracking-wider bg-red-600 hover:bg-red-700 text-white px-10 py-4 rounded-lg transition-all shadow-[0_4px_20px_rgba(220,38,38,0.35),inset_0_1px_0_rgba(255,255,255,0.1)] hover:shadow-[0_6px_30px_rgba(220,38,38,0.5)] border border-red-500/30"
          >
            Start Creating — Free
          </button>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-[#252535] py-8 px-4 md:px-6 bg-[#0c0c14]">
        <div className="max-w-5xl mx-auto flex flex-col md:flex-row justify-between items-center gap-4">
          <div className="flex items-center gap-2">
            <SkullIcon className="w-6 h-6" />
            <span className="font-grunge text-sm tracking-wide">
              <span className="text-white">STICK</span>
              <span className="text-red-600">DEATH</span>
              <span className="text-white ml-0.5">∞</span>
            </span>
          </div>
          <div className="text-xs text-[#606078]">
            © {new Date().getFullYear()} StickDeath Infinity. All rights reserved.
          </div>
        </div>
      </footer>
    </div>
  );
}
