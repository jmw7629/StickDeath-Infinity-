"""Fixed server-side allowlist of Spatter suggested prompts (#209, owner decision 2026-10-14).

Free accounts may only send one of these. The ids match the suggestion chips
the iOS app offers (``SpatterSuggestedPrompt`` in
``StickDeathInfinity/App/SpatterBackendClient.swift``) and the SQL allowlist
``sdi_private.spatter_suggested_prompt_ids()`` in
``backend/sql/spatter-draft-jobs.sql``; ``test_suggested_prompts.py`` keeps the
three lists identical.

For a Free request the handler discards every client-supplied message and sends
only ``FREE_SYSTEM`` plus the canonical prompt text below, so free text cannot
be smuggled through the conversation history or the client system prompt.
"""
from __future__ import annotations

from typing import Dict, List, Mapping, Optional, Tuple

# id -> (chip label shown in the app, canonical prompt text sent to the provider)
SUGGESTED_PROMPTS: Dict[str, Tuple[str, str]] = {
    "animation_tips": ("Animation tips",
                       "Give me three practical tips for making stick-figure animation feel smoother and more readable."),
    "scene_ideas": ("Scene ideas",
                    "Suggest three short stick-figure animation scene ideas I could build in the Studio."),
    "fight_choreography": ("Fight choreography",
                           "Explain how to choreograph a short, readable stick-figure fight: anticipation, impact and follow-through."),
    "style_advice": ("Style advice",
                     "Give me advice on developing a consistent visual style for my stick-figure animations."),
}
SUGGESTED_PROMPT_IDS: Tuple[str, ...] = tuple(SUGGESTED_PROMPTS)

FREE_SYSTEM = (
    "You are Spatter, the animation assistant of the StickDeath Infinity Studio. "
    "Give concise, practical stick-figure animation advice. You cannot edit, save, export or publish projects."
)


def validate_id(value: object) -> Optional[str]:
    """Return the id when it is on the allowlist, None when absent; raise ValueError otherwise."""
    if value is None:
        return None
    if not isinstance(value, str) or value not in SUGGESTED_PROMPTS:
        raise ValueError("unknown suggested prompt")
    return value


def free_messages(prompt_id: str) -> List[Mapping[str, str]]:
    """The only messages a Free request may send to the provider."""
    _label, text = SUGGESTED_PROMPTS[prompt_id]
    return [{"role": "system", "content": FREE_SYSTEM}, {"role": "user", "content": text}]
