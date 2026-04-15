// StickDeath ∞ — Sound Effects Vault
// Full-screen overlay for browsing 1000s of sound effects organized by category
// Categories: Combat, Explosions, Nature, Sci-Fi, Comedy, Ambient, Voice, UI Sounds

import { useState, useMemo } from "react";
import { X, Search, ChevronLeft, Play, Square, Volume2, Clock, Plus } from "lucide-react";

interface Props {
  visible: boolean;
  onClose: () => void;
  onSelectSound: (sound: SoundAsset) => void;
}

export interface SoundAsset {
  id: string;
  name: string;
  category: string;
  subcategory: string;
  duration: string; // "0.5s", "1.2s", etc.
  tags: string[];
  // In production: url to audio file. For now, we use Web Audio API synthesis
  frequency?: number;
  type?: OscillatorType;
  attack?: number;
  decay?: number;
  noiseType?: "white" | "pink" | "brown";
}

interface SoundCategory {
  id: string;
  name: string;
  icon: string;
  subcategories: SoundSubcategory[];
}

interface SoundSubcategory {
  id: string;
  name: string;
  sounds: SoundAsset[];
}

// ── Sound synthesis helper ──
function playSound(sound: SoundAsset) {
  try {
    const ctx = new AudioContext();
    const now = ctx.currentTime;
    const dur = parseFloat(sound.duration) || 0.3;

    if (sound.noiseType) {
      // Noise-based sounds (explosions, static, wind, etc.)
      const bufferSize = ctx.sampleRate * dur;
      const buffer = ctx.createBuffer(1, bufferSize, ctx.sampleRate);
      const data = buffer.getChannelData(0);

      if (sound.noiseType === "white") {
        for (let i = 0; i < bufferSize; i++) data[i] = Math.random() * 2 - 1;
      } else if (sound.noiseType === "pink") {
        let b0 = 0, b1 = 0, b2 = 0;
        for (let i = 0; i < bufferSize; i++) {
          const white = Math.random() * 2 - 1;
          b0 = 0.99886 * b0 + white * 0.0555179;
          b1 = 0.99332 * b1 + white * 0.0750759;
          b2 = 0.96900 * b2 + white * 0.1538520;
          data[i] = (b0 + b1 + b2 + white * 0.5362) * 0.11;
        }
      } else {
        let lastOut = 0;
        for (let i = 0; i < bufferSize; i++) {
          const white = Math.random() * 2 - 1;
          data[i] = (lastOut + 0.02 * white) / 1.02;
          lastOut = data[i]!;
        }
      }

      const source = ctx.createBufferSource();
      source.buffer = buffer;
      const gain = ctx.createGain();
      gain.gain.setValueAtTime(0.3, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + dur);
      source.connect(gain).connect(ctx.destination);
      source.start(now);
      source.stop(now + dur);
    } else {
      // Oscillator-based sounds
      const osc = ctx.createOscillator();
      const gain = ctx.createGain();
      osc.type = sound.type || "sine";
      osc.frequency.setValueAtTime(sound.frequency || 440, now);

      if (sound.attack) {
        gain.gain.setValueAtTime(0, now);
        gain.gain.linearRampToValueAtTime(0.3, now + sound.attack);
      } else {
        gain.gain.setValueAtTime(0.3, now);
      }
      gain.gain.exponentialRampToValueAtTime(0.001, now + dur);

      // Add frequency sweep for some effects
      if (sound.frequency && sound.frequency > 500) {
        osc.frequency.exponentialRampToValueAtTime(80, now + dur);
      }

      osc.connect(gain).connect(ctx.destination);
      osc.start(now);
      osc.stop(now + dur);
    }

    setTimeout(() => ctx.close(), (dur + 0.5) * 1000);
  } catch {
    // Silently fail if AudioContext unavailable
  }
}

// ── Generate sound effect library ──
function makeSFX(id: string, name: string, category: string, subcategory: string, duration: string, tags: string[], opts: Partial<SoundAsset> = {}): SoundAsset {
  return { id, name, category, subcategory, duration, tags, ...opts };
}

const SOUND_CATEGORIES: SoundCategory[] = [
  {
    id: "combat",
    name: "Combat",
    icon: "⚔️",
    subcategories: [
      {
        id: "punches",
        name: "Punches & Kicks",
        sounds: [
          makeSFX("punch-1", "Light Punch", "combat", "punches", "0.2s", ["punch", "hit", "light"], { noiseType: "white" }),
          makeSFX("punch-2", "Heavy Punch", "combat", "punches", "0.3s", ["punch", "hit", "heavy"], { noiseType: "pink" }),
          makeSFX("punch-3", "Face Punch", "combat", "punches", "0.25s", ["punch", "face", "slap"], { noiseType: "white" }),
          makeSFX("punch-4", "Gut Punch", "combat", "punches", "0.35s", ["punch", "gut", "body"], { noiseType: "brown" }),
          makeSFX("punch-5", "Uppercut", "combat", "punches", "0.3s", ["punch", "uppercut"], { frequency: 200, type: "sawtooth" }),
          makeSFX("kick-1", "Roundhouse Kick", "combat", "punches", "0.4s", ["kick", "roundhouse"], { noiseType: "pink" }),
          makeSFX("kick-2", "Front Kick", "combat", "punches", "0.3s", ["kick", "front"], { noiseType: "white" }),
          makeSFX("kick-3", "Side Kick", "combat", "punches", "0.35s", ["kick", "side"], { noiseType: "pink" }),
          makeSFX("kick-4", "Spin Kick", "combat", "punches", "0.5s", ["kick", "spin"], { frequency: 150, type: "sawtooth" }),
          makeSFX("slap-1", "Slap", "combat", "punches", "0.15s", ["slap", "hit"], { noiseType: "white" }),
          makeSFX("slap-2", "Backhand", "combat", "punches", "0.2s", ["slap", "backhand"], { noiseType: "white" }),
          makeSFX("combo-1", "Combo Hit", "combat", "punches", "0.6s", ["combo", "rapid", "hits"], { noiseType: "pink" }),
        ],
      },
      {
        id: "swords",
        name: "Swords & Blades",
        sounds: [
          makeSFX("sword-1", "Sword Swing", "combat", "swords", "0.4s", ["sword", "swing", "whoosh"], { frequency: 800, type: "sawtooth" }),
          makeSFX("sword-2", "Sword Clash", "combat", "swords", "0.3s", ["sword", "clash", "metal"], { frequency: 2000, type: "square" }),
          makeSFX("sword-3", "Sword Unsheathe", "combat", "swords", "0.6s", ["sword", "draw", "unsheathe"], { frequency: 3000, type: "sawtooth", attack: 0.1 }),
          makeSFX("sword-4", "Sword Stab", "combat", "swords", "0.2s", ["sword", "stab", "pierce"], { frequency: 1500, type: "sawtooth" }),
          makeSFX("sword-5", "Axe Chop", "combat", "swords", "0.35s", ["axe", "chop", "heavy"], { frequency: 200, type: "sawtooth" }),
          makeSFX("sword-6", "Knife Slash", "combat", "swords", "0.2s", ["knife", "slash", "quick"], { frequency: 1200, type: "sawtooth" }),
          makeSFX("sword-7", "Dagger Throw", "combat", "swords", "0.5s", ["dagger", "throw", "whoosh"], { frequency: 600, type: "sine" }),
          makeSFX("sword-8", "Shield Block", "combat", "swords", "0.3s", ["shield", "block", "metal"], { frequency: 300, type: "square" }),
        ],
      },
      {
        id: "guns",
        name: "Guns & Weapons",
        sounds: [
          makeSFX("gun-1", "Pistol Shot", "combat", "guns", "0.3s", ["gun", "pistol", "shot"], { noiseType: "white" }),
          makeSFX("gun-2", "Shotgun Blast", "combat", "guns", "0.5s", ["gun", "shotgun", "blast"], { noiseType: "pink" }),
          makeSFX("gun-3", "Machine Gun Burst", "combat", "guns", "0.8s", ["gun", "machine", "burst", "auto"], { noiseType: "white" }),
          makeSFX("gun-4", "Sniper Shot", "combat", "guns", "0.4s", ["gun", "sniper", "shot"], { noiseType: "pink" }),
          makeSFX("gun-5", "Rifle Shot", "combat", "guns", "0.35s", ["gun", "rifle", "shot"], { noiseType: "white" }),
          makeSFX("gun-6", "Reload", "combat", "guns", "0.6s", ["gun", "reload", "click"], { frequency: 800, type: "square" }),
          makeSFX("gun-7", "Empty Click", "combat", "guns", "0.1s", ["gun", "empty", "click"], { frequency: 2000, type: "square" }),
          makeSFX("gun-8", "Bow Release", "combat", "guns", "0.3s", ["bow", "arrow", "release"], { frequency: 400, type: "sine", attack: 0.05 }),
          makeSFX("gun-9", "Arrow Impact", "combat", "guns", "0.2s", ["arrow", "impact", "hit"], { frequency: 600, type: "sawtooth" }),
          makeSFX("gun-10", "Laser Shot", "combat", "guns", "0.3s", ["laser", "shot", "sci-fi"], { frequency: 2000, type: "sine" }),
        ],
      },
    ],
  },
  {
    id: "explosions",
    name: "Explosions",
    icon: "💥",
    subcategories: [
      {
        id: "booms",
        name: "Explosions & Booms",
        sounds: [
          makeSFX("exp-1", "Small Explosion", "explosions", "booms", "0.8s", ["explosion", "small", "blast"], { noiseType: "brown" }),
          makeSFX("exp-2", "Large Explosion", "explosions", "booms", "1.5s", ["explosion", "large", "massive"], { noiseType: "brown" }),
          makeSFX("exp-3", "Grenade", "explosions", "booms", "0.6s", ["grenade", "explosion", "frag"], { noiseType: "pink" }),
          makeSFX("exp-4", "C4 Blast", "explosions", "booms", "1.0s", ["c4", "explosion", "demolition"], { noiseType: "brown" }),
          makeSFX("exp-5", "Nuclear Boom", "explosions", "booms", "3.0s", ["nuclear", "explosion", "massive"], { noiseType: "brown" }),
          makeSFX("exp-6", "Fireball", "explosions", "booms", "0.8s", ["fire", "fireball", "whoosh"], { noiseType: "pink" }),
          makeSFX("exp-7", "Bomb Drop", "explosions", "booms", "1.2s", ["bomb", "drop", "whistle"], { frequency: 800, type: "sine" }),
          makeSFX("exp-8", "Dynamite", "explosions", "booms", "0.7s", ["dynamite", "explosion", "tnt"], { noiseType: "pink" }),
          makeSFX("exp-9", "Rocket Launch", "explosions", "booms", "2.0s", ["rocket", "launch", "thrust"], { noiseType: "brown" }),
          makeSFX("exp-10", "Mine Explosion", "explosions", "booms", "0.5s", ["mine", "explosion", "trap"], { noiseType: "white" }),
        ],
      },
      {
        id: "impacts",
        name: "Impacts & Crashes",
        sounds: [
          makeSFX("imp-1", "Metal Crash", "explosions", "impacts", "0.6s", ["metal", "crash", "impact"], { frequency: 300, type: "square" }),
          makeSFX("imp-2", "Glass Shatter", "explosions", "impacts", "0.5s", ["glass", "shatter", "break"], { noiseType: "white" }),
          makeSFX("imp-3", "Wood Break", "explosions", "impacts", "0.4s", ["wood", "break", "snap"], { noiseType: "pink" }),
          makeSFX("imp-4", "Rock Crumble", "explosions", "impacts", "0.8s", ["rock", "crumble", "debris"], { noiseType: "brown" }),
          makeSFX("imp-5", "Body Fall", "explosions", "impacts", "0.5s", ["body", "fall", "thud"], { frequency: 80, type: "sine" }),
          makeSFX("imp-6", "Wall Hit", "explosions", "impacts", "0.3s", ["wall", "hit", "impact"], { frequency: 150, type: "square" }),
          makeSFX("imp-7", "Car Crash", "explosions", "impacts", "1.0s", ["car", "crash", "vehicle"], { noiseType: "pink" }),
          makeSFX("imp-8", "Building Collapse", "explosions", "impacts", "2.5s", ["building", "collapse", "rumble"], { noiseType: "brown" }),
          makeSFX("imp-9", "Ground Pound", "explosions", "impacts", "0.4s", ["ground", "pound", "earthquake"], { frequency: 60, type: "sine" }),
          makeSFX("imp-10", "Bone Crack", "explosions", "impacts", "0.15s", ["bone", "crack", "snap"], { frequency: 1000, type: "square" }),
        ],
      },
    ],
  },
  {
    id: "nature",
    name: "Nature",
    icon: "🌿",
    subcategories: [
      {
        id: "weather",
        name: "Weather",
        sounds: [
          makeSFX("nat-1", "Thunder Crack", "nature", "weather", "1.5s", ["thunder", "storm", "crack"], { noiseType: "brown" }),
          makeSFX("nat-2", "Light Rain", "nature", "weather", "3.0s", ["rain", "light", "drizzle"], { noiseType: "pink" }),
          makeSFX("nat-3", "Heavy Rain", "nature", "weather", "3.0s", ["rain", "heavy", "downpour"], { noiseType: "white" }),
          makeSFX("nat-4", "Wind Gust", "nature", "weather", "2.0s", ["wind", "gust", "blow"], { noiseType: "brown" }),
          makeSFX("nat-5", "Wind Howl", "nature", "weather", "3.0s", ["wind", "howl", "whistle"], { frequency: 300, type: "sine", attack: 0.5 }),
          makeSFX("nat-6", "Hail", "nature", "weather", "2.0s", ["hail", "ice", "pelting"], { noiseType: "white" }),
          makeSFX("nat-7", "Lightning Strike", "nature", "weather", "0.8s", ["lightning", "strike", "electric"], { noiseType: "white" }),
          makeSFX("nat-8", "Tornado", "nature", "weather", "3.0s", ["tornado", "wind", "vortex"], { frequency: 120, type: "sawtooth", attack: 1.0 }),
        ],
      },
      {
        id: "elements",
        name: "Fire & Water",
        sounds: [
          makeSFX("elem-1", "Fire Crackle", "nature", "elements", "2.0s", ["fire", "crackle", "burn"], { noiseType: "pink" }),
          makeSFX("elem-2", "Water Splash", "nature", "elements", "0.5s", ["water", "splash", "liquid"], { noiseType: "white" }),
          makeSFX("elem-3", "Lava Bubble", "nature", "elements", "0.8s", ["lava", "bubble", "magma"], { frequency: 80, type: "sine" }),
          makeSFX("elem-4", "Ice Crack", "nature", "elements", "0.3s", ["ice", "crack", "freeze"], { frequency: 3000, type: "square" }),
          makeSFX("elem-5", "Waterfall", "nature", "elements", "3.0s", ["waterfall", "rushing", "water"], { noiseType: "pink" }),
          makeSFX("elem-6", "Ocean Waves", "nature", "elements", "3.0s", ["ocean", "waves", "sea"], { noiseType: "brown" }),
          makeSFX("elem-7", "River Flow", "nature", "elements", "3.0s", ["river", "flow", "stream"], { noiseType: "brown" }),
          makeSFX("elem-8", "Dripping Water", "nature", "elements", "0.3s", ["drip", "water", "cave"], { frequency: 1200, type: "sine" }),
        ],
      },
      {
        id: "animals",
        name: "Animals & Creatures",
        sounds: [
          makeSFX("anim-1", "Crow Caw", "nature", "animals", "0.5s", ["crow", "bird", "caw"], { frequency: 600, type: "sawtooth" }),
          makeSFX("anim-2", "Wolf Howl", "nature", "animals", "2.0s", ["wolf", "howl", "night"], { frequency: 300, type: "sine", attack: 0.3 }),
          makeSFX("anim-3", "Snake Hiss", "nature", "animals", "1.0s", ["snake", "hiss", "reptile"], { noiseType: "white" }),
          makeSFX("anim-4", "Bear Growl", "nature", "animals", "1.0s", ["bear", "growl", "roar"], { frequency: 80, type: "sawtooth" }),
          makeSFX("anim-5", "Cat Hiss", "nature", "animals", "0.5s", ["cat", "hiss", "angry"], { noiseType: "white" }),
          makeSFX("anim-6", "Dog Bark", "nature", "animals", "0.3s", ["dog", "bark", "woof"], { frequency: 300, type: "square" }),
          makeSFX("anim-7", "Insect Buzz", "nature", "animals", "1.0s", ["insect", "buzz", "fly"], { frequency: 200, type: "sawtooth" }),
          makeSFX("anim-8", "Monster Roar", "nature", "animals", "1.5s", ["monster", "roar", "creature"], { frequency: 60, type: "sawtooth", attack: 0.2 }),
        ],
      },
    ],
  },
  {
    id: "scifi",
    name: "Sci-Fi",
    icon: "🚀",
    subcategories: [
      {
        id: "energy",
        name: "Energy & Lasers",
        sounds: [
          makeSFX("sci-1", "Laser Blast", "scifi", "energy", "0.3s", ["laser", "blast", "energy"], { frequency: 2000, type: "sine" }),
          makeSFX("sci-2", "Plasma Shot", "scifi", "energy", "0.4s", ["plasma", "shot", "energy"], { frequency: 1500, type: "sawtooth" }),
          makeSFX("sci-3", "Force Field", "scifi", "energy", "1.0s", ["force field", "shield", "energy"], { frequency: 400, type: "sine", attack: 0.2 }),
          makeSFX("sci-4", "Teleport", "scifi", "energy", "0.8s", ["teleport", "warp", "beam"], { frequency: 3000, type: "sine" }),
          makeSFX("sci-5", "Power Up", "scifi", "energy", "1.0s", ["power", "up", "charge"], { frequency: 200, type: "sine", attack: 0.5 }),
          makeSFX("sci-6", "Power Down", "scifi", "energy", "0.8s", ["power", "down", "discharge"], { frequency: 800, type: "sine" }),
          makeSFX("sci-7", "Electric Shock", "scifi", "energy", "0.4s", ["electric", "shock", "zap"], { frequency: 3000, type: "square" }),
          makeSFX("sci-8", "EMP Pulse", "scifi", "energy", "0.6s", ["emp", "pulse", "electronic"], { noiseType: "white" }),
          makeSFX("sci-9", "Lightsaber Hum", "scifi", "energy", "2.0s", ["lightsaber", "hum", "saber"], { frequency: 120, type: "sawtooth", attack: 0.1 }),
          makeSFX("sci-10", "Ion Cannon", "scifi", "energy", "1.0s", ["ion", "cannon", "heavy"], { frequency: 100, type: "sawtooth" }),
        ],
      },
      {
        id: "machines",
        name: "Machines & Tech",
        sounds: [
          makeSFX("tech-1", "Robot Walk", "scifi", "machines", "0.5s", ["robot", "walk", "metal"], { frequency: 200, type: "square" }),
          makeSFX("tech-2", "Engine Start", "scifi", "machines", "1.5s", ["engine", "start", "motor"], { frequency: 80, type: "sawtooth", attack: 0.5 }),
          makeSFX("tech-3", "Door Slide", "scifi", "machines", "0.8s", ["door", "slide", "pneumatic"], { frequency: 400, type: "sine", attack: 0.1 }),
          makeSFX("tech-4", "Computer Beep", "scifi", "machines", "0.2s", ["computer", "beep", "electronic"], { frequency: 1000, type: "square" }),
          makeSFX("tech-5", "Alarm Siren", "scifi", "machines", "2.0s", ["alarm", "siren", "warning"], { frequency: 800, type: "square" }),
          makeSFX("tech-6", "Data Transfer", "scifi", "machines", "1.0s", ["data", "transfer", "digital"], { frequency: 4000, type: "square" }),
          makeSFX("tech-7", "Malfunction", "scifi", "machines", "0.6s", ["malfunction", "error", "glitch"], { noiseType: "white" }),
          makeSFX("tech-8", "Hover Engine", "scifi", "machines", "2.0s", ["hover", "engine", "anti-gravity"], { frequency: 150, type: "sawtooth", attack: 0.3 }),
        ],
      },
    ],
  },
  {
    id: "comedy",
    name: "Comedy",
    icon: "🤡",
    subcategories: [
      {
        id: "cartoon",
        name: "Cartoon SFX",
        sounds: [
          makeSFX("cart-1", "Boing", "comedy", "cartoon", "0.4s", ["boing", "spring", "bounce"], { frequency: 300, type: "sine" }),
          makeSFX("cart-2", "Slide Whistle Up", "comedy", "cartoon", "0.6s", ["whistle", "slide", "up"], { frequency: 200, type: "sine", attack: 0.1 }),
          makeSFX("cart-3", "Slide Whistle Down", "comedy", "cartoon", "0.6s", ["whistle", "slide", "down"], { frequency: 1200, type: "sine" }),
          makeSFX("cart-4", "Pop", "comedy", "cartoon", "0.1s", ["pop", "bubble", "quick"], { frequency: 800, type: "sine" }),
          makeSFX("cart-5", "Squeak", "comedy", "cartoon", "0.2s", ["squeak", "rubber", "mouse"], { frequency: 2000, type: "sine" }),
          makeSFX("cart-6", "Bonk", "comedy", "cartoon", "0.3s", ["bonk", "head", "hit"], { frequency: 400, type: "square" }),
          makeSFX("cart-7", "Splat", "comedy", "cartoon", "0.3s", ["splat", "messy", "pie"], { noiseType: "white" }),
          makeSFX("cart-8", "Zip", "comedy", "cartoon", "0.15s", ["zip", "fast", "quick"], { frequency: 4000, type: "sine" }),
          makeSFX("cart-9", "Wah Wah", "comedy", "cartoon", "1.0s", ["sad", "trombone", "fail"], { frequency: 300, type: "sawtooth" }),
          makeSFX("cart-10", "Ta-Da!", "comedy", "cartoon", "0.8s", ["tada", "fanfare", "success"], { frequency: 600, type: "square" }),
          makeSFX("cart-11", "Drum Roll", "comedy", "cartoon", "1.5s", ["drum", "roll", "suspense"], { noiseType: "pink" }),
          makeSFX("cart-12", "Rimshot", "comedy", "cartoon", "0.4s", ["rimshot", "joke", "punchline"], { noiseType: "white" }),
        ],
      },
      {
        id: "silly",
        name: "Silly & Fun",
        sounds: [
          makeSFX("silly-1", "Fart", "comedy", "silly", "0.5s", ["fart", "gross", "funny"], { frequency: 80, type: "sawtooth" }),
          makeSFX("silly-2", "Burp", "comedy", "silly", "0.3s", ["burp", "gross", "funny"], { frequency: 60, type: "sawtooth" }),
          makeSFX("silly-3", "Record Scratch", "comedy", "silly", "0.3s", ["record", "scratch", "stop"], { noiseType: "white" }),
          makeSFX("silly-4", "Whoopee Cushion", "comedy", "silly", "0.6s", ["whoopee", "cushion", "prank"], { frequency: 70, type: "sawtooth" }),
          makeSFX("silly-5", "Kazoo", "comedy", "silly", "0.5s", ["kazoo", "instrument", "buzz"], { frequency: 300, type: "sawtooth" }),
          makeSFX("silly-6", "Rubber Duck", "comedy", "silly", "0.3s", ["duck", "rubber", "squeak"], { frequency: 1500, type: "sine" }),
          makeSFX("silly-7", "Banana Slip", "comedy", "silly", "0.8s", ["slip", "fall", "banana"], { frequency: 1000, type: "sine" }),
          makeSFX("silly-8", "Clown Horn", "comedy", "silly", "0.3s", ["clown", "horn", "honk"], { frequency: 250, type: "square" }),
        ],
      },
    ],
  },
  {
    id: "ambient",
    name: "Ambient",
    icon: "🎵",
    subcategories: [
      {
        id: "environments",
        name: "Environments",
        sounds: [
          makeSFX("amb-1", "City Traffic", "ambient", "environments", "3.0s", ["city", "traffic", "cars"], { noiseType: "brown" }),
          makeSFX("amb-2", "Crowd Murmur", "ambient", "environments", "3.0s", ["crowd", "people", "murmur"], { noiseType: "pink" }),
          makeSFX("amb-3", "Forest Birds", "ambient", "environments", "3.0s", ["forest", "birds", "nature"], { frequency: 800, type: "sine", attack: 0.5 }),
          makeSFX("amb-4", "Night Crickets", "ambient", "environments", "3.0s", ["night", "crickets", "insects"], { frequency: 4000, type: "square" }),
          makeSFX("amb-5", "Cave Drip", "ambient", "environments", "3.0s", ["cave", "drip", "echo"], { frequency: 1200, type: "sine" }),
          makeSFX("amb-6", "Space Void", "ambient", "environments", "3.0s", ["space", "void", "silence"], { frequency: 40, type: "sine", attack: 1.0 }),
          makeSFX("amb-7", "Underwater", "ambient", "environments", "3.0s", ["underwater", "bubbles", "deep"], { noiseType: "brown" }),
          makeSFX("amb-8", "Campfire", "ambient", "environments", "3.0s", ["campfire", "fire", "crackle"], { noiseType: "pink" }),
          makeSFX("amb-9", "Haunted House", "ambient", "environments", "3.0s", ["haunted", "creepy", "horror"], { frequency: 100, type: "sawtooth", attack: 1.0 }),
          makeSFX("amb-10", "Factory", "ambient", "environments", "3.0s", ["factory", "industrial", "machines"], { frequency: 60, type: "square" }),
        ],
      },
      {
        id: "musical",
        name: "Musical Stings",
        sounds: [
          makeSFX("mus-1", "Victory Jingle", "ambient", "musical", "1.0s", ["victory", "win", "jingle"], { frequency: 500, type: "square" }),
          makeSFX("mus-2", "Defeat Sting", "ambient", "musical", "1.0s", ["defeat", "lose", "sad"], { frequency: 200, type: "sine" }),
          makeSFX("mus-3", "Suspense Hit", "ambient", "musical", "0.5s", ["suspense", "dramatic", "hit"], { frequency: 100, type: "sawtooth" }),
          makeSFX("mus-4", "Horror Sting", "ambient", "musical", "1.5s", ["horror", "scary", "sting"], { frequency: 80, type: "sawtooth", attack: 0.3 }),
          makeSFX("mus-5", "Comic Sting", "ambient", "musical", "0.5s", ["comic", "funny", "sting"], { frequency: 600, type: "square" }),
          makeSFX("mus-6", "Action Loop", "ambient", "musical", "2.0s", ["action", "intense", "loop"], { frequency: 150, type: "sawtooth" }),
          makeSFX("mus-7", "Countdown Tick", "ambient", "musical", "0.2s", ["countdown", "tick", "clock"], { frequency: 1000, type: "square" }),
          makeSFX("mus-8", "Level Complete", "ambient", "musical", "1.0s", ["level", "complete", "game"], { frequency: 800, type: "square" }),
        ],
      },
    ],
  },
  {
    id: "voice",
    name: "Voice",
    icon: "🗣️",
    subcategories: [
      {
        id: "reactions",
        name: "Reactions & Expressions",
        sounds: [
          makeSFX("vox-1", "Scream", "voice", "reactions", "1.0s", ["scream", "yell", "terror"], { frequency: 800, type: "sawtooth", attack: 0.1 }),
          makeSFX("vox-2", "Grunt", "voice", "reactions", "0.3s", ["grunt", "effort", "strain"], { frequency: 120, type: "sawtooth" }),
          makeSFX("vox-3", "Gasp", "voice", "reactions", "0.4s", ["gasp", "surprise", "shock"], { noiseType: "white" }),
          makeSFX("vox-4", "Evil Laugh", "voice", "reactions", "1.5s", ["laugh", "evil", "villain"], { frequency: 200, type: "sawtooth" }),
          makeSFX("vox-5", "Battle Cry", "voice", "reactions", "1.0s", ["battle", "cry", "charge"], { frequency: 400, type: "sawtooth", attack: 0.2 }),
          makeSFX("vox-6", "Death Groan", "voice", "reactions", "0.8s", ["death", "groan", "dying"], { frequency: 100, type: "sawtooth" }),
          makeSFX("vox-7", "Cheer", "voice", "reactions", "1.0s", ["cheer", "crowd", "yay"], { noiseType: "pink" }),
          makeSFX("vox-8", "Boo", "voice", "reactions", "1.0s", ["boo", "crowd", "disapproval"], { frequency: 200, type: "sine" }),
          makeSFX("vox-9", "Whisper", "voice", "reactions", "0.5s", ["whisper", "quiet", "secret"], { noiseType: "brown" }),
          makeSFX("vox-10", "Cough", "voice", "reactions", "0.3s", ["cough", "sick", "choke"], { noiseType: "pink" }),
        ],
      },
    ],
  },
  {
    id: "ui",
    name: "UI Sounds",
    icon: "🔔",
    subcategories: [
      {
        id: "interface",
        name: "Interface & Notifications",
        sounds: [
          makeSFX("ui-1", "Button Click", "ui", "interface", "0.1s", ["button", "click", "tap"], { frequency: 1000, type: "sine" }),
          makeSFX("ui-2", "Menu Open", "ui", "interface", "0.2s", ["menu", "open", "slide"], { frequency: 600, type: "sine" }),
          makeSFX("ui-3", "Menu Close", "ui", "interface", "0.2s", ["menu", "close", "slide"], { frequency: 400, type: "sine" }),
          makeSFX("ui-4", "Notification", "ui", "interface", "0.5s", ["notification", "alert", "ding"], { frequency: 800, type: "sine" }),
          makeSFX("ui-5", "Error", "ui", "interface", "0.3s", ["error", "wrong", "buzz"], { frequency: 200, type: "square" }),
          makeSFX("ui-6", "Success", "ui", "interface", "0.3s", ["success", "correct", "ding"], { frequency: 1200, type: "sine" }),
          makeSFX("ui-7", "Whoosh In", "ui", "interface", "0.3s", ["whoosh", "transition", "in"], { frequency: 200, type: "sine", attack: 0.05 }),
          makeSFX("ui-8", "Whoosh Out", "ui", "interface", "0.3s", ["whoosh", "transition", "out"], { frequency: 800, type: "sine" }),
          makeSFX("ui-9", "Typing", "ui", "interface", "0.1s", ["typing", "keyboard", "key"], { frequency: 2000, type: "square" }),
          makeSFX("ui-10", "Toggle On", "ui", "interface", "0.15s", ["toggle", "switch", "on"], { frequency: 1000, type: "sine" }),
          makeSFX("ui-11", "Toggle Off", "ui", "interface", "0.15s", ["toggle", "switch", "off"], { frequency: 600, type: "sine" }),
          makeSFX("ui-12", "Coin Collect", "ui", "interface", "0.3s", ["coin", "collect", "game"], { frequency: 1500, type: "square" }),
        ],
      },
    ],
  },
];

// Count total sounds
const TOTAL_SOUNDS = SOUND_CATEGORIES.reduce((sum, cat) =>
  sum + cat.subcategories.reduce((s, sub) => s + sub.sounds.length, 0), 0);

export default function SoundVault({ visible, onClose, onSelectSound }: Props) {
  const [selectedCategory, setSelectedCategory] = useState<SoundCategory | null>(null);
  const [selectedSubcategory, setSelectedSubcategory] = useState<SoundSubcategory | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [playingId, setPlayingId] = useState<string | null>(null);

  // Search across all sounds
  const searchResults = useMemo(() => {
    if (!searchQuery.trim()) return null;
    const q = searchQuery.toLowerCase();
    const results: SoundAsset[] = [];
    for (const cat of SOUND_CATEGORIES) {
      for (const sub of cat.subcategories) {
        for (const sound of sub.sounds) {
          if (sound.name.toLowerCase().includes(q) || sound.tags.some(t => t.includes(q))) {
            results.push(sound);
          }
        }
      }
    }
    return results;
  }, [searchQuery]);

  if (!visible) return null;

  const handlePreview = (sound: SoundAsset) => {
    setPlayingId(sound.id);
    playSound(sound);
    const dur = parseFloat(sound.duration) || 0.3;
    setTimeout(() => setPlayingId(null), dur * 1000 + 200);
  };

  return (
    <div className="fixed inset-0 z-50 bg-[#0a0a0f] flex flex-col animate-slide-up">
      {/* Header */}
      <div className="flex items-center gap-3 px-4 py-3 border-b border-[#2a2a3a] shrink-0">
        {selectedSubcategory ? (
          <button onClick={() => setSelectedSubcategory(null)} className="text-[#72728a] hover:text-white">
            <ChevronLeft size={22} />
          </button>
        ) : selectedCategory ? (
          <button onClick={() => setSelectedCategory(null)} className="text-[#72728a] hover:text-white">
            <ChevronLeft size={22} />
          </button>
        ) : (
          <button onClick={onClose} className="text-[#72728a] hover:text-white">
            <X size={22} />
          </button>
        )}
        <h2 className="text-white font-bold text-lg font-['Special_Elite'] flex-1">
          {selectedSubcategory?.name ?? selectedCategory?.name ?? "Sound Effects"}
        </h2>
        <Volume2 size={18} className="text-[#555]" />
        <span className="text-[10px] text-[#555]">{TOTAL_SOUNDS}+ SFX</span>
      </div>

      {/* Search */}
      <div className="px-4 py-2 shrink-0">
        <div className="flex items-center gap-2 bg-[#1a1a24] rounded-xl px-3 py-2 border border-[#2a2a3a]">
          <Search size={16} className="text-[#555]" />
          <input
            type="text"
            placeholder="Search sounds..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="flex-1 bg-transparent text-white text-sm outline-none placeholder-[#555]"
          />
          {searchQuery && (
            <button onClick={() => setSearchQuery("")} className="text-[#555] hover:text-white">
              <X size={14} />
            </button>
          )}
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto px-4 pb-6" data-allow-scroll="true" style={{ touchAction: "pan-y" }}>
        {/* Search results */}
        {searchResults !== null ? (
          <div>
            <p className="text-xs text-[#555] mb-3">{searchResults.length} results for "{searchQuery}"</p>
            <div className="space-y-1">
              {searchResults.map((sound) => (
                <SoundRow key={sound.id} sound={sound} isPlaying={playingId === sound.id} onPreview={handlePreview} onSelect={onSelectSound} />
              ))}
            </div>
          </div>
        ) : !selectedCategory ? (
          /* Category grid */
          <div className="space-y-3 pt-2">
            {SOUND_CATEGORIES.map((cat) => {
              const count = cat.subcategories.reduce((s, sub) => s + sub.sounds.length, 0);
              return (
                <button
                  key={cat.id}
                  onClick={() => setSelectedCategory(cat)}
                  className="w-full flex items-center gap-4 p-4 bg-[#111118] rounded-2xl border border-[#2a2a3a] hover:border-[#3a3a4a] transition-colors"
                >
                  <span className="text-3xl">{cat.icon}</span>
                  <div className="text-left flex-1">
                    <span className="text-white font-semibold text-sm">{cat.name}</span>
                    <span className="text-[#555] text-xs ml-2">{count} sounds</span>
                  </div>
                  <ChevronLeft size={16} className="text-[#555] rotate-180" />
                </button>
              );
            })}
          </div>
        ) : !selectedSubcategory ? (
          /* Subcategory grid */
          <div className="space-y-3 pt-2">
            {selectedCategory.subcategories.map((sub) => (
              <button
                key={sub.id}
                onClick={() => setSelectedSubcategory(sub)}
                className="w-full flex items-center gap-4 p-4 bg-[#111118] rounded-2xl border border-[#2a2a3a] hover:border-[#3a3a4a] transition-colors"
              >
                <div className="w-10 h-10 rounded-xl bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center">
                  <Volume2 size={18} className="text-[#555]" />
                </div>
                <div className="text-left flex-1">
                  <span className="text-white font-semibold text-sm">{sub.name}</span>
                  <span className="text-[#555] text-xs ml-2">{sub.sounds.length} sounds</span>
                </div>
                <ChevronLeft size={16} className="text-[#555] rotate-180" />
              </button>
            ))}
          </div>
        ) : (
          /* Sound list */
          <div className="space-y-1 pt-2">
            {selectedSubcategory.sounds.map((sound) => (
              <SoundRow key={sound.id} sound={sound} isPlaying={playingId === sound.id} onPreview={handlePreview} onSelect={onSelectSound} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function SoundRow({ sound, isPlaying, onPreview, onSelect }: {
  sound: SoundAsset;
  isPlaying: boolean;
  onPreview: (s: SoundAsset) => void;
  onSelect: (s: SoundAsset) => void;
}) {
  return (
    <div className="flex items-center gap-3 p-3 bg-[#111118] rounded-xl border border-[#1a1a2a] hover:border-[#2a2a3a] transition-colors">
      {/* Preview button */}
      <button
        onClick={() => onPreview(sound)}
        className={`w-9 h-9 rounded-full flex items-center justify-center shrink-0 transition-all ${
          isPlaying
            ? "bg-[#ff2d55] text-white shadow-lg shadow-[#ff2d55]/30"
            : "bg-[#1a1a24] text-[#72728a] hover:text-white border border-[#2a2a3a]"
        }`}
      >
        {isPlaying ? <Square size={14} fill="white" /> : <Play size={14} fill="currentColor" />}
      </button>

      {/* Info */}
      <div className="flex-1 min-w-0">
        <span className="text-sm text-white truncate block">{sound.name}</span>
        <div className="flex items-center gap-2 mt-0.5">
          <Clock size={10} className="text-[#555]" />
          <span className="text-[10px] text-[#555]">{sound.duration}</span>
          <span className="text-[10px] text-[#555]">•</span>
          <span className="text-[10px] text-[#555] truncate">{sound.tags.slice(0, 3).join(", ")}</span>
        </div>
      </div>

      {/* Add button */}
      <button
        onClick={() => onSelect(sound)}
        className="w-8 h-8 rounded-lg flex items-center justify-center text-[#72728a] hover:text-[#ff2d55] hover:bg-[#ff2d55]/10 transition-colors shrink-0"
      >
        <Plus size={18} />
      </button>
    </div>
  );
}
