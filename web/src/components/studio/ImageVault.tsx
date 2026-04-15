// StickDeath ∞ — Image Vault
// Full-screen overlay for browsing 1000s of images organized by category
// Categories: Backgrounds, Characters, Props, Effects, Stickers, UI Elements

import { useState, useMemo } from "react";
import { X, Search, ChevronLeft, Loader2 } from "lucide-react";

interface Props {
  visible: boolean;
  onClose: () => void;
  onSelectImage: (url: string, name: string) => void;
}

// ── Asset data structure ──
interface Category {
  id: string;
  name: string;
  icon: string;
  subcategories: Subcategory[];
}

interface Subcategory {
  id: string;
  name: string;
  items: ImageAsset[];
}

interface ImageAsset {
  id: string;
  name: string;
  url: string;
  tags: string[];
}

// ── CURATED ASSET LIBRARY ──
// Using free SVG/PNG resources and placeholders for asset packs
// In production: these would be hosted on CDN with proper licensing

function generateStickFigurePoses(): ImageAsset[] {
  const poses = [
    "Standing", "Walking", "Running", "Jumping", "Falling",
    "Punching", "Kicking", "Blocking", "Crouching", "Lying Down",
    "Dancing", "Waving", "Pointing", "Throwing", "Catching",
    "Climbing", "Swimming", "Flying", "Sitting", "Pushing",
    "Pulling", "Lifting", "Chopping", "Shooting", "Dodging",
    "Backflip", "Front Flip", "Cartwheel", "Splits", "T-Pose",
    "Victory", "Defeated", "Surprised", "Angry", "Happy",
    "Sad", "Thinking", "Sleeping", "Eating", "Drinking",
  ];
  return poses.map((pose, i) => ({
    id: `pose-${i}`,
    name: pose,
    url: `data:image/svg+xml,${encodeURIComponent(generateStickSVG(pose))}`,
    tags: ["stick figure", "pose", pose.toLowerCase()],
  }));
}

function generateStickSVG(pose: string): string {
  // Generate simple stick figure SVGs for different poses
  const hash = pose.split("").reduce((a, c) => a + c.charCodeAt(0), 0);
  const armAngle = (hash % 60) - 30;
  const legSpread = 15 + (hash % 20);

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 150" width="100" height="150">
    <circle cx="50" cy="20" r="12" fill="none" stroke="black" stroke-width="3"/>
    <line x1="50" y1="32" x2="50" y2="80" stroke="black" stroke-width="3"/>
    <line x1="50" y1="50" x2="${30 + armAngle}" y2="65" stroke="black" stroke-width="3"/>
    <line x1="50" y1="50" x2="${70 - armAngle}" y2="65" stroke="black" stroke-width="3"/>
    <line x1="50" y1="80" x2="${50 - legSpread}" y2="120" stroke="black" stroke-width="3"/>
    <line x1="50" y1="80" x2="${50 + legSpread}" y2="120" stroke="black" stroke-width="3"/>
    <text x="50" y="142" text-anchor="middle" font-size="8" fill="#666">${pose}</text>
  </svg>`;
}

function generateColorBackground(name: string, colors: string[]): ImageAsset {
  const id = name.toLowerCase().replace(/\s+/g, "-");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="${colors[0]}"/>
      <stop offset="100%" stop-color="${colors[1] || colors[0]}"/>
    </linearGradient></defs>
    <rect width="400" height="300" fill="url(#g)"/>
    <text x="200" y="155" text-anchor="middle" font-size="14" fill="white" opacity="0.5">${name}</text>
  </svg>`;
  return {
    id: `bg-${id}`,
    name,
    url: `data:image/svg+xml,${encodeURIComponent(svg)}`,
    tags: ["background", ...name.toLowerCase().split(" ")],
  };
}

function generatePatternBackground(name: string, pattern: string): ImageAsset {
  const id = name.toLowerCase().replace(/\s+/g, "-");
  const patterns: Record<string, string> = {
    grid: '<line x1="0" y1="20" x2="40" y2="20" stroke="#ddd" stroke-width="0.5"/><line x1="20" y1="0" x2="20" y2="40" stroke="#ddd" stroke-width="0.5"/>',
    dots: '<circle cx="20" cy="20" r="2" fill="#ddd"/>',
    lines: '<line x1="0" y1="0" x2="40" y2="40" stroke="#ddd" stroke-width="0.5"/>',
    cross: '<line x1="10" y1="20" x2="30" y2="20" stroke="#ddd" stroke-width="1"/><line x1="20" y1="10" x2="20" y2="30" stroke="#ddd" stroke-width="1"/>',
    zigzag: '<polyline points="0,30 10,10 20,30 30,10 40,30" fill="none" stroke="#ddd" stroke-width="0.5"/>',
  };
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">
    <rect width="400" height="300" fill="white"/>
    <defs><pattern id="p" patternUnits="userSpaceOnUse" width="40" height="40">${patterns[pattern] || patterns.grid}</pattern></defs>
    <rect width="400" height="300" fill="url(#p)"/>
    <text x="200" y="155" text-anchor="middle" font-size="14" fill="#999">${name}</text>
  </svg>`;
  return {
    id: `bg-${id}`,
    name,
    url: `data:image/svg+xml,${encodeURIComponent(svg)}`,
    tags: ["background", "pattern", ...name.toLowerCase().split(" ")],
  };
}

function generateEffectSVG(name: string, content: string): ImageAsset {
  const id = name.toLowerCase().replace(/\s+/g, "-");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="200" height="200">
    ${content}
    <text x="100" y="190" text-anchor="middle" font-size="10" fill="#666">${name}</text>
  </svg>`;
  return {
    id: `fx-${id}`,
    name,
    url: `data:image/svg+xml,${encodeURIComponent(svg)}`,
    tags: ["effect", ...name.toLowerCase().split(" ")],
  };
}

function generatePropSVG(name: string, content: string): ImageAsset {
  const id = name.toLowerCase().replace(/\s+/g, "-");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
    ${content}
  </svg>`;
  return {
    id: `prop-${id}`,
    name,
    url: `data:image/svg+xml,${encodeURIComponent(svg)}`,
    tags: ["prop", ...name.toLowerCase().split(" ")],
  };
}

// ── Build the full asset library ──
const CATEGORIES: Category[] = [
  {
    id: "backgrounds",
    name: "Backgrounds",
    icon: "🖼",
    subcategories: [
      {
        id: "gradients",
        name: "Gradients",
        items: [
          generateColorBackground("Sunset", ["#ff6b35", "#f7c59f"]),
          generateColorBackground("Ocean", ["#0077b6", "#90e0ef"]),
          generateColorBackground("Forest", ["#2d6a4f", "#95d5b2"]),
          generateColorBackground("Night Sky", ["#0a0a2a", "#1a1a4a"]),
          generateColorBackground("Blood Red", ["#8b0000", "#dc2626"]),
          generateColorBackground("Purple Haze", ["#4a0080", "#9b59b6"]),
          generateColorBackground("Desert", ["#e6c88a", "#d4a574"]),
          generateColorBackground("Arctic", ["#caf0f8", "#e8f4f8"]),
          generateColorBackground("Lava", ["#ff4500", "#ff8c00"]),
          generateColorBackground("Midnight", ["#0d1b2a", "#1b263b"]),
          generateColorBackground("Toxic", ["#0f0", "#006400"]),
          generateColorBackground("Cotton Candy", ["#ff69b4", "#dda0dd"]),
          generateColorBackground("Storm", ["#2c3e50", "#4a6fa5"]),
          generateColorBackground("Autumn", ["#d4711e", "#8b4513"]),
          generateColorBackground("Spring", ["#90ee90", "#98fb98"]),
          generateColorBackground("Neon", ["#ff00ff", "#00ffff"]),
          generateColorBackground("Warm Gray", ["#4a4a4a", "#8a8a8a"]),
          generateColorBackground("Cool Blue", ["#1e3a5f", "#3d7db5"]),
          generateColorBackground("Rose Gold", ["#b76e79", "#f0c9cf"]),
          generateColorBackground("Emerald", ["#046307", "#50c878"]),
        ],
      },
      {
        id: "patterns",
        name: "Patterns",
        items: [
          generatePatternBackground("Grid Paper", "grid"),
          generatePatternBackground("Dot Grid", "dots"),
          generatePatternBackground("Diagonal Lines", "lines"),
          generatePatternBackground("Cross Pattern", "cross"),
          generatePatternBackground("Zigzag", "zigzag"),
          generateColorBackground("Solid White", ["#ffffff", "#ffffff"]),
          generateColorBackground("Solid Black", ["#000000", "#000000"]),
          generateColorBackground("Solid Gray", ["#808080", "#808080"]),
          generateColorBackground("Solid Red", ["#dc2626", "#dc2626"]),
          generateColorBackground("Solid Blue", ["#2563eb", "#2563eb"]),
        ],
      },
      {
        id: "scenes",
        name: "Scene Templates",
        items: Array.from({ length: 20 }, (_, i) => {
          const scenes = [
            "City Street", "Alley", "Rooftop", "Park", "School",
            "Arena", "Dojo", "Prison", "Lab", "Warehouse",
            "Desert Road", "Mountain", "Beach", "Cave", "Bridge",
            "Spaceship", "Space Station", "Alien Planet", "Moon Surface", "Asteroid",
          ];
          const colors = [
            ["#34495e", "#7f8c8d"], ["#2c3e50", "#555"], ["#1a1a2e", "#16213e"],
            ["#2d6a4f", "#52b788"], ["#8d6e63", "#bcaaa4"], ["#b71c1c", "#e53935"],
            ["#ff8f00", "#ffb74d"], ["#1565c0", "#42a5f5"], ["#6a1b9a", "#ce93d8"],
            ["#424242", "#757575"], ["#e65100", "#ff9800"], ["#1b5e20", "#4caf50"],
            ["#0277bd", "#4fc3f7"], ["#3e2723", "#795548"], ["#546e7a", "#90a4ae"],
            ["#1a237e", "#5c6bc0"], ["#0d47a1", "#42a5f5"], ["#4a148c", "#ab47bc"],
            ["#263238", "#607d8b"], ["#37474f", "#78909c"],
          ];
          return generateColorBackground(scenes[i]!, colors[i]!);
        }),
      },
    ],
  },
  {
    id: "characters",
    name: "Characters",
    icon: "🧍",
    subcategories: [
      {
        id: "stick-poses",
        name: "Stick Figure Poses",
        items: generateStickFigurePoses(),
      },
      {
        id: "stick-templates",
        name: "Character Templates",
        items: [
          "Ninja", "Samurai", "Knight", "Archer", "Mage",
          "Zombie", "Robot", "Alien", "Pirate", "Cowboy",
          "Superhero", "Villain", "Soldier", "Spy", "Boxer",
          "Skater", "Surfer", "Rockstar", "Chef", "Doctor",
        ].map((name, i) => ({
          id: `char-${i}`,
          name,
          url: `data:image/svg+xml,${encodeURIComponent(generateStickSVG(name))}`,
          tags: ["character", "template", name.toLowerCase()],
        })),
      },
    ],
  },
  {
    id: "props",
    name: "Props & Objects",
    icon: "⚔️",
    subcategories: [
      {
        id: "weapons",
        name: "Weapons",
        items: [
          generatePropSVG("Sword", '<line x1="20" y1="80" x2="80" y2="20" stroke="#666" stroke-width="3"/><line x1="30" y1="55" x2="55" y2="30" stroke="#666" stroke-width="6"/>'),
          generatePropSVG("Axe", '<line x1="50" y1="85" x2="50" y2="25" stroke="#8B4513" stroke-width="4"/><path d="M35,25 Q50,10 65,25 Q60,35 40,35Z" fill="#888"/>'),
          generatePropSVG("Bow", '<path d="M30,20 Q15,50 30,80" fill="none" stroke="#8B4513" stroke-width="3"/><line x1="30" y1="20" x2="30" y2="80" stroke="#ddd" stroke-width="1"/>'),
          generatePropSVG("Shield", '<ellipse cx="50" cy="50" rx="25" ry="30" fill="#4a6fa5" stroke="#333" stroke-width="2"/><line x1="50" y1="25" x2="50" y2="75" stroke="#5a7fb5" stroke-width="3"/>'),
          generatePropSVG("Gun", '<rect x="25" y="40" width="50" height="15" rx="2" fill="#333"/><rect x="35" y="45" width="8" height="25" rx="1" fill="#444"/>'),
          generatePropSVG("Dagger", '<line x1="50" y1="75" x2="50" y2="25" stroke="#999" stroke-width="2"/><polygon points="45,30 50,15 55,30" fill="#bbb"/>'),
          generatePropSVG("Spear", '<line x1="50" y1="90" x2="50" y2="15" stroke="#8B4513" stroke-width="3"/><polygon points="45,20 50,5 55,20" fill="#888"/>'),
          generatePropSVG("Nunchaku", '<rect x="20" y="25" width="8" height="30" rx="3" fill="#8B4513"/><rect x="72" y="45" width="8" height="30" rx="3" fill="#8B4513"/><path d="M28,35 Q50,30 72,55" fill="none" stroke="#666" stroke-width="2"/>'),
          generatePropSVG("Bomb", '<circle cx="50" cy="55" r="22" fill="#333"/><line x1="60" y1="35" x2="70" y2="20" stroke="#666" stroke-width="2"/><circle cx="72" cy="18" r="5" fill="#ff6600" opacity="0.8"/>'),
          generatePropSVG("Grenade", '<rect x="38" y="40" width="24" height="32" rx="8" fill="#556b2f"/><rect x="44" y="32" width="12" height="10" rx="2" fill="#666"/><path d="M56,35 Q65,25 55,20" fill="none" stroke="#666" stroke-width="2"/>'),
        ],
      },
      {
        id: "vehicles",
        name: "Vehicles",
        items: [
          generatePropSVG("Car", '<rect x="15" y="45" width="70" height="20" rx="5" fill="#dc2626"/><rect x="25" y="30" width="40" height="20" rx="5" fill="#b91c1c"/><circle cx="30" cy="70" r="8" fill="#333"/><circle cx="70" cy="70" r="8" fill="#333"/>'),
          generatePropSVG("Motorcycle", '<circle cx="25" cy="65" r="12" fill="none" stroke="#333" stroke-width="3"/><circle cx="75" cy="65" r="12" fill="none" stroke="#333" stroke-width="3"/><path d="M25,65 L45,40 L75,65" fill="none" stroke="#dc2626" stroke-width="3"/>'),
          generatePropSVG("Helicopter", '<ellipse cx="50" cy="55" rx="30" ry="15" fill="#4a6fa5"/><line x1="20" y1="40" x2="80" y2="40" stroke="#666" stroke-width="2"/><line x1="70" y1="55" x2="90" y2="50" stroke="#4a6fa5" stroke-width="3"/>'),
          generatePropSVG("Tank", '<rect x="10" y="50" width="80" height="25" rx="5" fill="#556b2f"/><rect x="30" y="35" width="30" height="20" rx="3" fill="#4a5f30"/><line x1="60" y1="40" x2="90" y2="35" stroke="#666" stroke-width="4"/>'),
          generatePropSVG("Skateboard", '<rect x="15" y="50" width="70" height="8" rx="4" fill="#8B4513"/><circle cx="25" cy="65" r="6" fill="#333"/><circle cx="75" cy="65" r="6" fill="#333"/>'),
        ],
      },
      {
        id: "objects",
        name: "Objects",
        items: [
          generatePropSVG("Barrel", '<rect x="30" y="20" width="40" height="60" rx="8" fill="#8B4513"/><line x1="30" y1="35" x2="70" y2="35" stroke="#A0522D" stroke-width="2"/><line x1="30" y1="65" x2="70" y2="65" stroke="#A0522D" stroke-width="2"/>'),
          generatePropSVG("Crate", '<rect x="25" y="25" width="50" height="50" fill="#DEB887" stroke="#8B4513" stroke-width="2"/><line x1="25" y1="50" x2="75" y2="50" stroke="#8B4513" stroke-width="1"/><line x1="50" y1="25" x2="50" y2="75" stroke="#8B4513" stroke-width="1"/>'),
          generatePropSVG("Rock", '<path d="M25,70 L35,40 L55,30 L75,45 L80,70Z" fill="#888" stroke="#666" stroke-width="2"/>'),
          generatePropSVG("Tree", '<rect x="45" y="50" width="10" height="35" fill="#8B4513"/><circle cx="50" cy="35" r="25" fill="#2d6a4f"/>'),
          generatePropSVG("Fire", '<path d="M50,15 Q65,35 55,55 Q50,45 45,55 Q35,35 50,15Z" fill="#ff6600"/><path d="M50,25 Q58,40 52,50 Q50,45 48,50 Q42,40 50,25Z" fill="#ffcc00"/>'),
          generatePropSVG("Coin", '<circle cx="50" cy="50" r="22" fill="#ffd700" stroke="#daa520" stroke-width="2"/><text x="50" y="56" text-anchor="middle" font-size="20" fill="#b8860b" font-weight="bold">$</text>'),
          generatePropSVG("Heart", '<path d="M50,75 L25,50 Q15,30 35,30 Q50,30 50,45 Q50,30 65,30 Q85,30 75,50Z" fill="#dc2626"/>'),
          generatePropSVG("Star", '<polygon points="50,15 58,40 85,40 63,55 72,80 50,65 28,80 37,55 15,40 42,40" fill="#ffd700"/>'),
          generatePropSVG("Lightning", '<polygon points="55,10 35,50 50,50 40,90 70,45 55,45 65,10" fill="#ffd700"/>'),
          generatePropSVG("Skull", '<circle cx="50" cy="40" r="22" fill="white" stroke="#333" stroke-width="2"/><circle cx="42" cy="37" r="5" fill="#333"/><circle cx="58" cy="37" r="5" fill="#333"/><path d="M42,52 L45,48 L50,52 L55,48 L58,52" fill="none" stroke="#333" stroke-width="2"/>'),
        ],
      },
      {
        id: "speech",
        name: "Speech & UI",
        items: [
          generatePropSVG("Speech Bubble", '<path d="M20,20 Q20,10 35,10 L65,10 Q80,10 80,20 L80,50 Q80,60 65,60 L40,60 L25,75 L30,60 L35,60 Q20,60 20,50Z" fill="white" stroke="#333" stroke-width="2"/>'),
          generatePropSVG("Thought Bubble", '<ellipse cx="50" cy="35" rx="30" ry="22" fill="white" stroke="#333" stroke-width="2"/><circle cx="30" cy="65" r="5" fill="white" stroke="#333" stroke-width="2"/><circle cx="22" cy="78" r="3" fill="white" stroke="#333" stroke-width="2"/>'),
          generatePropSVG("Shout Bubble", '<polygon points="50,5 85,20 95,50 80,80 50,90 20,75 5,45 15,15" fill="white" stroke="#333" stroke-width="2"/>'),
          generatePropSVG("Arrow Right", '<line x1="15" y1="50" x2="75" y2="50" stroke="#333" stroke-width="4"/><polygon points="70,35 90,50 70,65" fill="#333"/>'),
          generatePropSVG("Arrow Left", '<line x1="25" y1="50" x2="85" y2="50" stroke="#333" stroke-width="4"/><polygon points="30,35 10,50 30,65" fill="#333"/>'),
        ],
      },
    ],
  },
  {
    id: "effects",
    name: "Effects",
    icon: "💥",
    subcategories: [
      {
        id: "impacts",
        name: "Impact & Explosion",
        items: [
          generateEffectSVG("Explosion 1", '<polygon points="100,30 120,60 150,50 130,80 160,100 130,110 140,140 100,120 60,140 70,110 40,100 70,80 50,50 80,60" fill="#ff6600" stroke="#ff0000" stroke-width="2"/>'),
          generateEffectSVG("Starburst", '<polygon points="100,20 110,70 160,50 120,90 170,100 120,110 150,150 100,120 50,150 80,110 30,100 80,90 40,50 90,70" fill="#ffcc00" opacity="0.8"/>'),
          generateEffectSVG("Impact Lines", '<line x1="100" y1="100" x2="100" y2="20" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="170" y2="50" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="180" y2="100" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="170" y2="150" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="100" y2="180" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="30" y2="150" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="20" y2="100" stroke="#333" stroke-width="2"/><line x1="100" y1="100" x2="30" y2="50" stroke="#333" stroke-width="2"/>'),
          generateEffectSVG("POW", '<polygon points="100,20 130,60 180,50 145,85 175,130 130,110 100,160 70,110 25,130 55,85 20,50 70,60" fill="#ff2d55"/><text x="100" y="105" text-anchor="middle" font-size="28" font-weight="bold" fill="white">POW</text>'),
          generateEffectSVG("BANG", '<polygon points="100,15 125,55 175,45 140,80 170,125 125,105 100,155 75,105 30,125 60,80 25,45 75,55" fill="#ffd700"/><text x="100" y="100" text-anchor="middle" font-size="24" font-weight="bold" fill="#333">BANG</text>'),
          generateEffectSVG("BOOM", '<circle cx="100" cy="100" r="60" fill="#ff4500" opacity="0.6"/><circle cx="100" cy="100" r="40" fill="#ff6600" opacity="0.7"/><circle cx="100" cy="100" r="20" fill="#ffcc00"/><text x="100" y="108" text-anchor="middle" font-size="20" font-weight="bold" fill="white">BOOM</text>'),
        ],
      },
      {
        id: "motion",
        name: "Motion & Speed",
        items: [
          generateEffectSVG("Speed Lines Left", '<line x1="180" y1="60" x2="40" y2="60" stroke="#333" stroke-width="1.5"/><line x1="180" y1="80" x2="20" y2="80" stroke="#333" stroke-width="2"/><line x1="180" y1="100" x2="10" y2="100" stroke="#333" stroke-width="2.5"/><line x1="180" y1="120" x2="20" y2="120" stroke="#333" stroke-width="2"/><line x1="180" y1="140" x2="40" y2="140" stroke="#333" stroke-width="1.5"/>'),
          generateEffectSVG("Speed Lines Right", '<line x1="20" y1="60" x2="160" y2="60" stroke="#333" stroke-width="1.5"/><line x1="20" y1="80" x2="180" y2="80" stroke="#333" stroke-width="2"/><line x1="20" y1="100" x2="190" y2="100" stroke="#333" stroke-width="2.5"/><line x1="20" y1="120" x2="180" y2="120" stroke="#333" stroke-width="2"/><line x1="20" y1="140" x2="160" y2="140" stroke="#333" stroke-width="1.5"/>'),
          generateEffectSVG("Dust Cloud", '<circle cx="60" cy="130" r="20" fill="#ddd" opacity="0.6"/><circle cx="90" cy="125" r="25" fill="#ccc" opacity="0.5"/><circle cx="120" cy="130" r="18" fill="#ddd" opacity="0.4"/><circle cx="140" cy="128" r="12" fill="#eee" opacity="0.3"/>'),
          generateEffectSVG("Motion Blur", '<rect x="30" y="85" width="140" height="30" rx="15" fill="#333" opacity="0.15"/><rect x="50" y="90" width="120" height="20" rx="10" fill="#333" opacity="0.1"/>'),
          generateEffectSVG("Wind", '<path d="M20,70 Q60,60 100,70 Q140,80 180,70" fill="none" stroke="#aaa" stroke-width="2"/><path d="M30,100 Q70,90 110,100 Q150,110 180,95" fill="none" stroke="#aaa" stroke-width="1.5"/><path d="M40,130 Q80,120 120,130 Q160,140 180,125" fill="none" stroke="#aaa" stroke-width="1"/>'),
        ],
      },
      {
        id: "particles",
        name: "Particles & Splatter",
        items: [
          generateEffectSVG("Blood Splatter", '<circle cx="100" cy="100" r="25" fill="#8b0000"/><circle cx="80" cy="70" r="10" fill="#8b0000"/><circle cx="130" cy="80" r="8" fill="#8b0000"/><circle cx="75" cy="120" r="12" fill="#8b0000"/><circle cx="120" cy="130" r="6" fill="#8b0000"/><circle cx="60" cy="95" r="4" fill="#8b0000"/><circle cx="140" cy="110" r="5" fill="#8b0000"/>'),
          generateEffectSVG("Sparks", '<line x1="100" y1="100" x2="60" y2="40" stroke="#ffd700" stroke-width="2"/><line x1="100" y1="100" x2="150" y2="50" stroke="#ffd700" stroke-width="2"/><line x1="100" y1="100" x2="160" y2="120" stroke="#ffd700" stroke-width="1.5"/><line x1="100" y1="100" x2="50" y2="140" stroke="#ffd700" stroke-width="1.5"/><circle cx="60" cy="40" r="3" fill="#fff"/><circle cx="150" cy="50" r="3" fill="#fff"/>'),
          generateEffectSVG("Smoke Puff", '<circle cx="100" cy="100" r="35" fill="#999" opacity="0.3"/><circle cx="80" cy="85" r="25" fill="#aaa" opacity="0.25"/><circle cx="120" cy="80" r="28" fill="#bbb" opacity="0.2"/><circle cx="100" cy="70" r="20" fill="#ccc" opacity="0.15"/>'),
          generateEffectSVG("Fire Burst", '<path d="M100,40 Q120,70 110,100 Q100,80 90,100 Q80,70 100,40Z" fill="#ff4500" opacity="0.8"/><path d="M80,60 Q90,80 85,110 Q80,90 75,110 Q70,80 80,60Z" fill="#ff6600" opacity="0.6"/><path d="M120,55 Q130,75 125,105 Q120,85 115,105 Q110,75 120,55Z" fill="#ff6600" opacity="0.6"/>'),
          generateEffectSVG("Stars", '<polygon points="40,30 43,40 53,40 45,47 48,57 40,50 32,57 35,47 27,40 37,40" fill="#ffd700"/><polygon points="100,50 103,60 113,60 105,67 108,77 100,70 92,77 95,67 87,60 97,60" fill="#ffd700"/><polygon points="150,25 153,35 163,35 155,42 158,52 150,45 142,52 145,42 137,35 147,35" fill="#ffd700"/>'),
          generateEffectSVG("Rain", '<line x1="30" y1="20" x2="25" y2="40" stroke="#4fc3f7" stroke-width="1.5"/><line x1="60" y1="10" x2="55" y2="30" stroke="#4fc3f7" stroke-width="1.5"/><line x1="90" y1="25" x2="85" y2="45" stroke="#4fc3f7" stroke-width="1.5"/><line x1="120" y1="15" x2="115" y2="35" stroke="#4fc3f7" stroke-width="1.5"/><line x1="150" y1="20" x2="145" y2="40" stroke="#4fc3f7" stroke-width="1.5"/><line x1="45" y1="50" x2="40" y2="70" stroke="#4fc3f7" stroke-width="1.5"/><line x1="75" y1="45" x2="70" y2="65" stroke="#4fc3f7" stroke-width="1.5"/><line x1="105" y1="55" x2="100" y2="75" stroke="#4fc3f7" stroke-width="1.5"/><line x1="135" y1="40" x2="130" y2="60" stroke="#4fc3f7" stroke-width="1.5"/>'),
        ],
      },
    ],
  },
  {
    id: "stickers",
    name: "Stickers",
    icon: "😎",
    subcategories: [
      {
        id: "emojis",
        name: "Emoji Pack",
        items: ["😀","😂","🤣","😎","🥶","🤯","😱","💀","☠️","👻","🔥","💥","⚡","💫","✨","🩸","🎯","🏆","🎮","🎬","🎨","🎸","🎤","🥊","⚔️","🔫","💣","🧨","🪓","🏹","🛡️","🗡️","🔪","🩹","💊","❤️","💔","💯","🆘","⛔"].map((emoji, i) => ({
          id: `emoji-${i}`,
          name: emoji,
          url: `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80"><text x="40" y="58" text-anchor="middle" font-size="50">${emoji}</text></svg>`)}`,
          tags: ["sticker", "emoji"],
        })),
      },
      {
        id: "comic-text",
        name: "Comic Text",
        items: ["WHAM!", "CRACK!", "SMASH!", "ZAP!", "SLASH!", "THUD!", "CRASH!", "SPLAT!", "WHOOSH!", "KABOOM!"].map((text, i) => {
          const colors = ["#ff2d55", "#ff6600", "#ffd700", "#00ff00", "#00bfff", "#ff00ff", "#ff4500", "#8b0000", "#4169e1", "#dc143c"];
          return generateEffectSVG(text, `<text x="100" y="110" text-anchor="middle" font-size="32" font-weight="bold" fill="${colors[i]}" stroke="white" stroke-width="2" paint-order="stroke">${text}</text>`);
        }),
      },
    ],
  },
];

// Count total assets
const TOTAL_ASSETS = CATEGORIES.reduce((sum, cat) =>
  sum + cat.subcategories.reduce((s, sub) => s + sub.items.length, 0), 0);

export default function ImageVault({ visible, onClose, onSelectImage }: Props) {
  const [selectedCategory, setSelectedCategory] = useState<Category | null>(null);
  const [selectedSubcategory, setSelectedSubcategory] = useState<Subcategory | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [loadingId, setLoadingId] = useState<string | null>(null);

  // Search across all assets
  const searchResults = useMemo(() => {
    if (!searchQuery.trim()) return null;
    const q = searchQuery.toLowerCase();
    const results: ImageAsset[] = [];
    for (const cat of CATEGORIES) {
      for (const sub of cat.subcategories) {
        for (const item of sub.items) {
          if (item.name.toLowerCase().includes(q) || item.tags.some(t => t.includes(q))) {
            results.push(item);
          }
        }
      }
    }
    return results;
  }, [searchQuery]);

  if (!visible) return null;

  const handleSelect = (asset: ImageAsset) => {
    setLoadingId(asset.id);
    onSelectImage(asset.url, asset.name);
    setTimeout(() => setLoadingId(null), 500);
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
          {selectedSubcategory?.name ?? selectedCategory?.name ?? "Image Vault"}
        </h2>
        <span className="text-[10px] text-[#555]">{TOTAL_ASSETS}+ assets</span>
      </div>

      {/* Search */}
      <div className="px-4 py-2 shrink-0">
        <div className="flex items-center gap-2 bg-[#1a1a24] rounded-xl px-3 py-2 border border-[#2a2a3a]">
          <Search size={16} className="text-[#555]" />
          <input
            type="text"
            placeholder="Search images..."
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
            <div className="grid grid-cols-4 gap-2">
              {searchResults.map((asset) => (
                <AssetTile key={asset.id} asset={asset} onClick={() => handleSelect(asset)} loading={loadingId === asset.id} />
              ))}
            </div>
          </div>
        ) : !selectedCategory ? (
          /* Category grid */
          <div className="space-y-3 pt-2">
            {CATEGORIES.map((cat) => {
              const count = cat.subcategories.reduce((s, sub) => s + sub.items.length, 0);
              return (
                <button
                  key={cat.id}
                  onClick={() => setSelectedCategory(cat)}
                  className="w-full flex items-center gap-4 p-4 bg-[#111118] rounded-2xl border border-[#2a2a3a] hover:border-[#3a3a4a] transition-colors"
                >
                  <span className="text-3xl">{cat.icon}</span>
                  <div className="text-left flex-1">
                    <span className="text-white font-semibold text-sm">{cat.name}</span>
                    <span className="text-[#555] text-xs ml-2">{count} items</span>
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
                <div className="w-12 h-12 rounded-xl bg-[#1a1a24] border border-[#2a2a3a] flex items-center justify-center overflow-hidden">
                  {sub.items[0] && (
                    <img src={sub.items[0].url} alt="" className="w-10 h-10 object-contain" />
                  )}
                </div>
                <div className="text-left flex-1">
                  <span className="text-white font-semibold text-sm">{sub.name}</span>
                  <span className="text-[#555] text-xs ml-2">{sub.items.length} items</span>
                </div>
                <ChevronLeft size={16} className="text-[#555] rotate-180" />
              </button>
            ))}
          </div>
        ) : (
          /* Asset grid */
          <div className="grid grid-cols-4 gap-2 pt-2">
            {selectedSubcategory.items.map((asset) => (
              <AssetTile key={asset.id} asset={asset} onClick={() => handleSelect(asset)} loading={loadingId === asset.id} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function AssetTile({ asset, onClick, loading }: { asset: ImageAsset; onClick: () => void; loading: boolean }) {
  return (
    <button
      onClick={onClick}
      className="relative aspect-square rounded-xl bg-[#111118] border border-[#2a2a3a] hover:border-[#ff2d55]/40 overflow-hidden transition-all hover:scale-[1.02] active:scale-95 group"
    >
      <img
        src={asset.url}
        alt={asset.name}
        className="w-full h-full object-contain p-1"
        loading="lazy"
      />
      {/* Name overlay on hover */}
      <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 to-transparent opacity-0 group-hover:opacity-100 transition-opacity p-1">
        <span className="text-[9px] text-white truncate block">{asset.name}</span>
      </div>
      {/* Loading spinner */}
      {loading && (
        <div className="absolute inset-0 bg-black/50 flex items-center justify-center">
          <Loader2 size={20} className="text-[#ff2d55] animate-spin" />
        </div>
      )}
    </button>
  );
}
