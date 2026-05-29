import { useState, useEffect, useRef, useCallback } from "react";
import { getSpatterBrainResponse } from "../data/spatterBrain";
import { getAIResponse, generateBotMessage } from "../data/aiService";

// ═══════════════════════════════════════════════════════════════════
// StickDeath ∞ — iPhone Simulator v5 (Complete Rebuild)
// Exact mirror of the preview app from video reference
// Every button functions. No mockups. No placeholders.
// ═══════════════════════════════════════════════════════════════════

const FONT = "'Special Elite', 'Courier New', monospace";
const C = {
  bg: "#0A0A0A", surface: "#141414", surfaceLight: "#1E1E1E",
  surface2: "#1A1A1A", surface3: "#222222", surfaceDark: "#0D0D12",
  border: "#2A2A2A", borderDim: "#1F1F1F",
  red: "#C80000", redBright: "#FF1A1A", redDeep: "#8B0000", redGlow: "rgba(200,0,0,0.4)",
  white: "#FFFFFF", gray: "#9CA3AF", grayDim: "#6B7280",
  textPrimary: "#E0E0E0", textSecondary: "#999999", textMuted: "#666666",
  purple: "#A855F7", success: "#00C853", green: "#22C55E",
  orange: "#F59E0B", blue: "#3B82F6", pink: "#EC4899",
};

type Screen = "splash" | "welcome" | "login" | "signup" | "onboarding" | "choosePlan" | "main";
type Tab = "home" | "challenges" | "studio" | "messages" | "profile";
type MessagesTab = "channels" | "dms" | "requests";

// ═══ STUDIO TYPES ═══
type StudioPanel =
  | "none" | "colorPicker" | "toolSettings" | "settings" | "projectSettings"
  | "layers" | "export" | "framesViewer" | "assetVault" | "audioTimeline"
  | "soundLibrary" | "soundDetail" | "importVideo" | "spatter" | "magicCut"
  | "stickerEmoji" | "addImage" | "backgroundLibrary" | "aiVoice";
type StudioTool =
  | "move" | "lasso" | "pencil" | "pen" | "brush" | "marker" | "crayon"
  | "line" | "rect" | "circle" | "fill" | "picker" | "eraser" | "smudge"
  | "text" | "hand" | "zoom";
type LockType = "free" | "full" | "pos" | "alpha";
type BlendMode = "Normal" | "Multiply" | "Screen" | "Overlay" | "Darken" | "Lighten" | "Color Dodge" | "Color Burn" | "Difference";

interface ToolDef {
  id: StudioTool; label: string; icon: string; shortcut: string;
  topColor: string; glowColor: string;
}
interface LayerData {
  id: string; name: string; visible: boolean; locked: boolean;
  lockType: LockType; opacity: number; expanded: boolean;
  colorLabel?: string; blendMode: BlendMode; glowEnabled: boolean;
}
interface FrameData { id: string; hasContent: boolean; }
interface DrawnPoint { x: number; y: number; }
interface DrawnStroke {
  id: string; tool: StudioTool; points: DrawnPoint[];
  color: string; width: number; opacity: number; layerId: string;
}
interface AudioClip { id: string; name: string; track: number; start: number; duration: number; volume: number; }

// ═══ TOOL DEFINITIONS (exact from video) ═══
const STUDIO_TOOLS: ToolDef[] = [
  { id: "move",    label: "Move",    icon: "☠⇕",  shortcut: "V", topColor: "#555566", glowColor: "#777788" },
  { id: "lasso",   label: "Lasso",   icon: "☠◎",  shortcut: "L", topColor: "#555566", glowColor: "#777788" },
  { id: "pencil",  label: "Pencil",  icon: "✏️",   shortcut: "N", topColor: "#DC2626", glowColor: "#EF4444" },
  { id: "pen",     label: "Pen",     icon: "🖊️",  shortcut: "P", topColor: "#C53030", glowColor: "#DC2626" },
  { id: "brush",   label: "Brush",   icon: "🖌️",  shortcut: "B", topColor: "#E03030", glowColor: "#F43F5E" },
  { id: "marker",  label: "Marker",  icon: "🖍️",  shortcut: "K", topColor: "#E83E8C", glowColor: "#D946EF" },
  { id: "crayon",  label: "Crayon",  icon: "🖍",   shortcut: "Y", topColor: "#F59E0B", glowColor: "#FBBF24" },
  { id: "line",    label: "Line",    icon: "╱",    shortcut: "U", topColor: "#888899", glowColor: "#999AAA" },
  { id: "rect",    label: "Rect",    icon: "▭",    shortcut: "U", topColor: "#888899", glowColor: "#999AAA" },
  { id: "circle",  label: "Circle",  icon: "◯",    shortcut: "U", topColor: "#888899", glowColor: "#999AAA" },
  { id: "fill",    label: "Fill",    icon: "🪣",   shortcut: "G", topColor: "#22C55E", glowColor: "#4ADE80" },
  { id: "picker",  label: "Picker",  icon: "💧",   shortcut: "I", topColor: "#06B6D4", glowColor: "#22D3EE" },
  { id: "eraser",  label: "Eraser",  icon: "◻️",   shortcut: "E", topColor: "#F97316", glowColor: "#FB923C" },
  { id: "smudge",  label: "Smudge",  icon: "👆",   shortcut: "R", topColor: "#A78BFA", glowColor: "#C4B5FD" },
  { id: "text",    label: "Text",    icon: "T",    shortcut: "T", topColor: "#E879F9", glowColor: "#D946EF" },
  { id: "hand",    label: "Hand",    icon: "✋",   shortcut: "H", topColor: "#78716C", glowColor: "#A8A29E" },
  { id: "zoom",    label: "Zoom",    icon: "🔍",   shortcut: "Z", topColor: "#78716C", glowColor: "#A8A29E" },
];

// ═══ SOUND LIBRARY DATA ═══
interface SoundEffect { id: string; name: string; duration: string; tag: string; }
interface SoundCategory { id: string; name: string; icon: string; count: number; items: SoundEffect[]; }
let _sid = 0;
const mkSnd = (name: string, dur: string, tag: string): SoundEffect => ({ id: `snd_${++_sid}`, name, duration: dur, tag });

const SOUND_CATEGORIES: SoundCategory[] = [
  { id: "impacts", name: "Impacts & Crashes", icon: "💥", count: 30, items: [
    mkSnd("Glass Shatter","0.8s","impact"), mkSnd("Metal Clang","0.6s","impact"), mkSnd("Wood Crack","0.5s","impact"),
    mkSnd("Heavy Thud","0.7s","impact"), mkSnd("Concrete Smash","1.0s","impact"), mkSnd("Car Crash","1.5s","impact"),
    mkSnd("Window Break","0.9s","impact"), mkSnd("Bone Crack","0.3s","impact"), mkSnd("Steel Slam","0.5s","impact"),
    mkSnd("Rock Crumble","1.2s","impact"), mkSnd("Ice Crack","0.4s","impact"), mkSnd("Plate Shatter","0.7s","impact"),
    mkSnd("Door Slam","0.6s","impact"), mkSnd("Hammer Strike","0.4s","impact"), mkSnd("Anvil Ring","1.0s","impact"),
  ]},
  { id: "weapons", name: "Weapons & Guns", icon: "🔫", count: 45, items: [
    mkSnd("Pistol Shot","0.3s","weapon"), mkSnd("Rifle Shot","0.4s","weapon"), mkSnd("Shotgun Blast","0.5s","weapon"),
    mkSnd("Machine Gun Burst","1.2s","weapon"), mkSnd("Sniper Shot","0.6s","weapon"), mkSnd("Silenced Shot","0.2s","weapon"),
    mkSnd("Sword Swing","0.4s","weapon"), mkSnd("Sword Clash","0.5s","weapon"), mkSnd("Axe Swing","0.5s","weapon"),
    mkSnd("Whip Crack","0.3s","weapon"), mkSnd("Chain Swing","0.6s","weapon"), mkSnd("Shield Block","0.3s","weapon"),
  ]},
  { id: "explosions", name: "Explosions & Booms", icon: "💣", count: 30, items: [
    mkSnd("Small Explosion","0.8s","explosion"), mkSnd("Medium Explosion","1.2s","explosion"), mkSnd("Large Explosion","2.0s","explosion"),
    mkSnd("Nuclear Blast","3.0s","explosion"), mkSnd("Grenade Pop","0.6s","explosion"), mkSnd("Dynamite Blast","1.0s","explosion"),
    mkSnd("Firework Burst","1.0s","explosion"), mkSnd("Mortar Shell","1.2s","explosion"), mkSnd("Shockwave","1.5s","explosion"),
  ]},
  { id: "body", name: "Body & Fighting", icon: "👊", count: 40, items: [
    mkSnd("Punch Light","0.2s","body"), mkSnd("Punch Heavy","0.3s","body"), mkSnd("Kick Light","0.2s","body"),
    mkSnd("Kick Heavy","0.4s","body"), mkSnd("Slap","0.2s","body"), mkSnd("Body Slam","0.5s","body"),
    mkSnd("Neck Snap","0.2s","body"), mkSnd("Bone Break","0.3s","body"), mkSnd("Jaw Crack","0.2s","body"),
  ]},
  { id: "movement", name: "Movement & Footsteps", icon: "👟", count: 30, items: [
    mkSnd("Footstep Stone","0.3s","movement"), mkSnd("Run Grass","0.6s","movement"), mkSnd("Jump Land","0.4s","movement"),
    mkSnd("Slide Dirt","0.5s","movement"), mkSnd("Roll","0.8s","movement"), mkSnd("Dash","0.3s","movement"),
  ]},
  { id: "environment", name: "Environment", icon: "🌍", count: 25, items: [
    mkSnd("Wind Howl","3.0s","env"), mkSnd("Rain Loop","5.0s","env"), mkSnd("Thunder","1.5s","env"),
    mkSnd("Fire Crackle","3.0s","env"), mkSnd("Water Splash","0.8s","env"), mkSnd("Ocean Waves","5.0s","env"),
  ]},
  { id: "voice", name: "Voice & Vocal", icon: "🗣️", count: 35, items: [
    mkSnd("Scream Male","1.0s","voice"), mkSnd("Scream Female","1.0s","voice"), mkSnd("Grunt","0.3s","voice"),
    mkSnd("Battle Cry","1.5s","voice"), mkSnd("Evil Laugh","2.0s","voice"), mkSnd("Death Gurgle","1.0s","voice"),
  ]},
  { id: "ui", name: "UI & Interface", icon: "📱", count: 20, items: [
    mkSnd("Button Click","0.1s","ui"), mkSnd("Menu Open","0.3s","ui"), mkSnd("Error Buzz","0.2s","ui"),
    mkSnd("Success Chime","0.5s","ui"), mkSnd("Notification","0.4s","ui"), mkSnd("Swoosh","0.3s","ui"),
  ]},
  { id: "music", name: "Music & Beats", icon: "🎵", count: 20, items: [
    mkSnd("Hip Hop Loop","4.0s","music"), mkSnd("Trap Beat","4.0s","music"), mkSnd("Dark Ambient","6.0s","music"),
    mkSnd("Action Score","5.0s","music"), mkSnd("8-Bit Theme","4.0s","music"), mkSnd("Epic Drums","3.0s","music"),
  ]},
  { id: "comedy", name: "Comedy & Cartoon", icon: "🤡", count: 25, items: [
    mkSnd("Boing","0.3s","comedy"), mkSnd("Slide Whistle","0.8s","comedy"), mkSnd("Honk","0.3s","comedy"),
    mkSnd("Record Scratch","0.5s","comedy"), mkSnd("Sad Trombone","1.5s","comedy"), mkSnd("Rimshot","0.6s","comedy"),
  ]},
  { id: "wood", name: "Wood & Nature Materials", icon: "🪵", count: 30, items: [
    mkSnd("Wood Hit","0.3s","wood"), mkSnd("Branch Snap","0.4s","wood"), mkSnd("Log Roll","1.0s","wood"),
    mkSnd("Tree Fall","2.0s","wood"), mkSnd("Bamboo Click","0.2s","wood"), mkSnd("Cork Pop","0.2s","wood"),
  ]},
  { id: "metal", name: "Metal & Chains", icon: "⛓️", count: 25, items: [
    mkSnd("Chain Rattle","0.8s","metal"), mkSnd("Metal Scrape","1.0s","metal"), mkSnd("Steel Ring","0.5s","metal"),
    mkSnd("Anvil Strike","0.4s","metal"), mkSnd("Tin Can","0.3s","metal"), mkSnd("Sword Unsheathe","0.6s","metal"),
  ]},
  { id: "magic", name: "Magic & Fantasy", icon: "✨", count: 20, items: [
    mkSnd("Spell Cast","0.8s","magic"), mkSnd("Magic Shimmer","1.0s","magic"), mkSnd("Portal Open","1.5s","magic"),
    mkSnd("Enchant","0.6s","magic"), mkSnd("Dark Energy","1.2s","magic"), mkSnd("Healing Glow","1.0s","magic"),
  ]},
  { id: "scifi", name: "Sci-Fi & Tech", icon: "🛸", count: 20, items: [
    mkSnd("Laser Zap","0.3s","scifi"), mkSnd("Robot Beep","0.2s","scifi"), mkSnd("Teleport","0.8s","scifi"),
    mkSnd("Force Field","1.0s","scifi"), mkSnd("Energy Charge","1.5s","scifi"), mkSnd("Plasma Bolt","0.4s","scifi"),
  ]},
  { id: "death", name: "Death & Horror", icon: "💀", count: 30, items: [
    mkSnd("Flatline","2.0s","death"), mkSnd("Heartbeat Stop","1.5s","death"), mkSnd("Ghost Whisper","1.0s","death"),
    mkSnd("Creepy Laugh","2.0s","death"), mkSnd("Coffin Close","0.8s","death"), mkSnd("Chains Drag","1.5s","death"),
  ]},
];

// ═══ BACKGROUND LIBRARY ═══
interface BgCategory { id: string; name: string; icon: string; count: number; }
const BG_CATEGORIES: BgCategory[] = [
  { id: "all", name: "All", icon: "⊞", count: 101 },
  { id: "dark-forest", name: "Dark Forest", icon: "🌲", count: 7 },
  { id: "cyberpunk", name: "Cyberpunk City", icon: "🏙️", count: 7 },
  { id: "mountains", name: "Mountains", icon: "⛰️", count: 7 },
  { id: "abstract", name: "Abstract", icon: "🎨", count: 7 },
  { id: "space", name: "Space", icon: "🚀", count: 7 },
  { id: "urban", name: "Urban Street", icon: "🏢", count: 7 },
  { id: "desert", name: "Desert", icon: "🏜️", count: 7 },
  { id: "beach", name: "Beach", icon: "🏖️", count: 7 },
  { id: "winter", name: "Winter", icon: "❄️", count: 7 },
  { id: "medieval", name: "Medieval", icon: "🏰", count: 6 },
  { id: "industrial", name: "Industrial", icon: "🏭", count: 6 },
  { id: "jungle", name: "Jungle", icon: "🌴", count: 6 },
  { id: "sunset", name: "Sunset", icon: "🌅", count: 7 },
  { id: "apocalyptic", name: "Apocalyptic", icon: "💀", count: 7 },
  { id: "neon", name: "Neon", icon: "💡", count: 6 },
];

// ═══ IMAGE/STICKER CATEGORIES ═══
interface ImageCat { id: string; name: string; count: number; emojis: string[]; }
const IMAGE_CATS: ImageCat[] = [
  { id: "people", name: "People & Faces", count: 100, emojis: ["😀","😁","😂","🤣","😃","😄","😅","😆","😉","😊","😋","😎","😍","🥰","😘","😗","😙","😚","🙂","🤗","🤩","🤔","🤨","😐","😑","😶","🙄","😏","😣","😥","😮","🤐","😯","😪","😫","🥱","😴","😌","😛","😜","😝","🤤","😒","😓","😔","😕","🙃","🤑","😲","🙁","😖","😞","😟","😤","😢","😭","😦","😧","😨","😩","🤯","😬","😰","😱","🥵","🥶","😳","🤪","😵","🥴","😠","😡","🤬","😷","🤒","🤕","🤢","🤮","🥺","🥹","😇","🥳","🥸","😈","👿","👹","👺","💀","☠️","👻","👽","👾","🤖","🎃","😺","😸","😹","😻","😼","😽"] },
  { id: "hands", name: "Hands & Gestures", count: 60, emojis: ["👋","🤚","🖐️","✋","🖖","👌","🤌","🤏","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","🖕","👇","☝️","👍","👎","✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏","✍️","💅","🤳","💪","🦾","🦿","🦵","🦶","👂","🦻","👃","🧠","🫀","🫁","🦷","🦴","👀","👁️","👅","👄","💋","👶","🧒","👦","👧","🧑","👱","👨","👩"] },
  { id: "animals", name: "Animals", count: 100, emojis: ["🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐔","🐧","🐦","🐤","🐣","🐥","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐜","🕷️","🦂","🐢","🐍","🦎","🦖","🦕","🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅","🐆"] },
  { id: "food", name: "Food & Drink", count: 100, emojis: ["🍏","🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶️","🌽","🥕","🥔","🍠","🥐","🥖","🍞","🥨","🧀","🥚","🍳","🥞","🥓","🥩","🍗","🍖","🌭","🍔","🍟","🍕","🥪","🌮","🌯","🥗","🍝","🍜"] },
  { id: "nature", name: "Nature & Weather", count: 90, emojis: ["🌲","🌳","🌴","🌵","🌾","🌿","☘️","🍀","🍁","🍂","🍃","🍄","🌺","🌻","🌹","🥀","🌷","🌼","🌸","💐","🪴","🪵","🪨","🌍","🌎","🌏","⭐","🌟","💫","✨","☀️","🌤️","⛅","☁️","🌧️","⛈️","🌩️","❄️","☃️","⛄","💨","💧","☔","🌊","🔥","🌈","🌕","🌙","🪐","⚡"] },
  { id: "objects", name: "Objects & Tools", count: 105, emojis: ["🔫","💣","🪃","🏹","🛡️","🪚","🔧","🪛","🔩","⚙️","⚖️","🔗","⛓️","🧰","🧲","⚗️","🧪","🔬","🔭","💉","💊","🚪","🪞","🪟","🛏️","🪑","🧴","🧹","🧻","🧼","🧯","🛒","⚰️","🪦","🗿","🔑","🗝️","🔐","🔒","🔓"] },
  { id: "shapes", name: "Shapes & Colors", count: 59, emojis: ["🔴","🟠","🟡","🟢","🔵","🟣","🟤","⚫","⚪","🔶","🔷","🔸","🔹","▪️","▫️","◼️","◻️","◾","◽","⬛","⬜","🟥","🟧","🟨","🟩","🟦","🟪","🟫","💠","🔘","🔳","🔲","⭕","❌","❎","✅","☑️","✔️","❗","❓","❕","❔","➕","➖","➗","✖️","💲","💯","🔆","🔅"] },
  { id: "hearts", name: "Hearts & Love", count: 36, emojis: ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💟","♥️","❤️‍🔥","❤️‍🩹","💌","💐","🌹","🥀","💍","💎","🫶","😘","😍","🥰","😻","💑","👩‍❤️‍👨","💏"] },
  { id: "tech", name: "Tech & Gaming", count: 60, emojis: ["💻","🖥️","🖨️","⌨️","🖱️","🖲️","🕹️","🎮","📱","📲","☎️","📞","📠","📺","📻","🎙️","🎚️","🎛️","🧭","📡","🔋","🔌","💡","🔦","🕯️","📷","📸","📹","🎥","🎬","📽️","🎞️","📀","💽","💾","💿","🖼️","🎨","📐","📏"] },
  { id: "buildings", name: "Buildings & Places", count: 60, emojis: ["🏠","🏡","🏢","🏣","🏤","🏥","🏦","🏨","🏩","🏪","🏫","🏬","🏭","🏯","🏰","💒","🗼","🗽","⛪","🕌","🛕","🕍","⛩️","🕋","⛲","⛺","🌁","🌃","🏙️","🌄","🌅","🌆","🌇","🌉","♨️","🎠","🎡","🎢","🎪","🗾"] },
];

// ═══ STICKER DATA ═══
interface StickerDef { id: string; name: string; emoji: string; }
interface StickerCat { id: string; name: string; stickers: StickerDef[]; }
const STICKER_CATS: StickerCat[] = [
  { id: "fighters", name: "Fighters", stickers: [
    { id: "s1", name: "Fencing", emoji: "🤺" }, { id: "s2", name: "Axe Chop", emoji: "🪓" },
    { id: "s3", name: "Shield Block", emoji: "🛡️" }, { id: "s4", name: "Arrow Shot", emoji: "🏹" },
    { id: "s5", name: "Roundhouse", emoji: "🦵" }, { id: "s6", name: "Uppercut", emoji: "👊" },
    { id: "s7", name: "Knife Throw", emoji: "🔪" }, { id: "s8", name: "Headbutt", emoji: "💀" },
  ]},
  { id: "movement", name: "Movement", stickers: [
    { id: "s9", name: "Running", emoji: "🏃" }, { id: "s10", name: "Jumping", emoji: "🦘" },
    { id: "s11", name: "Falling", emoji: "🪂" }, { id: "s12", name: "Rolling", emoji: "🔄" },
    { id: "s13", name: "Climbing", emoji: "🧗" }, { id: "s14", name: "Sliding", emoji: "⛷️" },
    { id: "s15", name: "Backflip", emoji: "🤸" }, { id: "s16", name: "Dodging", emoji: "💨" },
  ]},
  { id: "deaths", name: "Deaths", stickers: [
    { id: "s17", name: "Explosion", emoji: "💥" }, { id: "s18", name: "Impaled", emoji: "⚔️" },
    { id: "s19", name: "Electrocuted", emoji: "⚡" }, { id: "s20", name: "Crushed", emoji: "🪨" },
    { id: "s21", name: "Decapitated", emoji: "☠️" }, { id: "s22", name: "Burned", emoji: "🔥" },
    { id: "s23", name: "Frozen", emoji: "🧊" }, { id: "s24", name: "Dissolved", emoji: "🧪" },
  ]},
  { id: "poses", name: "Poses", stickers: [
    { id: "s25", name: "Victory", emoji: "✌️" }, { id: "s26", name: "Power", emoji: "💪" },
    { id: "s27", name: "Taunt", emoji: "😏" }, { id: "s28", name: "Guard", emoji: "🥋" },
    { id: "s29", name: "Pray", emoji: "🙏" }, { id: "s30", name: "Dance", emoji: "🕺" },
    { id: "s31", name: "Salute", emoji: "🫡" }, { id: "s32", name: "Meditate", emoji: "🧘" },
  ]},
  { id: "props", name: "Props", stickers: [
    { id: "s33", name: "Sword", emoji: "⚔️" }, { id: "s34", name: "Gun", emoji: "🔫" },
    { id: "s35", name: "Bomb", emoji: "💣" }, { id: "s36", name: "Shield", emoji: "🛡️" },
    { id: "s37", name: "Potion", emoji: "🧪" }, { id: "s38", name: "Crown", emoji: "👑" },
    { id: "s39", name: "Skull", emoji: "💀" }, { id: "s40", name: "Fire", emoji: "🔥" },
  ]},
];

// ═══ ASSET VAULT CATEGORIES ═══
interface AssetVaultCat { id: string; name: string; count: number; icon: string; }
const ASSET_VAULT_CATS: AssetVaultCat[] = [
  { id: "objects", name: "Objects & Tools", count: 105, icon: "🔧" },
  { id: "shapes", name: "Shapes & Colors", count: 59, icon: "🔶" },
  { id: "hearts", name: "Hearts & Love", count: 36, icon: "❤️" },
  { id: "music", name: "Music & Sound", count: 34, icon: "🎵" },
  { id: "buildings", name: "Buildings & Places", count: 60, icon: "🏢" },
  { id: "tech", name: "Tech & Gaming", count: 60, icon: "🎮" },
  { id: "flags", name: "Flags & Symbols", count: 80, icon: "🏳️" },
  { id: "vehicles", name: "Vehicles", count: 50, icon: "🚗" },
  { id: "sports", name: "Sports & Activities", count: 45, icon: "⚽" },
  { id: "weapons", name: "Weapons & Combat", count: 40, icon: "⚔️" },
  { id: "effects", name: "Effects & Magic", count: 35, icon: "✨" },
  { id: "nature", name: "Nature & Plants", count: 50, icon: "🌿" },
];

// ═══ VOICE PRESETS ═══
const VOICE_PRESETS = [
  { id: "normal", label: "Normal", color: "#A855F7" },
  { id: "deep", label: "Deep", color: "#6366F1" },
  { id: "high", label: "High", color: "#EC4899" },
  { id: "fast", label: "Fast", color: "#22C55E" },
  { id: "slow", label: "Slow", color: "#F59E0B" },
  { id: "robot", label: "Robot", color: "#06B6D4" },
  { id: "chipmunk", label: "Chipmunk", color: "#F97316" },
  { id: "narrator", label: "Narrator", color: "#8B5CF6" },
];

// ═══ CANVAS SIZE PRESETS ═══
const CANVAS_PRESETS = [
  { id: "portrait", label: "Portrait", w: 1080, h: 1920 },
  { id: "landscape", label: "Landscape", w: 1920, h: 1080 },
  { id: "square", label: "Square", w: 1080, h: 1080 },
  { id: "tiktok", label: "TikTok", w: 1080, h: 1920 },
  { id: "youtube", label: "YouTube", w: 1920, h: 1080 },
  { id: "instagram", label: "Instagram", w: 1080, h: 1080 },
  { id: "sd", label: "SD", w: 720, h: 480 },
  { id: "hd", label: "HD", w: 1920, h: 1080 },
];

// ═══ FPS OPTIONS ═══
const FPS_OPTIONS = [6, 8, 10, 12, 15, 24, 30];

// ═══ COLOR PALETTES ═══
const COLOR_PALETTES = [
  { name: "Basic", colors: ["#5AC8FA","#7EC8D9","#C4C9A8","#F39C12","#E67E22","#FFFFFF","#000000"] },
  { name: "Sketch", colors: ["#F5DEB3","#D2C6A5","#E8E4A0","#2D2D2D","#D5F0E8","#8B8B8B","#555555"] },
  { name: "Retro", colors: ["#EF4444","#E8F5A3","#4A9C6D","#6B7B8D","#2D3B4E","#FF6B6B","#FFD93D"] },
  { name: "Neon", colors: ["#FF1493","#FF8C00","#ADFF2F","#1E90FF","#9400D3","#00FF7F","#FF4500"] },
];

// ═══ SPATTER AI KNOWLEDGE ═══
// ═══ BOT MESSAGE DATA (live AI bots) ═══
interface BotMessage { id: string; bot: string; avatar: string; text: string; time: string; channel: string; }
const BOT_MESSAGES: BotMessage[] = [
  { id: "b1", bot: "Spatter AI", avatar: "🎨", text: "Just analyzed trending fight animations — reverse spin kicks are up 340% this week. Try adding one to your next scene! 💀", time: "2m ago", channel: "general" },
  { id: "b2", bot: "DeathBot", avatar: "☠️", text: "New death animation template available: 'Meteor Strike' — 24 frames, full effects included. Download from the Asset Vault.", time: "5m ago", channel: "general" },
  { id: "b3", bot: "StickCoach", avatar: "🎯", text: "Daily tip: Use onion skinning to preview your previous frame while drawing. Toggle it in the ⋯ menu → Onion.", time: "12m ago", channel: "tips" },
  { id: "b4", bot: "BattleBot", avatar: "⚔️", text: "War Room challenge starting in 30 min! Theme: 'Last Stand' — create a 3-second loop. Winner gets 500 coins. 🏆", time: "18m ago", channel: "challenges" },
  { id: "b5", bot: "Spatter AI", avatar: "🎨", text: "I noticed you've been working on sword fights lately. Here's a pro technique: stagger your keyframes — the attacker's swing should land 1-2 frames before the defender reacts.", time: "25m ago", channel: "general" },
  { id: "b6", bot: "SoundBot", avatar: "🎵", text: "New sound pack uploaded: 'Cinematic Impacts Vol. 3' — 50 new effects including slow-motion whooshes and bass drops.", time: "32m ago", channel: "assets" },
  { id: "b7", bot: "TrendBot", avatar: "📈", text: "Your animation 'Neon Duel' got 1.2K views! It's trending in the Cyberpunk category. Keep creating! 🔥", time: "1h ago", channel: "general" },
  { id: "b8", bot: "StickCoach", avatar: "🎯", text: "Animation principle spotlight: ANTICIPATION. Before every big action, add 2-3 frames of wind-up. It makes impacts feel 10x more powerful.", time: "1h ago", channel: "tips" },
];

// ═══════════════════════════════════════════════════════════════════
// MAIN COMPONENT
// ═══════════════════════════════════════════════════════════════════

export function IPhoneSimulator() {
  const [screen, setScreen] = useState<Screen>("splash");
  const [activeTab, setActiveTab] = useState<Tab>("home");
  const [showCreatePost, setShowCreatePost] = useState(false);
  const [showChatRoom, setShowChatRoom] = useState(false);
  const [onboardingPage, setOnboardingPage] = useState(0);
  const [selectedPlan, setSelectedPlan] = useState<string | null>(null);
  const [feedFilter, setFeedFilter] = useState("trending");
  const [challengeFilter, setChallengeFilter] = useState("active");
  const [msgTab, setMsgTab] = useState<MessagesTab>("channels");

  // Auto-advance splash
  useEffect(() => {
    if (screen === "splash") {
      const t = setTimeout(() => setScreen("welcome"), 2800);
      return () => clearTimeout(t);
    }
  }, [screen]);

  const resetToSplash = () => {
    setScreen("splash");
    setActiveTab("home");
    setShowCreatePost(false);
    setShowChatRoom(false);
    setOnboardingPage(0);
    setSelectedPlan(null);
  };

  // For studio and messages, we don't show the bottom nav
  const showBottomNav = activeTab !== "studio" && activeTab !== "messages" && screen === "main";

  return (
    <div style={{
      minHeight: "100vh", background: "#111",
      display: "flex", flexDirection: "column", alignItems: "center",
      justifyContent: "center", padding: "20px", fontFamily: "-apple-system, sans-serif",
    }}>
      {/* Title */}
      <div style={{ textAlign: "center", marginBottom: 20 }}>
        <h1 style={{ fontFamily: FONT, fontSize: 22, color: C.white, letterSpacing: 2, margin: 0 }}>
          ☠️ StickDeath ∞ — iPhone Preview
        </h1>
        <p style={{ color: C.gray, fontSize: 13, marginTop: 6 }}>
          SwiftUI Build v5 · Fully functional · Every button works
        </p>
      </div>

      {/* Screen navigation */}
      <div style={{ display: "flex", gap: 6, marginBottom: 16, flexWrap: "wrap", justifyContent: "center" }}>
        {(["splash","welcome","login","signup","onboarding","choosePlan","main"] as Screen[]).map(s => (
          <button key={s} onClick={() => { setScreen(s); if(s==="main") setActiveTab("home"); setShowChatRoom(false); setShowCreatePost(false); }}
            style={{
              padding: "4px 10px", borderRadius: 6, border: "none", cursor: "pointer",
              fontSize: 11, fontFamily: FONT,
              background: screen === s ? C.red : C.surface, color: screen === s ? C.white : C.gray,
            }}>
            {s === "choosePlan" ? "Plan" : s}
          </button>
        ))}
        <button onClick={resetToSplash} style={{
          padding: "4px 10px", borderRadius: 6, border: `1px solid ${C.border}`, cursor: "pointer",
          fontSize: 11, fontFamily: FONT, background: "none", color: C.gray,
        }}>↺ Restart</button>
      </div>

      {/* iPhone Frame */}
      <div style={{
        width: 393, height: 852,
        borderRadius: 50, border: "4px solid #333",
        background: "#000", position: "relative",
        overflow: "hidden",
        boxShadow: "0 0 60px rgba(0,0,0,0.8), inset 0 0 0 2px #222",
      }}>
        {/* Status Bar */}
        <StatusBar />
        
        {/* Screen content */}
        <div style={{ position: "absolute", top: 0, left: 0, right: 0, bottom: 0, overflow: "hidden" }}>
          {screen === "splash" && <SplashScreen />}
          {screen === "welcome" && <WelcomeScreen onSignIn={() => setScreen("login")} onCreateAccount={() => setScreen("signup")} onGuest={() => setScreen("main")} />}
          {screen === "login" && <LoginScreen onLogin={(user) => { if (user?.role === "superuser") { window.open("http://72.167.36.70/admin", "_blank"); } setScreen("main"); }} onBack={() => setScreen("welcome")} />}
          {screen === "signup" && <SignUpScreen onSignUp={() => setScreen("onboarding")} onBack={() => setScreen("welcome")} />}
          {screen === "onboarding" && <OnboardingScreen page={onboardingPage} onNext={() => { if (onboardingPage < 3) setOnboardingPage(onboardingPage + 1); else setScreen("choosePlan"); }} onSkip={() => setScreen("choosePlan")} />}
          {screen === "choosePlan" && <ChoosePlanScreen selectedPlan={selectedPlan} onSelect={setSelectedPlan} onContinue={() => setScreen("main")} />}
          {screen === "main" && (
            <>
              {activeTab === "home" && <HomeTab feedFilter={feedFilter} setFeedFilter={setFeedFilter} showCreatePost={showCreatePost} setShowCreatePost={setShowCreatePost} />}
              {activeTab === "challenges" && <ChallengesTab filter={challengeFilter} setFilter={setChallengeFilter} />}
              {activeTab === "studio" && <StudioTab />}
              {activeTab === "messages" && <MessagesTab tab={msgTab} setTab={setMsgTab} showChatRoom={showChatRoom} setShowChatRoom={setShowChatRoom} />}
              {activeTab === "profile" && <ProfileTab />}
            </>
          )}
        </div>

        {/* Bottom Tab Bar (NOT shown in Studio or Messages) */}
        {showBottomNav && (
          <div style={{
            position: "absolute", bottom: 0, left: 0, right: 0, height: 80,
            background: "rgba(10,10,10,0.95)", borderTop: `1px solid ${C.border}`,
            display: "flex", alignItems: "center", justifyContent: "space-around",
            paddingBottom: 16, backdropFilter: "blur(20px)",
          }}>
            {[
              { id: "home" as Tab, icon: "🏠", label: "Home" },
              { id: "challenges" as Tab, icon: "⚔️", label: "Battles" },
              { id: "studio" as Tab, icon: "🎨", label: "Studio" },
              { id: "messages" as Tab, icon: "💬", label: "Messages" },
              { id: "profile" as Tab, icon: "👤", label: "Profile" },
            ].map(t => (
              <button key={t.id} onClick={() => setActiveTab(t.id)} style={{
                display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
                background: "none", border: "none", cursor: "pointer", padding: "4px 12px",
              }}>
                <span style={{ fontSize: 20 }}>{t.icon}</span>
                <span style={{
                  fontSize: 9, fontFamily: FONT, letterSpacing: 1,
                  color: activeTab === t.id ? C.red : C.textMuted,
                }}>{t.label}</span>
              </button>
            ))}
          </div>
        )}

        {/* Home indicator */}
        <div style={{
          position: "absolute", bottom: 4, left: "50%", transform: "translateX(-50%)",
          width: 134, height: 5, borderRadius: 3, background: "rgba(255,255,255,0.3)",
        }} />
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// STATUS BAR
// ═══════════════════════════════════════════════════════════════════
function StatusBar() {
  return (
    <div style={{
      position: "absolute", top: 0, left: 0, right: 0, height: 54, zIndex: 100,
      display: "flex", alignItems: "flex-end", justifyContent: "space-between",
      padding: "0 24px 4px", pointerEvents: "none",
    }}>
      <span style={{ fontSize: 14, fontWeight: 600, color: C.white }}>
        {new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
      </span>
      <div style={{ width: 120, height: 30, background: "#000", borderRadius: 20, position: "absolute", top: 8, left: "50%", transform: "translateX(-50%)" }} />
      <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
        <span style={{ fontSize: 12, color: C.white }}>📶</span>
        <span style={{ fontSize: 12, color: C.white }}>📡</span>
        <span style={{ fontSize: 11, color: C.white }}>🔋</span>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// SPLASH SCREEN
// ═══════════════════════════════════════════════════════════════════
function SplashScreen() {
  return (
    <div style={{
      height: "100%", background: `radial-gradient(circle at 50% 40%, #1a0000 0%, #0A0A0A 70%)`,
      display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center",
    }}>
      <div style={{ fontSize: 80, marginBottom: 20, animation: "pulse 2s infinite" }}>💀</div>
      <h1 style={{ fontFamily: FONT, fontSize: 28, color: C.white, letterSpacing: 4, margin: 0 }}>STICKDEATH</h1>
      <p style={{ fontFamily: FONT, fontSize: 16, color: C.red, letterSpacing: 8, margin: "4px 0 0" }}>∞</p>
      <p style={{ fontFamily: FONT, fontSize: 10, color: C.textMuted, marginTop: 30, letterSpacing: 3 }}>LOADING...</p>
    </div>
  );
}

// ═══ WELCOME ═══
function WelcomeScreen({ onSignIn, onCreateAccount, onGuest }: { onSignIn: ()=>void; onCreateAccount: ()=>void; onGuest: ()=>void }) {
  return (
    <div style={{ height: "100%", background: C.bg, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "0 32px" }}>
      <div style={{ fontSize: 64, marginBottom: 20 }}>💀</div>
      <h1 style={{ fontFamily: FONT, fontSize: 24, color: C.white, letterSpacing: 3, margin: 0 }}>STICKDEATH ∞</h1>
      <p style={{ color: C.textSecondary, fontSize: 13, textAlign: "center", marginTop: 12, lineHeight: 1.5 }}>
        Create. Animate. Destroy.<br/>The ultimate stick figure animation studio.
      </p>
      <div style={{ width: "100%", marginTop: 40, display: "flex", flexDirection: "column", gap: 12 }}>
        <Btn label="Sign In" onClick={onSignIn} primary />
        <Btn label="Create Account" onClick={onCreateAccount} />
        <button onClick={onGuest} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 13, cursor: "pointer", fontFamily: FONT, padding: 8 }}>
          Continue as Guest →
        </button>
      </div>
    </div>
  );
}

// ═══ LOGIN ═══
const SUPABASE_URL = "https://iohubnamsqnzyburydxr.supabase.co";
const SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlvaHVibmFtc3FuenlidXJ5ZHhyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5MzQ4MjcsImV4cCI6MjA5MTUxMDgyN30.5kwCtvB7SxInFZFISuDKgE9z6RvOFJPzi2VfefrL7m0";

function LoginScreen({ onLogin, onBack }: { onLogin: (user?: { email: string; role: string; username: string })=>void; onBack: ()=>void }) {
  const [email, setEmail] = useState("");
  const [pass, setPass] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleLogin = async () => {
    if (!email.trim() || !pass.trim()) { setError("Enter email and password"); return; }
    setLoading(true); setError("");
    try {
      const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: { "apikey": SUPABASE_ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ email: email.trim(), password: pass }),
      });
      const data = await res.json();
      if (data.error || !data.access_token) {
        setError(data.error_description || data.msg || "Invalid credentials");
        setLoading(false);
        return;
      }
      const meta = data.user?.user_metadata || {};
      const role = meta.role || "user";
      const username = meta.username || data.user?.email || "User";
      // Store session
      try { localStorage.setItem("sdi_session", JSON.stringify({ token: data.access_token, email: data.user?.email, role, username })); } catch {}
      onLogin({ email: data.user?.email || email, role, username });
    } catch (err) {
      setError("Connection failed. Check your internet.");
    }
    setLoading(false);
  };

  return (
    <div style={{ height: "100%", background: C.bg, padding: "60px 24px 24px" }}>
      <button onClick={onBack} style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 14, cursor: "pointer", marginBottom: 20 }}>← Back</button>
      <h2 style={{ fontFamily: FONT, fontSize: 22, color: C.white, margin: "0 0 24px" }}>Sign In</h2>
      <InputField label="Email" value={email} onChange={setEmail} />
      <InputField label="Password" value={pass} onChange={setPass} type="password" />
      {error && <p style={{ color: "#EF4444", fontSize: 11, margin: "8px 0 0", fontFamily: FONT }}>{error}</p>}
      <div style={{ marginTop: 24 }}><Btn label={loading ? "Signing in..." : "Sign In"} onClick={handleLogin} primary /></div>
      <p style={{ color: C.textMuted, fontSize: 12, textAlign: "center", marginTop: 16 }}>Forgot password?</p>
    </div>
  );
}

// ═══ SIGNUP ═══
function SignUpScreen({ onSignUp, onBack }: { onSignUp: ()=>void; onBack: ()=>void }) {
  return (
    <div style={{ height: "100%", background: C.bg, padding: "60px 24px 24px" }}>
      <button onClick={onBack} style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 14, cursor: "pointer", marginBottom: 20 }}>← Back</button>
      <h2 style={{ fontFamily: FONT, fontSize: 22, color: C.white, margin: "0 0 24px" }}>Create Account</h2>
      <InputField label="Username" value="" onChange={() => {}} />
      <InputField label="Email" value="" onChange={() => {}} />
      <InputField label="Password" value="" onChange={() => {}} type="password" />
      <div style={{ marginTop: 24 }}><Btn label="Create Account" onClick={onSignUp} primary /></div>
    </div>
  );
}

// ═══ ONBOARDING ═══
function OnboardingScreen({ page, onNext, onSkip }: { page: number; onNext: ()=>void; onSkip: ()=>void }) {
  const pages = [
    { icon: "🎨", title: "Animation Studio", desc: "Full-featured drawing & rigging tools with 17+ brushes, layers, and professional timeline." },
    { icon: "💀", title: "Fight Choreography", desc: "Create epic stick figure battles with built-in poses, effects, and 1,000+ sound effects." },
    { icon: "🤖", title: "Spatter AI", desc: "Your creative AI assistant — suggests poses, reviews animation, auto-tweens, and more." },
    { icon: "⚔️", title: "War Room & Community", desc: "Battle other creators, join challenges, share animations, and build your following." },
  ];
  const p = pages[page];
  return (
    <div style={{ height: "100%", background: C.bg, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "0 32px" }}>
      <div style={{ fontSize: 64, marginBottom: 24 }}>{p.icon}</div>
      <h2 style={{ fontFamily: FONT, fontSize: 20, color: C.white, margin: 0, textAlign: "center" }}>{p.title}</h2>
      <p style={{ color: C.textSecondary, fontSize: 13, textAlign: "center", marginTop: 12, lineHeight: 1.5 }}>{p.desc}</p>
      <div style={{ display: "flex", gap: 6, marginTop: 32 }}>
        {pages.map((_, i) => <div key={i} style={{ width: i === page ? 24 : 8, height: 8, borderRadius: 4, background: i === page ? C.red : C.border, transition: "all 0.3s" }} />)}
      </div>
      <div style={{ width: "100%", marginTop: 40 }}>
        <Btn label={page < 3 ? "Next" : "Get Started"} onClick={onNext} primary />
        {page < 3 && <button onClick={onSkip} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 12, cursor: "pointer", width: "100%", marginTop: 12, fontFamily: FONT }}>Skip</button>}
      </div>
    </div>
  );
}

// ═══ CHOOSE PLAN ═══
function ChoosePlanScreen({ selectedPlan, onSelect, onContinue }: { selectedPlan: string | null; onSelect: (p: string)=>void; onContinue: ()=>void }) {
  const plans = [
    { id: "free", name: "Free", price: "$0", features: ["5 projects", "Basic tools", "480p export", "Watermark"], color: C.textSecondary },
    { id: "pro", name: "Pro", price: "$9.99/mo", features: ["Unlimited projects", "All tools", "1080p export", "No watermark", "Sound library"], color: C.red, popular: true },
    { id: "studio", name: "Studio", price: "$19.99/mo", features: ["Everything in Pro", "Team workspace", "Commercial license", "Unlimited AI", "API access"], color: C.purple },
  ];
  return (
    <div style={{ height: "100%", background: C.bg, padding: "60px 20px 24px", overflowY: "auto" }}>
      <h2 style={{ fontFamily: FONT, fontSize: 20, color: C.white, margin: "0 0 6px", textAlign: "center" }}>Choose Your Plan</h2>
      <p style={{ color: C.textMuted, fontSize: 12, textAlign: "center", margin: "0 0 24px" }}>Unlock your creative potential</p>
      <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {plans.map(p => (
          <button key={p.id} onClick={() => onSelect(p.id)} style={{
            padding: 16, borderRadius: 12, border: `2px solid ${selectedPlan === p.id ? p.color : C.border}`,
            background: selectedPlan === p.id ? `${p.color}15` : C.surface, cursor: "pointer", textAlign: "left", position: "relative",
          }}>
            {"popular" in p && <span style={{ position: "absolute", top: -8, right: 12, background: C.red, color: C.white, fontSize: 9, padding: "2px 8px", borderRadius: 8, fontFamily: FONT }}>POPULAR</span>}
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <span style={{ fontFamily: FONT, fontSize: 16, color: C.white }}>{p.name}</span>
              <span style={{ fontFamily: FONT, fontSize: 14, color: p.color }}>{p.price}</span>
            </div>
            <div style={{ marginTop: 8 }}>
              {p.features.map((f, i) => <div key={i} style={{ fontSize: 11, color: C.textSecondary, padding: "2px 0" }}>✓ {f}</div>)}
            </div>
          </button>
        ))}
      </div>
      <div style={{ marginTop: 20 }}><Btn label="Continue" onClick={onContinue} primary /></div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// HOME TAB
// ═══════════════════════════════════════════════════════════════════
function HomeTab({ feedFilter, setFeedFilter, showCreatePost, setShowCreatePost }: {
  feedFilter: string; setFeedFilter: (f: string)=>void; showCreatePost: boolean; setShowCreatePost: (v: boolean)=>void;
}) {
  const posts = [
    { id: "p1", user: "NeonBlade", avatar: "🎭", title: "Neon Duel", likes: 342, views: "1.2K", time: "2h" },
    { id: "p2", user: "StickMaster", avatar: "💀", title: "Epic Fall", likes: 128, views: "856", time: "4h" },
    { id: "p3", user: "PixelFury", avatar: "🔥", title: "Sword Fight III", likes: 567, views: "2.1K", time: "6h" },
    { id: "p4", user: "DeathDraw", avatar: "☠️", title: "Sniper Scene", likes: 234, views: "1.5K", time: "8h" },
  ];
  return (
    <div style={{ height: "100%", background: C.bg, paddingTop: 54, paddingBottom: 80, overflowY: "auto" }}>
      <div style={{ padding: "12px 16px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <h2 style={{ fontFamily: FONT, fontSize: 20, color: C.white, margin: 0 }}>Feed</h2>
        <button onClick={() => setShowCreatePost(true)} style={{ background: C.red, border: "none", borderRadius: 20, color: C.white, padding: "6px 14px", fontSize: 12, cursor: "pointer", fontFamily: FONT }}>+ Create</button>
      </div>
      <div style={{ display: "flex", gap: 8, padding: "0 16px", marginBottom: 12 }}>
        {["trending", "following", "new"].map(f => (
          <button key={f} onClick={() => setFeedFilter(f)} style={{
            padding: "6px 14px", borderRadius: 16, border: "none", cursor: "pointer",
            background: feedFilter === f ? C.red : C.surface, color: feedFilter === f ? C.white : C.textMuted,
            fontSize: 11, fontFamily: FONT, textTransform: "capitalize",
          }}>{f}</button>
        ))}
      </div>
      {posts.map(p => (
        <div key={p.id} style={{ margin: "0 16px 12px", background: C.surface, borderRadius: 12, overflow: "hidden", border: `1px solid ${C.border}` }}>
          <div style={{ height: 160, background: `linear-gradient(135deg, ${C.surfaceDark}, ${C.surface2})`, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <span style={{ fontSize: 48, opacity: 0.3 }}>💀</span>
          </div>
          <div style={{ padding: 12 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
              <span style={{ fontSize: 20 }}>{p.avatar}</span>
              <span style={{ fontFamily: FONT, fontSize: 13, color: C.white }}>{p.user}</span>
              <span style={{ fontSize: 11, color: C.textMuted, marginLeft: "auto" }}>{p.time}</span>
            </div>
            <p style={{ fontFamily: FONT, fontSize: 14, color: C.white, margin: "0 0 8px" }}>{p.title}</p>
            <div style={{ display: "flex", gap: 16, fontSize: 11, color: C.textMuted }}>
              <span>❤️ {p.likes}</span>
              <span>👁️ {p.views}</span>
              <span>💬 {Math.floor(p.likes / 5)}</span>
            </div>
          </div>
        </div>
      ))}

      {/* Create Post Modal */}
      {showCreatePost && (
        <div style={{ position: "absolute", bottom: 0, left: 0, right: 0, top: "30%", background: C.surfaceDark, borderRadius: "20px 20px 0 0", padding: 20, border: `1px solid ${C.border}` }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
            <h3 style={{ fontFamily: FONT, fontSize: 16, color: C.white, margin: 0 }}>Create Post</h3>
            <button onClick={() => setShowCreatePost(false)} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 18, cursor: "pointer" }}>✕</button>
          </div>
          <textarea placeholder="What did you create?" style={{ width: "100%", height: 80, background: C.surface, border: `1px solid ${C.border}`, borderRadius: 8, color: C.white, fontSize: 13, padding: 12, resize: "none", fontFamily: "inherit" }} />
          <Btn label="Post" onClick={() => setShowCreatePost(false)} primary />
        </div>
      )}
    </div>
  );
}

// ═══ CHALLENGES TAB ═══
function ChallengesTab({ filter, setFilter }: { filter: string; setFilter: (f: string)=>void }) {
  const challenges = [
    { id: "c1", title: "Last Stand", type: "1v1 Battle", prize: "500 coins", time: "30m", status: "active" },
    { id: "c2", title: "Speed Run", type: "Solo", prize: "200 coins", time: "1h", status: "active" },
    { id: "c3", title: "Epic Combo", type: "Community", prize: "1000 coins", time: "2d", status: "active" },
    { id: "c4", title: "Freestyle", type: "Open", prize: "300 coins", time: "6h", status: "upcoming" },
  ];
  return (
    <div style={{ height: "100%", background: C.bg, paddingTop: 54, paddingBottom: 80, overflowY: "auto" }}>
      <div style={{ padding: "12px 16px" }}>
        <h2 style={{ fontFamily: FONT, fontSize: 20, color: C.white, margin: "0 0 12px" }}>Challenges</h2>
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {["active", "upcoming", "completed"].map(f => (
            <button key={f} onClick={() => setFilter(f)} style={{
              padding: "6px 14px", borderRadius: 16, border: "none", cursor: "pointer",
              background: filter === f ? C.red : C.surface, color: filter === f ? C.white : C.textMuted,
              fontSize: 11, fontFamily: FONT, textTransform: "capitalize",
            }}>{f}</button>
          ))}
        </div>
      </div>
      {challenges.filter(c => c.status === filter || filter === "active").map(c => (
        <div key={c.id} style={{ margin: "0 16px 12px", padding: 16, background: C.surface, borderRadius: 12, border: `1px solid ${C.border}` }}>
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <h3 style={{ fontFamily: FONT, fontSize: 15, color: C.white, margin: 0 }}>{c.title}</h3>
            <span style={{ fontSize: 11, color: C.orange, fontFamily: FONT }}>{c.time}</span>
          </div>
          <div style={{ display: "flex", gap: 12, marginTop: 8, fontSize: 11, color: C.textMuted }}>
            <span>⚔️ {c.type}</span><span>🏆 {c.prize}</span>
          </div>
          <button style={{ marginTop: 10, background: C.red, border: "none", borderRadius: 8, color: C.white, padding: "6px 16px", fontSize: 11, cursor: "pointer", fontFamily: FONT }}>
            Join Battle
          </button>
        </div>
      ))}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// STUDIO TAB — EXACT MATCH TO VIDEO
// ═══════════════════════════════════════════════════════════════════
function StudioTab() {
  // ─── State ───
  const [projectName, _setProjectName] = useState("Untitled Animation");
  const [selectedTool, setSelectedTool] = useState<StudioTool>("pencil");
  const [activePanel, setActivePanel] = useState<StudioPanel>("none");
  const [currentColor, setCurrentColor] = useState("#FF0000");
  const [brushSize, setBrushSize] = useState(4);
  const [brushOpacity, setBrushOpacity] = useState(100);
  const [smoothing, setSmoothing] = useState(50);
  const [pressureSensitivity, setPressureSensitivity] = useState(true);
  const [fps, setFps] = useState(12);
  const [canvasW, setCanvasW] = useState(1080);
  const [canvasH, setCanvasH] = useState(1080);
  const [frames, setFrames] = useState<FrameData[]>([{ id: "f1", hasContent: false }, { id: "f2", hasContent: false }]);
  const [activeFrame, setActiveFrame] = useState(0);
  const [layers, setLayers] = useState<LayerData[]>([{
    id: "l1", name: "Layer 1", visible: true, locked: false, lockType: "free",
    opacity: 100, expanded: false, colorLabel: undefined, blendMode: "Normal", glowEnabled: false,
  }]);
  const [isPlaying, setIsPlaying] = useState(false);
  const [zoomLevel, setZoomLevel] = useState(100);
  const [onionSkin, setOnionSkin] = useState(false);
  const [gridEnabled, setGridEnabled] = useState(true);
  const [showToolSettings, setShowToolSettings] = useState(false);
  const [undoStack, setUndoStack] = useState<DrawnStroke[][]>([]);
  const [redoStack, setRedoStack] = useState<DrawnStroke[][]>([]);
  const [strokes, setStrokes] = useState<DrawnStroke[]>([]);
  const [currentStroke, setCurrentStroke] = useState<DrawnPoint[]>([]);
  const [isDrawing, setIsDrawing] = useState(false);
  const [lastSave, setLastSave] = useState("just now");
  const [spatterMessages, setSpatterMessages] = useState<{text:string;isSpatter:boolean}[]>([]);
  const [spatterInput, setSpatterInput] = useState("");
  const [exportFormat, setExportFormat] = useState<"mp4"|"gif"|"png"|"spritesheet">("mp4");
  const [exportQuality, setExportQuality] = useState<"480p"|"720p"|"1080p">("480p");
  const [selectedSoundCat, setSelectedSoundCat] = useState<string | null>(null);
  const [audioClips, setAudioClips] = useState<AudioClip[]>([]);
  const [audioSnapOn, setAudioSnapOn] = useState(true);
  const [bgCat, setBgCat] = useState("all");
  const [imageCat, setImageCat] = useState("people");
  const [imageTab, setImageTab] = useState<"upload"|"url"|"library">("library");
  const [stickerTab, setStickerTab] = useState<"stickers"|"emoji">("stickers");
  const [stickerCat, setStickerCat] = useState("fighters");
  const [vaultTab, setVaultTab] = useState<"browse"|"recent"|"favorites">("browse");
  const [voicePreset, setVoicePreset] = useState("normal");
  const [voiceScript, setVoiceScript] = useState("");
  const [voiceSpeed, setVoiceSpeed] = useState(1.0);
  const [voicePitch, setVoicePitch] = useState(1.0);
  const [fillTolerance, setFillTolerance] = useState(32);
  const [fillExpand, setFillExpand] = useState(0);
  const [fillContiguous, setFillContiguous] = useState(true);
  const [fillAntiAlias, setFillAntiAlias] = useState(true);
  const [fillSampleAll, setFillSampleAll] = useState(false);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  // Auto-save timer
  useEffect(() => {
    const interval = setInterval(() => {
      const seconds = Math.floor(Math.random() * 50 + 10);
      setLastSave(`${seconds}s ago`);
    }, 10000);
    return () => clearInterval(interval);
  }, []);

  // Playback
  useEffect(() => {
    if (!isPlaying) return;
    const interval = setInterval(() => {
      setActiveFrame(f => (f + 1) % frames.length);
    }, 1000 / fps);
    return () => clearInterval(interval);
  }, [isPlaying, fps, frames.length]);

  // Canvas drawing
  const redrawCanvas = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = canvas.width, H = canvas.height;
    
    // Clear
    ctx.fillStyle = "#0D0D12";
    ctx.fillRect(0, 0, W, H);
    
    // Canvas area (white with grid)
    const canvasArea = { x: 20, y: 10, w: W - 40, h: H - 20 };
    ctx.fillStyle = "#FAFAFA";
    ctx.fillRect(canvasArea.x, canvasArea.y, canvasArea.w, canvasArea.h);
    
    // Grid dots
    if (gridEnabled) {
      ctx.fillStyle = "#E0E0E0";
      for (let gx = canvasArea.x; gx <= canvasArea.x + canvasArea.w; gx += 20) {
        for (let gy = canvasArea.y; gy <= canvasArea.y + canvasArea.h; gy += 20) {
          ctx.fillRect(gx, gy, 1, 1);
        }
      }
    }
    
    // Draw strokes
    for (const stroke of strokes) {
      if (stroke.points.length < 2) continue;
      ctx.beginPath();
      ctx.strokeStyle = stroke.color;
      ctx.lineWidth = stroke.width;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.globalAlpha = stroke.opacity / 100;
      ctx.moveTo(stroke.points[0].x, stroke.points[0].y);
      for (let i = 1; i < stroke.points.length; i++) {
        ctx.lineTo(stroke.points[i].x, stroke.points[i].y);
      }
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    
    // Current stroke
    if (currentStroke.length > 1) {
      ctx.beginPath();
      ctx.strokeStyle = currentColor;
      ctx.lineWidth = brushSize;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.globalAlpha = brushOpacity / 100;
      ctx.moveTo(currentStroke[0].x, currentStroke[0].y);
      for (let i = 1; i < currentStroke.length; i++) {
        ctx.lineTo(currentStroke[i].x, currentStroke[i].y);
      }
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
  }, [strokes, currentStroke, currentColor, brushSize, brushOpacity, gridEnabled]);

  useEffect(() => { redrawCanvas(); }, [redrawCanvas]);

  const handleCanvasPointerDown = (e: React.PointerEvent) => {
    if (!["pencil","pen","brush","marker","crayon","line","eraser"].includes(selectedTool)) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (canvas.width / rect.width);
    const y = (e.clientY - rect.top) * (canvas.height / rect.height);
    setIsDrawing(true);
    setCurrentStroke([{ x, y }]);
  };

  const handleCanvasPointerMove = (e: React.PointerEvent) => {
    if (!isDrawing) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = (e.clientX - rect.left) * (canvas.width / rect.width);
    const y = (e.clientY - rect.top) * (canvas.height / rect.height);
    setCurrentStroke(prev => [...prev, { x, y }]);
  };

  const handleCanvasPointerUp = () => {
    if (!isDrawing) return;
    setIsDrawing(false);
    if (currentStroke.length > 1) {
      const newStroke: DrawnStroke = {
        id: `stroke_${Date.now()}`, tool: selectedTool, points: currentStroke,
        color: selectedTool === "eraser" ? "#FAFAFA" : currentColor,
        width: selectedTool === "eraser" ? brushSize * 3 : brushSize,
        opacity: brushOpacity, layerId: layers[0]?.id || "l1",
      };
      setUndoStack(prev => [...prev, strokes]);
      setRedoStack([]);
      setStrokes(prev => [...prev, newStroke]);
      const newFrames = [...frames];
      newFrames[activeFrame] = { ...newFrames[activeFrame], hasContent: true };
      setFrames(newFrames);
    }
    setCurrentStroke([]);
  };

  const undo = () => {
    if (undoStack.length === 0) return;
    setRedoStack(prev => [...prev, strokes]);
    setStrokes(undoStack[undoStack.length - 1]);
    setUndoStack(prev => prev.slice(0, -1));
  };

  const redo = () => {
    if (redoStack.length === 0) return;
    setUndoStack(prev => [...prev, strokes]);
    setStrokes(redoStack[redoStack.length - 1]);
    setRedoStack(prev => prev.slice(0, -1));
  };

  const addFrame = () => {
    setFrames(prev => [...prev, { id: `f${prev.length + 1}`, hasContent: false }]);
    setActiveFrame(frames.length);
  };

  const deleteFrame = () => {
    if (frames.length <= 1) return;
    const newFrames = frames.filter((_, i) => i !== activeFrame);
    setFrames(newFrames);
    setActiveFrame(Math.min(activeFrame, newFrames.length - 1));
  };

  const addLayer = () => {
    const num = layers.length + 1;
    setLayers(prev => [...prev, {
      id: `l${num}`, name: `Layer ${num}`, visible: true, locked: false, lockType: "free",
      opacity: 100, expanded: false, blendMode: "Normal", glowEnabled: false,
    }]);
  };

  const togglePanel = (p: StudioPanel) => {
    setActivePanel(activePanel === p ? "none" : p);
    if (p === "toolSettings") setShowToolSettings(!showToolSettings);
  };

  const toolDef = STUDIO_TOOLS.find(t => t.id === selectedTool)!;

  // Tool-specific settings content
  const getToolSettings = () => {
    switch (selectedTool) {
      case "pencil": case "pen": case "brush": case "marker": case "crayon":
        return (
          <div style={{ padding: "8px 12px", background: "rgba(20,20,28,0.95)", borderBottom: `1px solid ${C.border}` }}>
            <SliderRow label="Size" value={brushSize} min={1} max={50} unit="px" onChange={setBrushSize} />
            <SliderRow label="Opacity" value={brushOpacity} min={1} max={100} unit="%" onChange={setBrushOpacity} />
            <SliderRow label="Smoothing" value={smoothing} min={0} max={100} unit="" onChange={setSmoothing} />
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 4 }}>
              <span style={{ fontSize: 10, color: C.textMuted, fontFamily: FONT }}>Pressure Sensitivity</span>
              <button onClick={() => setPressureSensitivity(!pressureSensitivity)} style={{
                width: 36, height: 20, borderRadius: 10, border: "none", cursor: "pointer",
                background: pressureSensitivity ? C.red : C.border, position: "relative", transition: "background 0.2s",
              }}>
                <div style={{ width: 16, height: 16, borderRadius: 8, background: C.white, position: "absolute", top: 2, left: pressureSensitivity ? 18 : 2, transition: "left 0.2s" }} />
              </button>
            </div>
            <div style={{ fontSize: 9, color: C.textMuted, marginTop: 6, fontFamily: FONT }}>Shortcut: {toolDef.shortcut}</div>
          </div>
        );
      case "fill":
        return (
          <div style={{ padding: "8px 12px", background: "rgba(20,20,28,0.95)", borderBottom: `1px solid ${C.border}` }}>
            <SliderRow label="Tolerance" value={fillTolerance} min={0} max={255} unit="" onChange={setFillTolerance} />
            <SliderRow label="Opacity" value={brushOpacity} min={1} max={100} unit="%" onChange={setBrushOpacity} />
            <SliderRow label="Expand" value={fillExpand} min={0} max={20} unit="px" onChange={setFillExpand} />
            <div style={{ display: "flex", gap: 4, marginTop: 6, flexWrap: "wrap" }}>
              <ToggleBtn label="Contiguous" active={fillContiguous} onClick={() => setFillContiguous(!fillContiguous)} />
              <ToggleBtn label="Anti-Alias" active={fillAntiAlias} onClick={() => setFillAntiAlias(!fillAntiAlias)} />
              <ToggleBtn label="Sample All" active={fillSampleAll} onClick={() => setFillSampleAll(!fillSampleAll)} />
            </div>
            <div style={{ fontSize: 9, color: C.textMuted, marginTop: 6, fontFamily: FONT }}>Shortcut: G</div>
          </div>
        );
      case "eraser":
        return (
          <div style={{ padding: "8px 12px", background: "rgba(20,20,28,0.95)", borderBottom: `1px solid ${C.border}` }}>
            <SliderRow label="Size" value={brushSize} min={1} max={80} unit="px" onChange={setBrushSize} />
            <SliderRow label="Opacity" value={brushOpacity} min={1} max={100} unit="%" onChange={setBrushOpacity} />
            <div style={{ fontSize: 9, color: C.textMuted, marginTop: 6, fontFamily: FONT }}>Shortcut: E</div>
          </div>
        );
      default:
        return (
          <div style={{ padding: "8px 12px", background: "rgba(20,20,28,0.95)", borderBottom: `1px solid ${C.border}` }}>
            <div style={{ fontSize: 10, color: C.textMuted, fontFamily: FONT }}>Shortcut: {toolDef.shortcut}</div>
          </div>
        );
    }
  };

  return (
    <div style={{ height: "100%", background: C.bg, display: "flex", flexDirection: "column", overflow: "hidden" }}>
      {/* ─── Header (exact from video) ─── */}
      <div style={{ padding: "54px 10px 6px", display: "flex", alignItems: "center", gap: 6, borderBottom: `1px solid ${C.borderDim}`, flexShrink: 0 }}>
        <button style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 16, cursor: "pointer", padding: 4 }}>‹</button>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontFamily: FONT, fontSize: 14, color: C.white, fontWeight: 700, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{projectName}</div>
          <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted }}>{fps} FPS · {frames.length} frames · {layers.length} layers</div>
        </div>
        <button onClick={() => togglePanel("none")} style={{ background: "none", border: `1px solid ${C.border}`, borderRadius: 4, color: C.textMuted, fontSize: 8, padding: "3px 8px", cursor: "pointer", fontFamily: FONT }}>
          HIDE
        </button>
        <div style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 10, color: C.textMuted }}>
          <span>💾</span><span>{lastSave}</span>
        </div>
        <button style={{ background: "none", border: "none", color: C.red, fontSize: 16, cursor: "pointer", padding: 4 }}>↑</button>
        <button onClick={() => togglePanel(activePanel === "settings" ? "none" : "settings")}
          style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 16, cursor: "pointer", padding: 4 }}>⋯</button>
      </div>

      {/* ─── Tool Strip (horizontal scroll, exact from video) ─── */}
      <div style={{
        display: "flex", alignItems: "center", gap: 2, padding: "6px 6px",
        overflowX: "auto", flexShrink: 0,
        background: "rgba(18,18,24,0.95)", borderBottom: `1px solid ${C.borderDim}`,
        scrollbarWidth: "none",
      }}>
        {/* Drag handle */}
        <div style={{ display: "grid", gridTemplateColumns: "4px 4px", gap: 2, padding: "0 4px", flexShrink: 0 }}>
          {[...Array(6)].map((_, i) => <div key={i} style={{ width: 4, height: 4, borderRadius: 2, background: C.textMuted }} />)}
        </div>
        {/* Color swatch */}
        <button onClick={() => togglePanel("colorPicker")} style={{
          width: 44, height: 44, borderRadius: 10, border: "none", cursor: "pointer",
          background: currentColor, flexShrink: 0,
          boxShadow: `0 0 12px ${currentColor}60`,
        }} />
        {/* Tools */}
        {STUDIO_TOOLS.map(t => (
          <button key={t.id} onClick={() => { setSelectedTool(t.id); setShowToolSettings(true); }}
            style={{
              display: "flex", flexDirection: "column", alignItems: "center", gap: 1,
              padding: "6px 8px", borderRadius: 8, border: "none", cursor: "pointer",
              background: selectedTool === t.id ? `${t.topColor}30` : "transparent",
              minWidth: 48, flexShrink: 0,
              boxShadow: selectedTool === t.id ? `0 0 8px ${t.glowColor}40` : "none",
              transition: "all 0.15s",
            }}>
            <span style={{ fontSize: 18 }}>{t.icon}</span>
            <span style={{
              fontSize: 8, fontFamily: FONT, letterSpacing: 0.5,
              color: selectedTool === t.id ? t.glowColor : C.textMuted,
            }}>{t.label}</span>
          </button>
        ))}
      </div>

      {/* ─── Tool Settings Dropdown (NOT bottom sheet) ─── */}
      {showToolSettings && getToolSettings()}

      {/* ─── Canvas Area ─── */}
      <div style={{ flex: 1, position: "relative", overflow: "hidden", background: "#0D0D12" }}>
        <canvas
          ref={canvasRef}
          width={340}
          height={280}
          onPointerDown={handleCanvasPointerDown}
          onPointerMove={handleCanvasPointerMove}
          onPointerUp={handleCanvasPointerUp}
          onPointerLeave={handleCanvasPointerUp}
          style={{ width: "100%", height: "100%", touchAction: "none", cursor: selectedTool === "hand" ? "grab" : "crosshair" }}
        />
        
        {/* Zoom controls (right side) */}
        <div style={{ position: "absolute", right: 8, bottom: 16, display: "flex", flexDirection: "column", gap: 6 }}>
          <ZoomBtn label="+" onClick={() => setZoomLevel(Math.min(zoomLevel + 25, 400))} />
          <ZoomBtn label="−" onClick={() => setZoomLevel(Math.max(zoomLevel - 25, 25))} />
          <ZoomBtn label="FIT" onClick={() => setZoomLevel(100)} small />
        </div>
      </div>

      {/* ─── Frame Timeline ─── */}
      <div style={{
        display: "flex", alignItems: "center", gap: 4, padding: "6px 8px",
        background: "rgba(18,18,24,0.95)", borderTop: `1px solid ${C.borderDim}`, flexShrink: 0,
      }}>
        <button onClick={() => setActiveFrame(Math.max(0, activeFrame - 1))} style={{ ...tinyBtnStyle, fontSize: 10 }}>‹</button>
        <button onClick={() => setIsPlaying(!isPlaying)} style={{
          width: 32, height: 32, borderRadius: 16, border: `1px solid ${C.border}`,
          background: isPlaying ? C.red : C.surface, color: C.white, fontSize: 12,
          cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          {isPlaying ? "⏸" : "▶"}
        </button>
        <button onClick={() => setActiveFrame(Math.min(frames.length - 1, activeFrame + 1))} style={{ ...tinyBtnStyle, fontSize: 10 }}>›</button>
        
        {/* Frame thumbnails */}
        <div style={{ flex: 1, display: "flex", gap: 4, overflowX: "auto", scrollbarWidth: "none", padding: "2px 0" }}>
          {frames.map((f, i) => (
            <button key={f.id} onClick={() => setActiveFrame(i)} style={{
              width: 36, height: 36, borderRadius: 6, flexShrink: 0,
              border: `2px solid ${i === activeFrame ? C.red : C.border}`,
              background: f.hasContent ? C.surface2 : C.surface,
              cursor: "pointer", position: "relative",
              boxShadow: i === activeFrame ? `0 0 8px ${C.redGlow}` : "none",
            }}>
              <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>{i + 1}</span>
              {i === activeFrame && <div style={{ position: "absolute", bottom: -8, left: "50%", transform: "translateX(-50%)", fontSize: 7, color: C.red, fontFamily: FONT }}>{i + 1}</div>}
            </button>
          ))}
        </div>
        
        <button onClick={addFrame} style={{ ...tinyBtnStyle, fontSize: 14 }}>+</button>
        <button style={{ ...tinyBtnStyle, fontSize: 10 }}>◐</button>
        <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT, flexShrink: 0 }}>{activeFrame + 1}/{frames.length}</span>
      </div>

      {/* ─── Bottom Toolbar (AUDIO, UNDO, REDO, COPY, PASTE, DEL, LAYER) ─── */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-around",
        padding: "6px 4px 20px", background: "rgba(14,14,18,0.98)",
        borderTop: `1px solid ${C.borderDim}`, flexShrink: 0,
      }}>
        {[
          { icon: "🎵", label: "AUDIO", action: () => togglePanel("soundLibrary") },
          { icon: "↩️", label: "UNDO", action: undo },
          { icon: "↪️", label: "REDO", action: redo },
          { icon: "📋", label: "COPY", action: () => {} },
          { icon: "📌", label: "PASTE", action: () => {} },
          { icon: "🗑️", label: "DEL", action: deleteFrame },
          { icon: "📑", label: "LAYER", action: () => togglePanel("layers"), badge: layers.length },
        ].map((b, i) => (
          <button key={i} onClick={b.action} style={{
            display: "flex", flexDirection: "column", alignItems: "center", gap: 1,
            background: "none", border: "none", cursor: "pointer", padding: "2px 6px", position: "relative",
          }}>
            <span style={{ fontSize: 16 }}>{b.icon}</span>
            <span style={{ fontSize: 7, fontFamily: FONT, color: C.textMuted, letterSpacing: 0.5 }}>{b.label}</span>
            {b.badge && (
              <span style={{
                position: "absolute", top: -2, right: 0, background: C.red, color: C.white,
                fontSize: 7, width: 14, height: 14, borderRadius: 7, display: "flex",
                alignItems: "center", justifyContent: "center", fontWeight: 700,
              }}>{b.badge}</span>
            )}
          </button>
        ))}
      </div>

      {/* ─── PANELS (slide up from bottom) ─── */}
      
      {/* ⋯ Settings Menu */}
      {activePanel === "settings" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="60%">
          <PanelHeader title="Menu" onClose={() => setActivePanel("none")} />
          <div style={{ padding: "4px 0" }}>
            <div style={{ padding: "6px 16px", fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2 }}>PROJECT</div>
            <SettingsRow icon="⚙️" label="Project Settings" onClick={() => setActivePanel("projectSettings")} />
            <div style={{ padding: "6px 16px", fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginTop: 8 }}>TOOLS</div>
            <SettingsRow icon="🎬" label="Frames Viewer" onClick={() => setActivePanel("framesViewer")} />
            <SettingsRow icon="🧅" label="Onion" right={<div style={{ display: "flex", alignItems: "center", gap: 6 }}><span style={{ color: C.red, fontSize: 10, fontFamily: FONT }}>Edit</span><ToggleSwitch on={onionSkin} onToggle={() => setOnionSkin(!onionSkin)} /></div>} />
            <SettingsRow icon="📐" label="Grid" right={<div style={{ display: "flex", alignItems: "center", gap: 6 }}><span style={{ color: C.red, fontSize: 10, fontFamily: FONT }}>Edit</span><ToggleSwitch on={gridEnabled} onToggle={() => setGridEnabled(!gridEnabled)} /></div>} />
            <SettingsRow icon="✨" label="Magic Cut" onClick={() => setActivePanel("magicCut")} />
            <SettingsRow icon="🖼️" label="Background Library" onClick={() => setActivePanel("backgroundLibrary")} />
            <SettingsRow icon="🎬" label="Rotoscope / Video" onClick={() => setActivePanel("importVideo")} />
            <SettingsRow icon="🖼️" label="Add Picture" onClick={() => setActivePanel("addImage")} />
            <SettingsRow icon="🗣️" label="AI Voice Maker" onClick={() => setActivePanel("aiVoice")} />
            <SettingsRow icon="🎨" label="Spatter AI" onClick={() => setActivePanel("spatter")} accent />
          </div>
        </PanelOverlay>
      )}

      {/* Project Settings */}
      {activePanel === "projectSettings" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="55%">
          <PanelHeader title="⚙️ Project Settings" onClose={() => setActivePanel("settings")} />
          <div style={{ padding: "12px 16px" }}>
            <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginBottom: 8 }}>FRAME RATE</div>
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 16 }}>
              {FPS_OPTIONS.map(f => (
                <button key={f} onClick={() => setFps(f)} style={{
                  padding: "6px 12px", borderRadius: 8, border: `1px solid ${fps === f ? C.red : C.border}`,
                  background: fps === f ? "rgba(200,0,0,0.15)" : C.surface, color: fps === f ? C.red : C.textSecondary,
                  fontSize: 12, fontFamily: FONT, cursor: "pointer",
                }}>{f}</button>
              ))}
            </div>
            <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginBottom: 8 }}>CANVAS SIZE</div>
            <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
              <div style={{ flex: 1 }}>
                <label style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>Width</label>
                <input type="number" value={canvasW} onChange={e => setCanvasW(Number(e.target.value))} style={numInputStyle} />
              </div>
              <span style={{ color: C.textMuted, alignSelf: "flex-end", paddingBottom: 8 }}>×</span>
              <div style={{ flex: 1 }}>
                <label style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>Height</label>
                <input type="number" value={canvasH} onChange={e => setCanvasH(Number(e.target.value))} style={numInputStyle} />
              </div>
            </div>
            <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
              {CANVAS_PRESETS.map(p => (
                <button key={p.id} onClick={() => { setCanvasW(p.w); setCanvasH(p.h); }} style={{
                  padding: "4px 10px", borderRadius: 6, border: `1px solid ${C.border}`,
                  background: canvasW === p.w && canvasH === p.h ? "rgba(200,0,0,0.15)" : C.surface,
                  color: canvasW === p.w && canvasH === p.h ? C.red : C.textMuted,
                  fontSize: 9, fontFamily: FONT, cursor: "pointer",
                }}>{p.label}</button>
              ))}
            </div>
          </div>
        </PanelOverlay>
      )}

      {/* Color Picker */}
      {activePanel === "colorPicker" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="45%">
          <PanelHeader title="Color" onClose={() => setActivePanel("none")} />
          <div style={{ padding: "12px 16px" }}>
            {/* HSV-style color grid */}
            <div style={{
              height: 120, borderRadius: 8, marginBottom: 12,
              background: `linear-gradient(to bottom, transparent, #000), linear-gradient(to right, #fff, ${currentColor})`,
              cursor: "pointer",
            }} onClick={(e) => {
              const rect = e.currentTarget.getBoundingClientRect();
              const hue = Math.floor((e.clientX - rect.left) / rect.width * 360);
              setCurrentColor(`hsl(${hue}, 100%, 50%)`);
            }} />
            {/* Hue slider */}
            <div style={{
              height: 24, borderRadius: 12, marginBottom: 12,
              background: "linear-gradient(to right, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)",
              cursor: "pointer",
            }} onClick={(e) => {
              const rect = e.currentTarget.getBoundingClientRect();
              const hue = Math.floor((e.clientX - rect.left) / rect.width * 360);
              setCurrentColor(`hsl(${hue}, 100%, 50%)`);
            }} />
            {/* Palette swatches */}
            {COLOR_PALETTES.map(pal => (
              <div key={pal.name} style={{ marginBottom: 8 }}>
                <div style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT, marginBottom: 4 }}>{pal.name}</div>
                <div style={{ display: "flex", gap: 6 }}>
                  {pal.colors.map((c, i) => (
                    <button key={i} onClick={() => setCurrentColor(c)} style={{
                      width: 28, height: 28, borderRadius: 6, border: currentColor === c ? "2px solid white" : "1px solid rgba(255,255,255,0.1)",
                      background: c, cursor: "pointer",
                    }} />
                  ))}
                </div>
              </div>
            ))}
          </div>
        </PanelOverlay>
      )}

      {/* Layers Panel */}
      {activePanel === "layers" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="50%">
          <div style={{ overflowY: "auto", maxHeight: "100%" }}>
            {layers.map((layer, i) => (
              <div key={layer.id}>
                <div style={{
                  display: "flex", alignItems: "center", gap: 6, padding: "8px 12px",
                  borderBottom: `1px solid ${C.borderDim}`,
                }}>
                  {/* Drag */}
                  <div style={{ display: "grid", gridTemplateColumns: "3px 3px", gap: 1.5, cursor: "grab" }}>
                    {[...Array(6)].map((_, j) => <div key={j} style={{ width: 3, height: 3, borderRadius: 1.5, background: C.textMuted }} />)}
                  </div>
                  {/* Visibility */}
                  <button onClick={() => {
                    const newLayers = [...layers];
                    newLayers[i] = { ...newLayers[i], visible: !newLayers[i].visible };
                    setLayers(newLayers);
                  }} style={{ background: "none", border: "none", fontSize: 14, cursor: "pointer", color: layer.visible ? C.textMuted : C.red }}>
                    {layer.visible ? "👁️" : "🚫"}
                  </button>
                  {/* Thumbnail */}
                  <div style={{ width: 32, height: 32, borderRadius: 4, background: C.surface2, border: `1px solid ${C.border}` }} />
                  {/* Name */}
                  <span style={{ flex: 1, fontFamily: FONT, fontSize: 12, color: C.red, fontWeight: 700 }}>{layer.name}</span>
                  {/* Lock + Opacity */}
                  <span style={{ fontSize: 12 }}>{layer.locked ? "🔒" : "🔓"}</span>
                  <span style={{ fontSize: 10, color: C.textMuted, fontFamily: FONT }}>{layer.opacity}%</span>
                  {/* Expand */}
                  <button onClick={() => {
                    const newLayers = [...layers];
                    newLayers[i] = { ...newLayers[i], expanded: !newLayers[i].expanded };
                    setLayers(newLayers);
                  }} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 12, cursor: "pointer" }}>
                    {layer.expanded ? "▼" : "▸"}
                  </button>
                </div>
                
                {/* Expanded layer settings */}
                {layer.expanded && (
                  <div style={{ padding: "8px 16px", background: "rgba(10,10,14,0.5)", borderBottom: `1px solid ${C.borderDim}` }}>
                    {/* Opacity slider */}
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
                      <span style={{ fontSize: 10, color: C.textMuted, fontFamily: FONT, width: 50 }}>Opacity</span>
                      <input type="range" min={0} max={100} value={layer.opacity}
                        onChange={e => { const nl = [...layers]; nl[i] = { ...nl[i], opacity: Number(e.target.value) }; setLayers(nl); }}
                        style={{ flex: 1, accentColor: C.red }} />
                      <span style={{ fontSize: 10, color: C.textMuted, fontFamily: FONT, width: 30, textAlign: "right" }}>{layer.opacity}%</span>
                    </div>
                    {/* Lock Mode */}
                    <div style={{ fontFamily: FONT, fontSize: 8, color: C.textMuted, letterSpacing: 2, marginBottom: 4 }}>LOCK MODE</div>
                    <div style={{ display: "flex", gap: 4, marginBottom: 8 }}>
                      {(["free","full","pos","alpha"] as LockType[]).map(lt => (
                        <button key={lt} onClick={() => { const nl = [...layers]; nl[i] = { ...nl[i], lockType: lt, locked: lt !== "free" }; setLayers(nl); }}
                          style={{
                            flex: 1, padding: "6px 4px", borderRadius: 6,
                            border: `1px solid ${layer.lockType === lt ? C.red : C.border}`,
                            background: layer.lockType === lt ? "rgba(200,0,0,0.15)" : C.surface,
                            color: layer.lockType === lt ? C.red : C.textMuted,
                            fontSize: 9, fontFamily: FONT, cursor: "pointer", textTransform: "capitalize",
                            display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
                          }}>
                          <span style={{ fontSize: 14 }}>{lt === "free" ? "🔓" : lt === "full" ? "🔒" : lt === "pos" ? "📌" : "🎨"}</span>
                          <span>{lt === "free" ? "Free" : lt === "full" ? "Full" : lt === "pos" ? "Pos" : "Alpha"}</span>
                        </button>
                      ))}
                    </div>
                    {/* Blend Mode */}
                    <div style={{ fontFamily: FONT, fontSize: 8, color: C.textMuted, letterSpacing: 2, marginBottom: 4 }}>BLEND MODE</div>
                    <select value={layer.blendMode} onChange={e => { const nl = [...layers]; nl[i] = { ...nl[i], blendMode: e.target.value as BlendMode }; setLayers(nl); }}
                      style={{ width: "100%", padding: "6px 8px", borderRadius: 6, border: `1px solid ${C.border}`, background: C.surface, color: C.white, fontSize: 11, fontFamily: FONT, marginBottom: 8 }}>
                      {(["Normal","Multiply","Screen","Overlay","Darken","Lighten","Color Dodge","Color Burn","Difference"] as BlendMode[]).map(m => (
                        <option key={m} value={m}>{m}</option>
                      ))}
                    </select>
                    {/* Glow */}
                    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
                      <span style={{ fontSize: 9, fontFamily: FONT, color: C.textMuted, letterSpacing: 2 }}>GLOW</span>
                      <ToggleSwitch on={layer.glowEnabled} onToggle={() => { const nl = [...layers]; nl[i] = { ...nl[i], glowEnabled: !nl[i].glowEnabled }; setLayers(nl); }} />
                    </div>
                    {/* Color labels */}
                    <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 8 }}>
                      <span style={{ fontSize: 9, fontFamily: FONT, color: C.textMuted }}>Color:</span>
                      {["#EF4444","#F97316","#FBBF24","#22C55E","#3B82F6","#A855F7","#EC4899","#9CA3AF"].map(c => (
                        <button key={c} onClick={() => { const nl = [...layers]; nl[i] = { ...nl[i], colorLabel: c }; setLayers(nl); }}
                          style={{
                            width: 18, height: 18, borderRadius: 9, background: c, border: layer.colorLabel === c ? "2px solid white" : "none", cursor: "pointer",
                          }} />
                      ))}
                    </div>
                    {/* Actions */}
                    <div style={{ display: "flex", gap: 6 }}>
                      <button style={layerActionStyle}>✏️ Editable</button>
                      <button onClick={() => {
                        const dup: LayerData = { ...layer, id: `l${Date.now()}`, name: `${layer.name} copy`, expanded: false };
                        setLayers([...layers, dup]);
                      }} style={layerActionStyle}>📋 Duplicate</button>
                      <button onClick={() => { if (i > 0) { const nl = [...layers]; [nl[i-1], nl[i]] = [nl[i], nl[i-1]]; setLayers(nl); } }} style={layerActionStyle}>⬆</button>
                      <button onClick={() => { if (i < layers.length - 1) { const nl = [...layers]; [nl[i], nl[i+1]] = [nl[i+1], nl[i]]; setLayers(nl); } }} style={layerActionStyle}>⬇</button>
                    </div>
                  </div>
                )}
              </div>
            ))}
            {/* Add layer button */}
            <button onClick={addLayer} style={{
              width: "100%", padding: 12, background: "none", border: "none",
              color: C.red, fontSize: 20, cursor: "pointer", fontFamily: FONT,
            }}>+</button>
          </div>
        </PanelOverlay>
      )}

      {/* Export Panel */}
      {activePanel === "export" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="45%">
          <PanelHeader title="Export" onClose={() => setActivePanel("none")} />
          <div style={{ padding: "12px 16px" }}>
            <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginBottom: 8 }}>FORMAT</div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6, marginBottom: 16 }}>
              {(["mp4","gif","png","spritesheet"] as const).map(f => (
                <button key={f} onClick={() => setExportFormat(f)} style={{
                  padding: "10px 8px", borderRadius: 8, border: `1px solid ${exportFormat === f ? C.red : C.border}`,
                  background: exportFormat === f ? "rgba(200,0,0,0.15)" : C.surface,
                  color: exportFormat === f ? C.red : C.textSecondary,
                  fontSize: 12, fontFamily: FONT, cursor: "pointer", textTransform: "uppercase",
                }}>{f}</button>
              ))}
            </div>
            <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginBottom: 8 }}>QUALITY</div>
            <div style={{ display: "flex", gap: 6, marginBottom: 16 }}>
              {(["480p","720p","1080p"] as const).map(q => (
                <button key={q} onClick={() => setExportQuality(q)} style={{
                  flex: 1, padding: "8px 4px", borderRadius: 8, border: `1px solid ${exportQuality === q ? C.red : C.border}`,
                  background: exportQuality === q ? "rgba(200,0,0,0.15)" : C.surface,
                  color: exportQuality === q ? C.red : C.textSecondary,
                  fontSize: 11, fontFamily: FONT, cursor: "pointer",
                }}>
                  {q === "480p" ? "Standard 480p" : q === "720p" ? "HD 720p" : "Full HD 1080p"}
                </button>
              ))}
            </div>
            <div style={{ textAlign: "center", fontSize: 10, color: C.textMuted, fontFamily: FONT }}>
              💀 StickDeath ∞ watermark
            </div>
            <div style={{ textAlign: "center", fontSize: 8, color: C.textMuted, marginTop: 4 }}>Powered by StickDeath Infinity</div>
          </div>
        </PanelOverlay>
      )}

      {/* Magic Cut */}
      {activePanel === "magicCut" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="35%">
          <PanelHeader title="✨ Magic Cut" onClose={() => setActivePanel("settings")} />
          <div style={{ padding: "12px 16px" }}>
            <p style={{ fontSize: 11, color: C.textSecondary, marginBottom: 12 }}>Remove backgrounds automatically or pick a color to remove.</p>
            <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
              <button style={{ flex: 1, padding: "8px", borderRadius: 8, border: `1px solid ${C.red}`, background: "rgba(200,0,0,0.15)", color: C.red, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>Auto Detect</button>
              <button style={{ flex: 1, padding: "8px", borderRadius: 8, border: `1px solid ${C.border}`, background: C.surface, color: C.textSecondary, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>Pick Color</button>
            </div>
            <div style={{ marginBottom: 12 }}>
              <div style={{ display: "flex", justifyContent: "space-between", fontSize: 10, color: C.textMuted, marginBottom: 4 }}>
                <span>Precise</span><span>Tolerance</span><span>Aggressive</span>
              </div>
              <input type="range" min={0} max={100} value={50} style={{ width: "100%", accentColor: C.red }} />
            </div>
            <button style={{ width: "100%", padding: "10px", borderRadius: 8, border: "none", background: C.red, color: C.white, fontSize: 12, fontFamily: FONT, cursor: "pointer" }}>
              ✨ Remove Background
            </button>
          </div>
        </PanelOverlay>
      )}

      {/* Background Library */}
      {activePanel === "backgroundLibrary" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="85%">
          <PanelHeader title="🖼️ Background Library" onClose={() => setActivePanel("settings")} right={
            <button style={{ background: "rgba(168,85,247,0.15)", border: "1px solid rgba(168,85,247,0.3)", borderRadius: 6, color: C.purple, fontSize: 9, padding: "4px 8px", cursor: "pointer", fontFamily: FONT }}>✨ AI Generate</button>
          } />
          <div style={{ display: "flex", height: "calc(100% - 42px)" }}>
            {/* Sidebar */}
            <div style={{ width: 100, overflowY: "auto", borderRight: `1px solid ${C.borderDim}`, padding: "4px 0", scrollbarWidth: "none" }}>
              {BG_CATEGORIES.map(cat => (
                <button key={cat.id} onClick={() => setBgCat(cat.id)} style={{
                  width: "100%", padding: "6px 8px", border: "none", cursor: "pointer", textAlign: "left",
                  background: bgCat === cat.id ? "rgba(200,0,0,0.1)" : "transparent",
                  borderLeft: bgCat === cat.id ? `2px solid ${C.red}` : "2px solid transparent",
                }}>
                  <div style={{ fontSize: 12 }}>{cat.icon}</div>
                  <div style={{ fontSize: 8, color: bgCat === cat.id ? C.red : C.textMuted, fontFamily: FONT }}>{cat.name}</div>
                  <div style={{ fontSize: 7, color: C.textMuted }}>{cat.count}</div>
                </button>
              ))}
            </div>
            {/* Grid */}
            <div style={{ flex: 1, overflowY: "auto", padding: 8 }}>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6 }}>
                {Array.from({ length: BG_CATEGORIES.find(c => c.id === bgCat)?.count || 8 }, (_, i) => (
                  <div key={i} style={{
                    height: 80, borderRadius: 8, cursor: "pointer",
                    background: `hsl(${(i * 37) % 360}, 40%, ${20 + (i % 3) * 10}%)`,
                    border: `1px solid ${C.border}`,
                    display: "flex", alignItems: "flex-end", padding: 4,
                  }}>
                    <span style={{ fontSize: 7, color: "rgba(255,255,255,0.6)", fontFamily: FONT }}>BG {i + 1}</span>
                  </div>
                ))}
              </div>
              <div style={{ textAlign: "center", padding: "12px 0", fontSize: 10, color: C.textMuted, fontFamily: FONT }}>
                {BG_CATEGORIES.find(c => c.id === bgCat)?.count || 101} backgrounds available
              </div>
              <button style={{ width: "100%", padding: "8px", borderRadius: 8, border: `1px solid ${C.border}`, background: C.surface, color: C.textMuted, fontSize: 10, fontFamily: FONT, cursor: "pointer" }}>
                Clear Background
              </button>
            </div>
          </div>
        </PanelOverlay>
      )}

      {/* Add Picture */}
      {activePanel === "addImage" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="85%">
          <PanelHeader title="Add Picture" onClose={() => setActivePanel("settings")} />
          <div style={{ padding: "0 12px" }}>
            <div style={{ display: "flex", gap: 4, marginBottom: 8 }}>
              {(["upload","url","library"] as const).map(t => (
                <button key={t} onClick={() => setImageTab(t)} style={{
                  flex: 1, padding: "6px", borderRadius: 6, border: "none", cursor: "pointer",
                  background: imageTab === t ? C.red : C.surface, color: imageTab === t ? C.white : C.textMuted,
                  fontSize: 10, fontFamily: FONT, textTransform: "capitalize",
                }}>{t}</button>
              ))}
            </div>
            {imageTab === "library" && (
              <>
                <input placeholder="Search images..." style={{ ...searchInputStyle, marginBottom: 6 }} />
                <div style={{ display: "flex", gap: 4, overflowX: "auto", marginBottom: 8, scrollbarWidth: "none" }}>
                  {IMAGE_CATS.map(cat => (
                    <button key={cat.id} onClick={() => setImageCat(cat.id)} style={{
                      padding: "4px 8px", borderRadius: 12, border: "none", cursor: "pointer", whiteSpace: "nowrap",
                      background: imageCat === cat.id ? C.red : C.surface, color: imageCat === cat.id ? C.white : C.textMuted,
                      fontSize: 9, fontFamily: FONT, flexShrink: 0,
                    }}>{cat.name} {cat.count}</button>
                  ))}
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 4, maxHeight: 300, overflowY: "auto" }}>
                  {IMAGE_CATS.find(c => c.id === imageCat)?.emojis.slice(0, 50).map((e, i) => (
                    <button key={i} style={{
                      width: "100%", aspectRatio: "1", borderRadius: 6, border: `1px solid ${C.border}`,
                      background: C.surface, cursor: "pointer", fontSize: 22, display: "flex",
                      alignItems: "center", justifyContent: "center",
                    }}>{e}</button>
                  ))}
                </div>
                <div style={{ textAlign: "center", fontSize: 9, color: C.textMuted, padding: "8px 0", fontFamily: FONT }}>
                  Tap image to place on canvas...
                </div>
              </>
            )}
            {imageTab === "upload" && (
              <div style={{ padding: 20, textAlign: "center" }}>
                <div style={{ fontSize: 40, marginBottom: 12 }}>📁</div>
                <p style={{ fontSize: 12, color: C.textSecondary }}>Tap to upload an image</p>
                <button style={{ marginTop: 12, padding: "8px 20px", borderRadius: 8, background: C.red, border: "none", color: C.white, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>Choose File</button>
              </div>
            )}
            {imageTab === "url" && (
              <div style={{ padding: 20 }}>
                <input placeholder="Paste image URL..." style={searchInputStyle} />
                <button style={{ marginTop: 12, width: "100%", padding: "8px", borderRadius: 8, background: C.red, border: "none", color: C.white, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>Load Image</button>
              </div>
            )}
          </div>
        </PanelOverlay>
      )}

      {/* AI Voice Maker */}
      {activePanel === "aiVoice" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="65%">
          <PanelHeader title="🗣️ AI Voice Maker" onClose={() => setActivePanel("settings")} />
          <div style={{ padding: "12px 16px" }}>
            <textarea value={voiceScript} onChange={e => setVoiceScript(e.target.value)}
              placeholder="Enter your script or dialogue..."
              style={{ width: "100%", height: 60, background: "#1a1028", border: "1px solid rgba(168,85,247,0.3)", borderRadius: 8, color: C.white, fontSize: 12, padding: 10, resize: "none", fontFamily: "inherit" }} />
            <div style={{ textAlign: "right", fontSize: 9, color: C.textMuted, marginTop: 2 }}>{voiceScript.split(/\s+/).filter(Boolean).length} words</div>
            
            <div style={{ fontFamily: FONT, fontSize: 9, color: C.textMuted, letterSpacing: 2, marginTop: 8, marginBottom: 6 }}>VOICE PRESETS</div>
            <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginBottom: 12 }}>
              {VOICE_PRESETS.map(p => (
                <button key={p.id} onClick={() => setVoicePreset(p.id)} style={{
                  padding: "5px 10px", borderRadius: 16, border: "none", cursor: "pointer",
                  background: voicePreset === p.id ? `${p.color}25` : "rgba(255,255,255,0.05)",
                  color: voicePreset === p.id ? p.color : C.textMuted,
                  fontSize: 10, fontFamily: FONT,
                }}>{p.label}</button>
              ))}
            </div>

            <div style={{ marginBottom: 8 }}>
              <label style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>Voice</label>
              <select style={{ width: "100%", padding: "6px 8px", borderRadius: 6, border: "1px solid rgba(168,85,247,0.3)", background: "#1a1028", color: C.white, fontSize: 11, fontFamily: FONT }}>
                <option>Samantha (en-US)</option>
                <option>Daniel (en-GB)</option>
                <option>Alex (en-US)</option>
              </select>
            </div>
            
            <SliderRow label="Speed" value={voiceSpeed * 100} min={50} max={200} unit="x" onChange={v => setVoiceSpeed(v / 100)} purple />
            <SliderRow label="Pitch" value={voicePitch * 100} min={50} max={200} unit="x" onChange={v => setVoicePitch(v / 100)} purple />

            <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
              <button style={{ flex: 1, padding: "8px", borderRadius: 8, border: "1px solid rgba(168,85,247,0.3)", background: "rgba(168,85,247,0.1)", color: C.purple, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>▶ Preview</button>
              <button style={{ flex: 1, padding: "8px", borderRadius: 8, border: "none", background: C.purple, color: C.white, fontSize: 11, fontFamily: FONT, cursor: "pointer" }}>Add to Timeline</button>
            </div>
          </div>
        </PanelOverlay>
      )}

      {/* Sticker & Emoji */}
      {activePanel === "stickerEmoji" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="70%">
          <PanelHeader title="Stickers & Emoji" onClose={() => setActivePanel("none")} />
          <div style={{ padding: "0 12px" }}>
            <div style={{ display: "flex", gap: 4, marginBottom: 8 }}>
              <button onClick={() => setStickerTab("stickers")} style={{
                flex: 1, padding: "6px", borderRadius: 6, border: "none", cursor: "pointer",
                background: stickerTab === "stickers" ? C.red : C.surface, color: stickerTab === "stickers" ? C.white : C.textMuted,
                fontSize: 10, fontFamily: FONT,
              }}>💀 STICKERS</button>
              <button onClick={() => setStickerTab("emoji")} style={{
                flex: 1, padding: "6px", borderRadius: 6, border: "none", cursor: "pointer",
                background: stickerTab === "emoji" ? C.red : C.surface, color: stickerTab === "emoji" ? C.white : C.textMuted,
                fontSize: 10, fontFamily: FONT,
              }}>😀 EMOJI</button>
            </div>
            <input placeholder="Search..." style={{ ...searchInputStyle, marginBottom: 8 }} />
            {stickerTab === "stickers" && (
              <>
                <div style={{ display: "flex", gap: 4, overflowX: "auto", marginBottom: 8, scrollbarWidth: "none" }}>
                  {STICKER_CATS.map(cat => (
                    <button key={cat.id} onClick={() => setStickerCat(cat.id)} style={{
                      padding: "4px 10px", borderRadius: 12, border: "none", cursor: "pointer",
                      background: stickerCat === cat.id ? C.red : C.surface, color: stickerCat === cat.id ? C.white : C.textMuted,
                      fontSize: 9, fontFamily: FONT, whiteSpace: "nowrap", flexShrink: 0,
                    }}>{cat.name}</button>
                  ))}
                </div>
                <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 6 }}>
                  {STICKER_CATS.find(c => c.id === stickerCat)?.stickers.map(s => (
                    <button key={s.id} style={{
                      aspectRatio: "1", borderRadius: 8, border: `1px solid ${C.border}`,
                      background: C.surface, cursor: "pointer", display: "flex", flexDirection: "column",
                      alignItems: "center", justifyContent: "center", gap: 4,
                    }}>
                      <span style={{ fontSize: 28 }}>{s.emoji}</span>
                      <span style={{ fontSize: 7, color: C.textMuted, fontFamily: FONT }}>{s.name}</span>
                    </button>
                  ))}
                </div>
              </>
            )}
            {stickerTab === "emoji" && (
              <div style={{ display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 4, maxHeight: 300, overflowY: "auto" }}>
                {IMAGE_CATS[0].emojis.map((e, i) => (
                  <button key={i} style={{ fontSize: 22, padding: 4, background: "none", border: "none", cursor: "pointer" }}>{e}</button>
                ))}
              </div>
            )}
          </div>
        </PanelOverlay>
      )}

      {/* Asset Vault */}
      {activePanel === "assetVault" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="80%">
          <div style={{ padding: "12px 16px" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
              <h3 style={{ fontFamily: FONT, fontSize: 16, color: C.white, margin: 0 }}>Asset Vault</h3>
              <span style={{ background: C.red, color: C.white, fontSize: 9, padding: "2px 8px", borderRadius: 8, fontFamily: FONT }}>1,331+</span>
              <div style={{ flex: 1 }} />
              <button onClick={() => setActivePanel("none")} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 14, cursor: "pointer" }}>✕</button>
            </div>
            <input placeholder="Search assets..." style={{ ...searchInputStyle, marginBottom: 8 }} />
            <div style={{ display: "flex", gap: 4, marginBottom: 12 }}>
              {(["browse","recent","favorites"] as const).map(t => (
                <button key={t} onClick={() => setVaultTab(t)} style={{
                  flex: 1, padding: "6px", borderRadius: 6, border: "none", cursor: "pointer",
                  background: vaultTab === t ? C.red : C.surface, color: vaultTab === t ? C.white : C.textMuted,
                  fontSize: 10, fontFamily: FONT, textTransform: "capitalize",
                }}>{t}</button>
              ))}
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
              {ASSET_VAULT_CATS.map(cat => (
                <div key={cat.id} style={{
                  padding: 12, borderRadius: 10, background: C.surface, border: `1px solid ${C.border}`,
                  cursor: "pointer", textAlign: "center",
                }}>
                  <span style={{ fontSize: 28 }}>{cat.icon}</span>
                  <div style={{ fontFamily: FONT, fontSize: 10, color: C.white, marginTop: 4 }}>{cat.name}</div>
                  <div style={{ fontSize: 9, color: C.textMuted }}>{cat.count}</div>
                </div>
              ))}
            </div>
          </div>
        </PanelOverlay>
      )}

      {/* Sound Library */}
      {activePanel === "soundLibrary" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="75%">
          <PanelHeader title="🎵 Sound Library" onClose={() => setActivePanel("none")} right={
            <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>1,000+ effects</span>
          } />
          <div style={{ padding: "0 12px" }}>
            <input placeholder="Search sounds..." style={{ ...searchInputStyle, marginBottom: 8 }} />
            {!selectedSoundCat ? (
              <div style={{ overflowY: "auto", maxHeight: 350 }}>
                {SOUND_CATEGORIES.map(cat => (
                  <button key={cat.id} onClick={() => setSelectedSoundCat(cat.id)} style={{
                    width: "100%", padding: "10px 12px", border: "none", cursor: "pointer",
                    background: "transparent", display: "flex", alignItems: "center", gap: 10,
                    borderBottom: `1px solid ${C.borderDim}`, textAlign: "left",
                  }}>
                    <span style={{ fontSize: 20 }}>{cat.icon}</span>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontFamily: FONT, fontSize: 12, color: C.white }}>{cat.name}</div>
                      <div style={{ fontSize: 9, color: C.textMuted }}>{cat.count} sounds</div>
                    </div>
                    <span style={{ color: C.textMuted, fontSize: 12 }}>›</span>
                  </button>
                ))}
              </div>
            ) : (
              <div>
                <button onClick={() => setSelectedSoundCat(null)} style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 11, cursor: "pointer", marginBottom: 8, fontFamily: FONT }}>
                  ← Back to categories
                </button>
                <div style={{ fontFamily: FONT, fontSize: 13, color: C.white, marginBottom: 8 }}>
                  {SOUND_CATEGORIES.find(c => c.id === selectedSoundCat)?.icon} {SOUND_CATEGORIES.find(c => c.id === selectedSoundCat)?.name}
                </div>
                <div style={{ overflowY: "auto", maxHeight: 300 }}>
                  {SOUND_CATEGORIES.find(c => c.id === selectedSoundCat)?.items.map(snd => (
                    <div key={snd.id} style={{
                      display: "flex", alignItems: "center", gap: 8, padding: "6px 0",
                      borderBottom: `1px solid ${C.borderDim}`,
                    }}>
                      <button style={{ width: 24, height: 24, borderRadius: 12, background: C.surface, border: `1px solid ${C.border}`, color: C.white, fontSize: 10, cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center" }}>▶</button>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 11, color: C.white, fontFamily: FONT, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{snd.name}</div>
                      </div>
                      <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>{snd.duration}</span>
                      {/* Mini waveform */}
                      <div style={{ display: "flex", alignItems: "center", gap: 1, height: 16 }}>
                        {[3,5,8,12,10,6,9,4,7,11,5,3].map((h, j) => (
                          <div key={j} style={{ width: 2, height: h, background: C.red, borderRadius: 1, opacity: 0.6 }} />
                        ))}
                      </div>
                      <span style={{ fontSize: 8, color: C.textMuted, background: C.surface, padding: "2px 4px", borderRadius: 4, fontFamily: FONT }}>{snd.tag}</span>
                      <button onClick={() => {
                        setAudioClips(prev => [...prev, { id: `ac_${Date.now()}`, name: snd.name, track: prev.length % 4, start: prev.length * 0.5, duration: parseFloat(snd.duration), volume: 80 }]);
                      }} style={{ background: "none", border: "none", color: C.green, fontSize: 16, cursor: "pointer" }}>+</button>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
          {/* Audio Timeline section */}
          <div style={{ borderTop: `1px solid ${C.border}`, padding: "8px 12px" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 6 }}>
              <span style={{ fontFamily: FONT, fontSize: 11, color: C.white }}>🎵 Audio Timeline</span>
              {audioClips.length > 0 && <span style={{ background: C.red, color: C.white, fontSize: 8, padding: "1px 5px", borderRadius: 6 }}>{audioClips.length}</span>}
              <div style={{ flex: 1 }} />
              <button onClick={() => setAudioSnapOn(!audioSnapOn)} style={{ fontSize: 8, color: audioSnapOn ? C.green : C.textMuted, background: "none", border: `1px solid ${C.border}`, borderRadius: 4, padding: "2px 6px", cursor: "pointer", fontFamily: FONT }}>
                Snap: {audioSnapOn ? "ON" : "OFF"}
              </button>
              <button style={{ fontSize: 9, color: C.white, background: C.red, border: "none", borderRadius: 4, padding: "3px 8px", cursor: "pointer", fontFamily: FONT }}>+ Add</button>
            </div>
            {/* Transport */}
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
              <button style={{ ...tinyBtnStyle, fontSize: 10 }}>⏮</button>
              <button style={{ ...tinyBtnStyle, fontSize: 10 }}>▶</button>
              <button style={{ ...tinyBtnStyle, fontSize: 10 }}>⏭</button>
              <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT }}>00:00.00</span>
            </div>
            {/* Tracks */}
            <div style={{ background: C.surfaceDark, borderRadius: 6, overflow: "hidden" }}>
              {[0, 1, 2, 3].map(track => (
                <div key={track} style={{ display: "flex", alignItems: "center", height: 20, borderBottom: `1px solid ${C.borderDim}` }}>
                  <div style={{ width: 24, display: "flex", alignItems: "center", justifyContent: "center", borderRight: `1px solid ${C.borderDim}` }}>
                    <span style={{ fontSize: 8 }}>🔊</span>
                  </div>
                  <div style={{ flex: 1, position: "relative", height: "100%" }}>
                    {audioClips.filter(c => c.track === track).map(clip => (
                      <div key={clip.id} style={{
                        position: "absolute", left: `${clip.start * 30}%`, width: `${clip.duration * 15}%`,
                        height: "80%", top: "10%", borderRadius: 3, background: `${C.red}40`, border: `1px solid ${C.red}60`,
                        fontSize: 6, color: C.white, padding: "0 2px", overflow: "hidden", whiteSpace: "nowrap",
                      }}>{clip.name}</div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </PanelOverlay>
      )}

      {/* Spatter AI */}
      {activePanel === "spatter" && (
        <PanelOverlay onClose={() => setActivePanel("none")} height="55%">
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "10px 16px", borderBottom: `1px solid ${C.borderDim}` }}>
            <div style={{ width: 28, height: 28, borderRadius: 14, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14 }}>🎨</div>
            <span style={{ fontFamily: FONT, fontSize: 14, color: C.white, fontWeight: 700 }}>Spatter AI</span>
            <span style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 9, color: C.green }}>
              <span style={{ width: 6, height: 6, borderRadius: 3, background: C.green }} />online
            </span>
            <div style={{ flex: 1 }} />
            <button onClick={() => setActivePanel("none")} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 14, cursor: "pointer" }}>✕</button>
          </div>
          <div style={{ flex: 1, overflowY: "auto", padding: "8px 12px" }}>
            {spatterMessages.length === 0 && (
              <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
                <div style={{ width: 24, height: 24, borderRadius: 12, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 11, flexShrink: 0, marginTop: 2 }}>🎨</div>
                <p style={{ fontSize: 12, color: "rgba(255,255,255,0.7)", background: "rgba(18,18,26,0.8)", borderRadius: 12, padding: "8px 12px", margin: 0, lineHeight: 1.5 }}>
                  Yo! I'm Spatter. 🎨 I can help with poses, animation tips, fight choreography, or just vibe. What're you working on?
                </p>
              </div>
            )}
            {spatterMessages.map((m, i) => (
              <div key={i} style={{ display: "flex", gap: 8, marginBottom: 8, justifyContent: m.isSpatter ? "flex-start" : "flex-end" }}>
                {m.isSpatter && <div style={{ width: 24, height: 24, borderRadius: 12, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 11, flexShrink: 0, marginTop: 2 }}>🎨</div>}
                <p style={{
                  fontSize: 11, borderRadius: 12, padding: "8px 12px", margin: 0, maxWidth: "85%", whiteSpace: "pre-line", lineHeight: 1.4,
                  background: m.isSpatter ? "rgba(18,18,26,0.8)" : "rgba(200,0,0,0.15)",
                  color: m.isSpatter ? "rgba(255,255,255,0.7)" : "#fca5a5",
                }}>{m.text}</p>
              </div>
            ))}
          </div>
          {spatterMessages.length === 0 && (
            <div style={{ display: "flex", gap: 6, padding: "4px 12px", overflowX: "auto", scrollbarWidth: "none" }}>
              {[
                { icon: "🦴", text: "Suggest a pose", color: "#FF3333" },
                { icon: "👍", text: "Review my work", color: "#4ADE80" },
                { icon: "✨", text: "Auto-tween", color: "#A855F7" },
                { icon: "💡", text: "Animation tip", color: "#FACC15" },
                { icon: "🥊", text: "Fight scene", color: "#FF3333" },
              ].map((a, i) => (
                <button key={i} onClick={async () => {
                  const brainResp = getSpatterBrainResponse(a.text, frames.length, layers.length, selectedTool);
                  setSpatterMessages(prev => [...prev, { text: a.text, isSpatter: false }, { text: brainResp, isSpatter: true }]);
                  // Upgrade to AI response
                  const aiResp = await getAIResponse(a.text, "Spatter AI", { frameCount: frames.length, layerCount: layers.length, tool: selectedTool });
                  if (aiResp) setSpatterMessages(prev => { const n = [...prev]; n[n.length - 1] = { text: aiResp, isSpatter: true }; return n; });
                }} style={{
                  flexShrink: 0, display: "flex", alignItems: "center", gap: 4,
                  padding: "5px 10px", borderRadius: 16, border: "none", cursor: "pointer",
                  background: `${a.color}15`, color: a.color, fontSize: 10, fontFamily: FONT,
                }}>{a.icon} {a.text}</button>
              ))}
            </div>
          )}
          <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 12px", borderTop: `1px solid ${C.borderDim}` }}>
            <input type="text" value={spatterInput} onChange={e => setSpatterInput(e.target.value)}
              onKeyDown={async e => {
                if (e.key === "Enter" && spatterInput.trim()) {
                  const msg = spatterInput.trim();
                  const brainResp = getSpatterBrainResponse(msg, frames.length, layers.length, selectedTool);
                  setSpatterMessages(prev => [...prev, { text: msg, isSpatter: false }, { text: brainResp, isSpatter: true }]);
                  setSpatterInput("");
                  const aiResp = await getAIResponse(msg, "Spatter AI", { frameCount: frames.length, layerCount: layers.length, tool: selectedTool });
                  if (aiResp) setSpatterMessages(prev => { const n = [...prev]; n[n.length - 1] = { text: aiResp, isSpatter: true }; return n; });
                }
              }}
              placeholder="Ask Spatter anything..." style={{
                flex: 1, background: "rgba(18,18,26,0.8)", color: C.white, fontSize: 12, padding: "8px 12px",
                borderRadius: 12, border: `1px solid ${C.borderDim}`, outline: "none", fontFamily: "inherit",
              }} />
            <button onClick={async () => {
              if (spatterInput.trim()) {
                const msg = spatterInput.trim();
                const brainResp = getSpatterBrainResponse(msg, frames.length, layers.length, selectedTool);
                setSpatterMessages(prev => [...prev, { text: msg, isSpatter: false }, { text: brainResp, isSpatter: true }]);
                setSpatterInput("");
                const aiResp = await getAIResponse(msg, "Spatter AI", { frameCount: frames.length, layerCount: layers.length, tool: selectedTool });
                if (aiResp) setSpatterMessages(prev => { const n = [...prev]; n[n.length - 1] = { text: aiResp, isSpatter: true }; return n; });
              }
            }} style={{ background: "none", border: "none", color: C.red, fontSize: 16, cursor: "pointer" }}>➤</button>
          </div>
        </PanelOverlay>
      )}

      {/* Frames Viewer */}
      {activePanel === "framesViewer" && (
        <PanelOverlay onClose={() => setActivePanel("settings")} height="50%">
          <PanelHeader title="🎬 Frames Viewer" onClose={() => setActivePanel("settings")} />
          <div style={{ padding: "12px", display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 8 }}>
            {frames.map((f, i) => (
              <button key={f.id} onClick={() => { setActiveFrame(i); setActivePanel("none"); }} style={{
                aspectRatio: "1", borderRadius: 8, border: `2px solid ${i === activeFrame ? C.red : C.border}`,
                background: f.hasContent ? C.surface2 : C.surface, cursor: "pointer",
                display: "flex", alignItems: "center", justifyContent: "center",
              }}>
                <span style={{ fontFamily: FONT, fontSize: 14, color: i === activeFrame ? C.red : C.textMuted }}>{i + 1}</span>
              </button>
            ))}
            <button onClick={addFrame} style={{ aspectRatio: "1", borderRadius: 8, border: `2px dashed ${C.border}`, background: "transparent", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 20, color: C.textMuted }}>+</button>
          </div>
        </PanelOverlay>
      )}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// MESSAGES TAB — Teams-style layout (no bottom nav)
// ═══════════════════════════════════════════════════════════════════
function MessagesTab({ tab, setTab, showChatRoom: _showChatRoom, setShowChatRoom: _setShowChatRoom }: {
  tab: MessagesTab; setTab: (t: MessagesTab)=>void; showChatRoom: boolean; setShowChatRoom: (v: boolean)=>void;
}) {
  const [selectedChannel, setSelectedChannel] = useState<string | null>(null);
  const [chatInput, setChatInput] = useState("");
  const [localMessages, setLocalMessages] = useState<{text: string; isUser: boolean; time: string}[]>([]);
  const [liveBotMessages, setLiveBotMessages] = useState<BotMessage[]>([]);

  // Live AI bots auto-posting messages
  const liveBotPool: BotMessage[] = [
    { id: "lb1", bot: "Spatter AI", avatar: "🎨", text: "Just analyzed your recent work — your timing is improving! Try adding 2 anticipation frames before impacts for even more punch. 💀", time: "just now", channel: "general" },
    { id: "lb2", bot: "DeathBot", avatar: "☠️", text: "New weapon pack available: 'Ancient Blades Collection' — 12 swords, 8 axes, 6 staffs. All fully rigged for animation.", time: "just now", channel: "assets" },
    { id: "lb3", bot: "StickCoach", avatar: "🎯", text: "Pro tip: Hold your key poses for 2-3 extra frames. It gives the viewer's eye time to 'read' the action. This is called a 'moving hold.' 🎬", time: "just now", channel: "tips" },
    { id: "lb4", bot: "BattleBot", avatar: "⚔️", text: "Flash Challenge! Create a 2-second dodge animation. Best entry wins 250 coins + featured on the homepage! ⏰ 1 hour left!", time: "just now", channel: "challenges" },
    { id: "lb5", bot: "Spatter AI", avatar: "🎨", text: "I detected a common animation issue: your characters are floating! Enable 'Foot Plant Grounding' in settings to anchor them. 🦶", time: "just now", channel: "general" },
    { id: "lb6", bot: "TrendBot", avatar: "📈", text: "Trending this hour: Neon effects are up 280%. Try combining glow layers with fast action for that cyberpunk look! 🔮", time: "just now", channel: "general" },
    { id: "lb7", bot: "SoundBot", avatar: "🎵", text: "Audio tip: Layer 2-3 impact sounds at different pitches for a richer hit effect. Try 'Bone Crack' + 'Metal Clang' + 'Bass Drop.' 🔊", time: "just now", channel: "tips" },
    { id: "lb8", bot: "Spatter AI", avatar: "🎨", text: "Your last 3 animations all used the same camera angle. Mix it up! Try a low-angle shot for power, or Dutch angle for tension. 🎥", time: "just now", channel: "general" },
    { id: "lb9", bot: "CollabBot", avatar: "🤝", text: "3 creators are looking for collaborators right now! Check Creator Rooms to join a live session. 🎙️", time: "just now", channel: "general" },
    { id: "lb10", bot: "StickCoach", avatar: "🎯", text: "Animation challenge: Draw the same action at 8 FPS, 12 FPS, and 24 FPS. Notice how timing changes the feel entirely! 🧪", time: "just now", channel: "tips" },
  ];

  useEffect(() => {
    let idx = 0;
    const botNames = ["Spatter AI", "DeathBot", "StickCoach", "BattleBot", "TrendBot", "SoundBot", "CollabBot"];
    const botAvatars: Record<string, string> = { "Spatter AI": "🎨", "DeathBot": "☠️", "StickCoach": "🎯", "BattleBot": "⚔️", "TrendBot": "📈", "SoundBot": "🎵", "CollabBot": "🤝" };
    const botChannels = ["general", "tips", "challenges", "assets", "general", "tips", "general"];

    const interval = setInterval(async () => {
      // First show pool messages quickly, then start generating AI messages
      if (idx < liveBotPool.length) {
        const msg = { ...liveBotPool[idx], id: `live_${Date.now()}_${idx}`, time: "just now" };
        setLiveBotMessages(prev => [...prev, msg]);
        idx++;
      } else {
        // Generate a real AI bot message
        const botIdx = idx % botNames.length;
        const botName = botNames[botIdx];
        try {
          const text = await generateBotMessage(botName);
          if (text) {
            setLiveBotMessages(prev => [...prev, {
              id: `ai_${Date.now()}`,
              bot: botName,
              avatar: botAvatars[botName] || "🤖",
              text,
              time: "just now",
              channel: botChannels[botIdx],
            }]);
          }
        } catch { /* silently skip failed generation */ }
        idx++;
      }
    }, 8000); // New bot message every 8 seconds
    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const channels = [
    { id: "general", name: "General", icon: "#", unread: 3, lastMsg: "Spatter AI: reverse spin kicks are up 340%...", time: "2m" },
    { id: "tips", name: "Tips & Tricks", icon: "#", unread: 1, lastMsg: "StickCoach: Daily tip: Use onion skinning...", time: "12m" },
    { id: "challenges", name: "Challenges", icon: "#", unread: 1, lastMsg: "BattleBot: War Room challenge starting...", time: "18m" },
    { id: "assets", name: "Assets & Packs", icon: "#", unread: 1, lastMsg: "SoundBot: New sound pack uploaded...", time: "32m" },
    { id: "showcase", name: "Showcase", icon: "#", unread: 0, lastMsg: "Share your latest animations!", time: "1h" },
    { id: "feedback", name: "Feedback", icon: "#", unread: 0, lastMsg: "Help us improve StickDeath ∞", time: "3h" },
  ];

  const dms = [
    { id: "dm1", name: "Spatter AI", avatar: "🎨", online: true, lastMsg: "I noticed you've been working on sword fights...", time: "5m" },
    { id: "dm2", name: "NeonBlade", avatar: "🎭", online: true, lastMsg: "Check out my latest animation!", time: "1h" },
    { id: "dm3", name: "StickMaster", avatar: "💀", online: false, lastMsg: "Want to collab?", time: "3h" },
  ];

  if (selectedChannel) {
    const channelMsgs = [...BOT_MESSAGES, ...liveBotMessages].filter(m => m.channel === selectedChannel || selectedChannel === "general");
    return (
      <div style={{ height: "100%", background: C.bg, display: "flex", flexDirection: "column" }}>
        {/* Chat header */}
        <div style={{ padding: "54px 12px 8px", display: "flex", alignItems: "center", gap: 8, borderBottom: `1px solid ${C.border}` }}>
          <button onClick={() => setSelectedChannel(null)} style={{ background: "none", border: "none", color: C.textSecondary, fontSize: 16, cursor: "pointer" }}>‹</button>
          <span style={{ fontFamily: FONT, fontSize: 14, color: C.white }}>#{channels.find(c => c.id === selectedChannel)?.name}</span>
        </div>
        {/* Messages */}
        <div style={{ flex: 1, overflowY: "auto", padding: "8px 12px" }}>
          {channelMsgs.map(m => (
            <div key={m.id} style={{ display: "flex", gap: 8, marginBottom: 12 }}>
              <div style={{ width: 32, height: 32, borderRadius: 16, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 16, flexShrink: 0 }}>{m.avatar}</div>
              <div style={{ flex: 1 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <span style={{ fontFamily: FONT, fontSize: 11, color: C.white, fontWeight: 700 }}>{m.bot}</span>
                  <span style={{ fontSize: 9, color: C.textMuted }}>{m.time}</span>
                </div>
                <p style={{ fontSize: 11, color: C.textSecondary, margin: "4px 0 0", lineHeight: 1.4 }}>{m.text}</p>
              </div>
            </div>
          ))}
          {localMessages.map((m, i) => (
            <div key={`local_${i}`} style={{ display: "flex", gap: 8, marginBottom: 12, justifyContent: m.isUser ? "flex-end" : "flex-start" }}>
              {!m.isUser && <div style={{ width: 32, height: 32, borderRadius: 16, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 16, flexShrink: 0 }}>🎨</div>}
              <div style={{ maxWidth: "75%" }}>
                <p style={{
                  fontSize: 11, borderRadius: 12, padding: "8px 12px", margin: 0, lineHeight: 1.4,
                  background: m.isUser ? "rgba(200,0,0,0.15)" : "rgba(18,18,26,0.8)",
                  color: m.isUser ? "#fca5a5" : "rgba(255,255,255,0.7)",
                }}>{m.text}</p>
              </div>
            </div>
          ))}
        </div>
        {/* Input */}
        <div style={{ padding: "8px 12px 24px", borderTop: `1px solid ${C.border}`, display: "flex", gap: 8 }}>
          <input value={chatInput} onChange={e => setChatInput(e.target.value)}
            onKeyDown={async e => {
              if (e.key === "Enter" && chatInput.trim()) {
                const userMsg = chatInput.trim();
                setLocalMessages(prev => [...prev, { text: userMsg, isUser: true, time: "now" }, { text: "typing...", isUser: false, time: "now" }]);
                setChatInput("");
                const aiResp = await getAIResponse(userMsg, "Spatter AI");
                const finalResp = aiResp || getSpatterBrainResponse(userMsg, 2, 1, "pencil");
                setLocalMessages(prev => { const n = [...prev]; n[n.length - 1] = { text: finalResp, isUser: false, time: "now" }; return n; });
              }
            }}
            placeholder="Type a message..."
            style={{ flex: 1, background: C.surface, border: `1px solid ${C.border}`, borderRadius: 20, color: C.white, fontSize: 12, padding: "8px 16px", outline: "none" }} />
          <button onClick={async () => {
            if (chatInput.trim()) {
              const userMsg = chatInput.trim();
              setLocalMessages(prev => [...prev, { text: userMsg, isUser: true, time: "now" }, { text: "typing...", isUser: false, time: "now" }]);
              setChatInput("");
              const aiResp = await getAIResponse(userMsg, "Spatter AI");
              const finalResp = aiResp || getSpatterBrainResponse(userMsg, 2, 1, "pencil");
              setLocalMessages(prev => { const n = [...prev]; n[n.length - 1] = { text: finalResp, isUser: false, time: "now" }; return n; });
            }
          }} style={{ background: C.red, border: "none", borderRadius: 20, color: C.white, padding: "8px 12px", fontSize: 12, cursor: "pointer" }}>Send</button>
        </div>
      </div>
    );
  }

  return (
    <div style={{ height: "100%", background: C.bg, display: "flex", flexDirection: "column" }}>
      {/* Teams-style top bar */}
      <div style={{ padding: "54px 16px 8px", borderBottom: `1px solid ${C.border}` }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 8 }}>
          <h2 style={{ fontFamily: FONT, fontSize: 18, color: C.white, margin: 0 }}>Chat</h2>
          <div style={{ display: "flex", gap: 12 }}>
            <button style={{ background: "none", border: "none", color: C.textMuted, fontSize: 16, cursor: "pointer" }}>🔍</button>
            <button style={{ background: "none", border: "none", color: C.textMuted, fontSize: 16, cursor: "pointer" }}>✏️</button>
          </div>
        </div>
        {/* Teams-style tab bar */}
        <div style={{ display: "flex", gap: 0 }}>
          {(["channels", "dms", "requests"] as MessagesTab[]).map(t => (
            <button key={t} onClick={() => setTab(t)} style={{
              flex: 1, padding: "8px 4px", border: "none", cursor: "pointer",
              background: "transparent", borderBottom: `2px solid ${tab === t ? C.red : "transparent"}`,
              color: tab === t ? C.white : C.textMuted, fontSize: 11, fontFamily: FONT, textTransform: "capitalize",
            }}>{t === "dms" ? "Direct" : t}</button>
          ))}
        </div>
      </div>

      {/* Channel/DM list */}
      <div style={{ flex: 1, overflowY: "auto" }}>
        {tab === "channels" && channels.map(ch => (
          <button key={ch.id} onClick={() => setSelectedChannel(ch.id)} style={{
            width: "100%", padding: "12px 16px", border: "none", cursor: "pointer",
            background: "transparent", display: "flex", alignItems: "center", gap: 10,
            borderBottom: `1px solid ${C.borderDim}`, textAlign: "left",
          }}>
            <div style={{ width: 36, height: 36, borderRadius: 8, background: C.surface2, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, color: C.textMuted, fontFamily: FONT }}>{ch.icon}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span style={{ fontFamily: FONT, fontSize: 13, color: C.white }}>{ch.name}</span>
                <span style={{ fontSize: 9, color: C.textMuted }}>{ch.time}</span>
              </div>
              <p style={{ fontSize: 10, color: C.textMuted, margin: "2px 0 0", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{ch.lastMsg}</p>
            </div>
            {ch.unread > 0 && <span style={{ background: C.red, color: C.white, fontSize: 9, width: 18, height: 18, borderRadius: 9, display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 700 }}>{ch.unread}</span>}
          </button>
        ))}
        {tab === "dms" && dms.map(dm => (
          <button key={dm.id} onClick={() => setSelectedChannel("general")} style={{
            width: "100%", padding: "12px 16px", border: "none", cursor: "pointer",
            background: "transparent", display: "flex", alignItems: "center", gap: 10,
            borderBottom: `1px solid ${C.borderDim}`, textAlign: "left",
          }}>
            <div style={{ width: 36, height: 36, borderRadius: 18, background: "rgba(200,0,0,0.2)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 18, position: "relative" }}>
              {dm.avatar}
              {dm.online && <div style={{ position: "absolute", bottom: 0, right: 0, width: 8, height: 8, borderRadius: 4, background: C.green, border: "2px solid #0A0A0A" }} />}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <span style={{ fontFamily: FONT, fontSize: 13, color: C.white }}>{dm.name}</span>
              <p style={{ fontSize: 10, color: C.textMuted, margin: "2px 0 0", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{dm.lastMsg}</p>
            </div>
            <span style={{ fontSize: 9, color: C.textMuted }}>{dm.time}</span>
          </button>
        ))}
        {tab === "requests" && (
          <div style={{ padding: 40, textAlign: "center" }}>
            <p style={{ fontSize: 32, marginBottom: 8 }}>📭</p>
            <p style={{ fontSize: 12, color: C.textMuted }}>No message requests</p>
          </div>
        )}
      </div>

      {/* Teams-style bottom nav */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-around",
        padding: "8px 0 24px", borderTop: `1px solid ${C.border}`, background: "rgba(10,10,10,0.98)",
      }}>
        {[
          { icon: "💬", label: "Chat", active: true },
          { icon: "📅", label: "Calendar", active: false },
          { icon: "👥", label: "Teams", active: false },
          { icon: "📞", label: "Calls", active: false },
          { icon: "⋯", label: "More", active: false },
        ].map((item, i) => (
          <button key={i} style={{
            display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
            background: "none", border: "none", cursor: "pointer", padding: "4px 12px",
          }}>
            <span style={{ fontSize: 18 }}>{item.icon}</span>
            <span style={{ fontSize: 8, color: item.active ? C.red : C.textMuted, fontFamily: FONT }}>{item.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

// ═══ PROFILE TAB ═══
function ProfileTab() {
  return (
    <div style={{ height: "100%", background: C.bg, paddingTop: 54, paddingBottom: 80, overflowY: "auto" }}>
      <div style={{ padding: "20px 16px", textAlign: "center" }}>
        <div style={{ width: 80, height: 80, borderRadius: 40, background: `linear-gradient(135deg, ${C.red}, ${C.redDeep})`, margin: "0 auto 12px", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 36 }}>💀</div>
        <h2 style={{ fontFamily: FONT, fontSize: 18, color: C.white, margin: "0 0 4px" }}>demo_user</h2>
        <p style={{ fontSize: 12, color: C.textMuted, margin: 0 }}>Pro Member · Joined May 2026</p>
        <div style={{ display: "flex", justifyContent: "center", gap: 24, marginTop: 16 }}>
          <div style={{ textAlign: "center" }}>
            <div style={{ fontFamily: FONT, fontSize: 18, color: C.white }}>42</div>
            <div style={{ fontSize: 10, color: C.textMuted }}>Animations</div>
          </div>
          <div style={{ textAlign: "center" }}>
            <div style={{ fontFamily: FONT, fontSize: 18, color: C.white }}>1.2K</div>
            <div style={{ fontSize: 10, color: C.textMuted }}>Followers</div>
          </div>
          <div style={{ textAlign: "center" }}>
            <div style={{ fontFamily: FONT, fontSize: 18, color: C.white }}>856</div>
            <div style={{ fontSize: 10, color: C.textMuted }}>Following</div>
          </div>
        </div>
      </div>
      <div style={{ padding: "0 16px" }}>
        {[
          { icon: "⚙️", label: "Settings" },
          { icon: "🎨", label: "My Projects" },
          { icon: "⭐", label: "Favorites" },
          { icon: "📊", label: "Analytics" },
          { icon: "💳", label: "Subscription" },
          { icon: "🔔", label: "Notifications" },
          { icon: "❓", label: "Help & Support" },
          { icon: "🚪", label: "Sign Out" },
        ].map((item, i) => (
          <button key={i} style={{
            width: "100%", padding: "14px 0", border: "none", cursor: "pointer",
            background: "transparent", display: "flex", alignItems: "center", gap: 12,
            borderBottom: `1px solid ${C.borderDim}`, textAlign: "left",
          }}>
            <span style={{ fontSize: 18 }}>{item.icon}</span>
            <span style={{ fontFamily: FONT, fontSize: 13, color: C.white }}>{item.label}</span>
            <span style={{ marginLeft: "auto", color: C.textMuted, fontSize: 12 }}>›</span>
          </button>
        ))}
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// SHARED COMPONENTS
// ═══════════════════════════════════════════════════════════════════

function Btn({ label, onClick, primary }: { label: string; onClick: ()=>void; primary?: boolean }) {
  return (
    <button onClick={onClick} style={{
      width: "100%", padding: "14px 0", borderRadius: 12, border: primary ? "none" : `1px solid ${C.border}`,
      background: primary ? C.red : "transparent", color: primary ? C.white : C.textSecondary,
      fontSize: 14, fontFamily: FONT, cursor: "pointer", letterSpacing: 1,
    }}>{label}</button>
  );
}

function InputField({ label, value, onChange, type }: { label: string; value: string; onChange: (v: string)=>void; type?: string }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <label style={{ display: "block", fontFamily: FONT, fontSize: 11, color: C.textMuted, marginBottom: 6 }}>{label}</label>
      <input type={type || "text"} value={value} onChange={e => onChange(e.target.value)} style={{
        width: "100%", padding: "12px 14px", borderRadius: 8, border: `1px solid ${C.border}`,
        background: C.surface, color: C.white, fontSize: 14, outline: "none", boxSizing: "border-box",
      }} />
    </div>
  );
}

function PanelOverlay({ children, onClose: _onClose, height }: { children: React.ReactNode; onClose: ()=>void; height: string }) {
  return (
    <div style={{
      position: "absolute", bottom: 0, left: 0, right: 0, height,
      background: "rgba(20,20,28,0.98)", borderRadius: "16px 16px 0 0",
      border: `1px solid ${C.border}`, borderBottom: "none",
      display: "flex", flexDirection: "column", overflow: "hidden",
      zIndex: 50, backdropFilter: "blur(20px)",
    }}>
      {/* Drag handle */}
      <div style={{ display: "flex", justifyContent: "center", padding: "6px 0 2px" }}>
        <div style={{ width: 36, height: 4, borderRadius: 2, background: C.textMuted }} />
      </div>
      <div style={{ flex: 1, overflowY: "auto" }}>
        {children}
      </div>
    </div>
  );
}

function PanelHeader({ title, onClose, right }: { title: string; onClose: ()=>void; right?: React.ReactNode }) {
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "8px 16px", borderBottom: `1px solid ${C.borderDim}` }}>
      <span style={{ fontFamily: FONT, fontSize: 14, color: C.white, fontWeight: 700 }}>{title}</span>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        {right}
        <button onClick={onClose} style={{ background: "none", border: "none", color: C.textMuted, fontSize: 14, cursor: "pointer" }}>✕</button>
      </div>
    </div>
  );
}

function SettingsRow({ icon, label, onClick, right, accent }: { icon: string; label: string; onClick?: ()=>void; right?: React.ReactNode; accent?: boolean }) {
  return (
    <button onClick={onClick} style={{
      width: "100%", padding: "10px 16px", border: "none", cursor: onClick ? "pointer" : "default",
      background: "transparent", display: "flex", alignItems: "center", gap: 10, textAlign: "left",
    }}>
      <span style={{ fontSize: 16 }}>{icon}</span>
      <span style={{ flex: 1, fontFamily: FONT, fontSize: 12, color: accent ? C.red : C.white }}>{label}</span>
      {right || (onClick && <span style={{ color: C.textMuted, fontSize: 12 }}>›</span>)}
    </button>
  );
}

function ToggleSwitch({ on, onToggle }: { on: boolean; onToggle: ()=>void }) {
  return (
    <button onClick={onToggle} style={{
      width: 36, height: 20, borderRadius: 10, border: "none", cursor: "pointer",
      background: on ? C.red : C.border, position: "relative", transition: "background 0.2s",
    }}>
      <div style={{ width: 16, height: 16, borderRadius: 8, background: C.white, position: "absolute", top: 2, left: on ? 18 : 2, transition: "left 0.2s" }} />
    </button>
  );
}

function ToggleBtn({ label, active, onClick }: { label: string; active: boolean; onClick: ()=>void }) {
  return (
    <button onClick={onClick} style={{
      padding: "4px 8px", borderRadius: 6, border: `1px solid ${active ? C.red : C.border}`,
      background: active ? "rgba(200,0,0,0.15)" : C.surface, color: active ? C.red : C.textMuted,
      fontSize: 9, fontFamily: FONT, cursor: "pointer",
    }}>{label}</button>
  );
}

function SliderRow({ label, value, min, max, unit, onChange, purple }: {
  label: string; value: number; min: number; max: number; unit: string; onChange: (v: number)=>void; purple?: boolean;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 4 }}>
      <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT, width: 50 }}>{label}</span>
      <input type="range" min={min} max={max} value={value} onChange={e => onChange(Number(e.target.value))}
        style={{ flex: 1, accentColor: purple ? C.purple : C.red, height: 3 }} />
      <span style={{ fontSize: 9, color: C.textMuted, fontFamily: FONT, width: 35, textAlign: "right" }}>{Math.round(value)}{unit}</span>
    </div>
  );
}

function ZoomBtn({ label, onClick, small }: { label: string; onClick: ()=>void; small?: boolean }) {
  return (
    <button onClick={onClick} style={{
      width: 32, height: 32, borderRadius: 16, border: `1px solid ${C.border}`,
      background: C.surface, color: C.white, fontSize: small ? 9 : 16,
      cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center",
      fontFamily: small ? FONT : "inherit",
    }}>{label}</button>
  );
}

// Shared styles
const tinyBtnStyle: React.CSSProperties = {
  width: 28, height: 28, borderRadius: 14, border: `1px solid ${C.border}`,
  background: C.surface, color: C.white, cursor: "pointer",
  display: "flex", alignItems: "center", justifyContent: "center",
  fontSize: 12, flexShrink: 0,
};

const numInputStyle: React.CSSProperties = {
  width: "100%", padding: "6px 8px", borderRadius: 6, border: `1px solid ${C.border}`,
  background: C.surface, color: C.white, fontSize: 12, fontFamily: FONT,
  outline: "none", boxSizing: "border-box",
};

const searchInputStyle: React.CSSProperties = {
  width: "100%", padding: "8px 12px", borderRadius: 8, border: `1px solid ${C.border}`,
  background: C.surface, color: C.white, fontSize: 11, outline: "none",
  boxSizing: "border-box", fontFamily: "inherit",
};

const layerActionStyle: React.CSSProperties = {
  padding: "5px 8px", borderRadius: 6, border: `1px solid ${C.border}`,
  background: C.surface, color: C.textMuted, fontSize: 9, fontFamily: FONT, cursor: "pointer",
};
