// ═══════════════════════════════════════════════════════════════════
// Spatter AI Brain — 1,100 Knowledge Modules Engine
// ═══════════════════════════════════════════════════════════════════

import brainData from "./spatterBrainData.json";

export interface BrainModule {
  id: string;
  title: string;
  category: string;
  summary: string;
  keywords: string[];
  knowledge: Record<string, unknown>;
}

export const SPATTER_BRAIN: BrainModule[] = brainData as BrainModule[];

// Search brain for relevant modules
export function searchBrain(query: string): BrainModule[] {
  const q = query.toLowerCase();
  const words = q.split(/\s+/).filter(w => w.length > 2);

  const scored: [BrainModule, number][] = SPATTER_BRAIN.map(m => {
    let score = 0;
    for (const word of words) {
      if (m.title.toLowerCase().includes(word)) score += 10;
      if (m.category.toLowerCase().includes(word)) score += 5;
      if (m.summary.toLowerCase().includes(word)) score += 3;
      if (m.keywords.some(k => k.includes(word))) score += 2;
    }
    return [m, score] as [BrainModule, number];
  });

  return scored
    .filter(([, s]) => s > 0)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5)
    .map(([m]) => m);
}

// Generate Spatter AI response using brain knowledge
export function getSpatterBrainResponse(
  userMsg: string,
  frameCount: number,
  layerCount: number,
  _toolActive: string,
): string {
  const relevant = searchBrain(userMsg);

  if (relevant.length === 0) {
    return `Working with ${frameCount} frame${frameCount !== 1 ? 's' : ''} and ${layerCount} layer${layerCount !== 1 ? 's' : ''} — looking solid!\n\nI can help with:\n🦴 Poses & anatomy\n🎬 Animation techniques\n🥊 Fight choreography\n🎨 Color & style advice\n📤 Export & sharing\n🎵 Sound design\n\nWhat do you want to work on? 💀🎨`;
  }

  const top = relevant[0];
  const k = top.knowledge as Record<string, unknown>;

  switch (top.category) {
    case 'Core Identity':
    case 'Lore':
      return buildIdentityResponse(top, k);
    case 'Studio Tools':
      return buildToolResponse(top, k);
    case 'Animation':
      return buildAnimationResponse(top, k, frameCount);
    case 'Studio Systems':
      return buildSystemResponse(top, k);
    case 'AI Animation':
      return buildAIResponse(top, k);
    case 'Social':
      return buildSocialResponse(top, k);
    case 'Collaboration':
      return buildCollabResponse(top, k);
    case 'Business':
      return buildBusinessResponse(top, k);
    case 'Audio':
      return buildAudioResponse(top, k);
    case 'Advanced':
      return buildAdvancedResponse(top, k);
    case 'UX':
      return buildUXResponse(top, k);
    case 'Community':
      return buildCommunityResponse(top, k);
    default:
      return buildGenericResponse(top, k, frameCount, layerCount);
  }
}

function arr(v: unknown): string[] {
  return Array.isArray(v) ? v.filter(x => typeof x === 'string') as string[] : [];
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function buildIdentityResponse(m: BrainModule, k: Record<string, unknown>): string {
  const traits = arr(k['traits']);
  const mission = str(k['mission']);
  if (m.id.includes('personality')) {
    return `I'm Spatter — ${traits.slice(0, 4).join(', ')}. ${mission || 'Here to help you create.'} 💀🎨\n\nWhat do you want to work on?`;
  }
  const roles = arr(k['spatterIs']);
  if (roles.length) {
    return `I'm your ${roles.slice(0, 3).join(', ')}. Not just a chatbot — I'm the creative operating system of StickDeath ∞.\n\nI can help with poses, timing, effects, audio, export... what do you need? 🔥`;
  }
  return `${m.summary}\n\nAsk me anything about the studio! 💀`;
}

function buildToolResponse(m: BrainModule, k: Record<string, unknown>): string {
  const purpose = str(k['purpose']);
  const panel = arr(k['panel']);
  const rules = arr(k['rules']);
  let resp = `🛠️ ${m.title}\n\nPurpose: ${purpose}\n`;
  if (panel.length) resp += `\nSettings: ${panel.join(' · ')}\n`;
  if (rules.length) resp += `\nPro tips:\n${rules.slice(0, 3).map(r => '• ' + r).join('\n')}`;
  return resp;
}

function buildAnimationResponse(m: BrainModule, k: Record<string, unknown>, frameCount: number): string {
  let resp = `🎬 ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val) && val.length) resp += `${key}: ${arr(val).slice(0, 4).join(' → ')}\n`;
    else if (typeof val === 'string') resp += `${key}: ${val}\n`;
  }
  resp += `\nYour project: ${frameCount} frame${frameCount !== 1 ? 's' : ''}. `;
  if (frameCount < 4) resp += 'Add more frames for smoother motion!';
  else if (frameCount < 12) resp += 'Good foundation — keep building keyframes.';
  else resp += 'Strong frame count — focus on timing and easing!';
  return resp;
}

function buildSystemResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `⚙️ ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `${key}:\n${arr(val).slice(0, 4).map(v => '  • ' + v).join('\n')}\n`;
  }
  return resp;
}

function buildAIResponse(m: BrainModule, k: Record<string, unknown>): string {
  const pipeline = arr(k['pipeline']);
  const output = arr(k['output']);
  let resp = `🤖 ${m.title}\n\n${m.summary}\n\n`;
  if (pipeline.length) resp += `Pipeline: ${pipeline.join(' → ')}\n`;
  if (output.length) resp += `Output: ${output.join(', ')}\n`;
  return resp;
}

function buildSocialResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `📱 ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `${key}: ${arr(val).slice(0, 5).join(', ')}\n`;
  }
  return resp;
}

function buildCollabResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `🤝 ${m.title}\n\n${m.summary}\n\n`;
  for (const [, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `• ${arr(val).slice(0, 3).join(', ')}\n`;
  }
  return resp;
}

function buildBusinessResponse(m: BrainModule, _k: Record<string, unknown>): string {
  return `📊 ${m.title}\n\n${m.summary}\n\nThis is handled by the platform. Ask me about animation instead! 💀`;
}

function buildAudioResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `🎵 ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `${key}: ${arr(val).slice(0, 4).join(', ')}\n`;
  }
  resp += '\nCheck the Sound Library — 1,000+ effects across 15 categories! 🔊';
  return resp;
}

function buildAdvancedResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `✨ ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (typeof val === 'string') resp += `${key}: ${val}\n`;
    else if (Array.isArray(val)) resp += `${key}: ${arr(val).slice(0, 3).join(' · ')}\n`;
  }
  return resp;
}

function buildUXResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `📲 ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `${key}:\n${arr(val).slice(0, 4).map(v => '  • ' + v).join('\n')}\n`;
    else if (typeof val === 'string') resp += `${key}: ${val}\n`;
  }
  return resp;
}

function buildCommunityResponse(m: BrainModule, k: Record<string, unknown>): string {
  let resp = `👥 ${m.title}\n\n${m.summary}\n\n`;
  for (const [key, val] of Object.entries(k)) {
    if (Array.isArray(val)) resp += `${key}: ${arr(val).slice(0, 4).join(', ')}\n`;
  }
  return resp;
}

function buildGenericResponse(m: BrainModule, k: Record<string, unknown>, _frameCount: number, _layerCount: number): string {
  let resp = `💀 ${m.title}\n\n${m.summary}\n\n`;
  const entries = Object.entries(k);
  for (const [key, val] of entries.slice(0, 3)) {
    if (typeof val === 'string') resp += `${key}: ${val}\n`;
    else if (Array.isArray(val)) resp += `${key}: ${arr(val).slice(0, 3).join(', ')}\n`;
  }
  return resp;
}
