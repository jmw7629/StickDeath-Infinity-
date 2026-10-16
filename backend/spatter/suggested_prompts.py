"""Fixed server-side allowlist of Spatter suggested prompts (#209).

The ids match the suggestion chips
the iOS app offers (``SpatterSuggestedPrompt`` in
``StickDeathInfinity/App/SpatterBackendClient.swift``) and the SQL allowlist
``sdi_private.spatter_suggested_prompt_ids()`` in
``backend/sql/spatter-draft-jobs.sql``; ``test_suggested_prompts.py`` keeps the
three lists identical.

Owner decision 2026-10-15: the chips stay visible on Free, but Spatter does not
work on Free at all; the server refuses every Free request with
``upgrade_required`` before anything is counted or sent to a provider. A paid
(Creator or Pro) request may name one of these ids; an unknown id is refused.
The former Free-only canonical-message path (``free_messages``) was removed.
"""
from __future__ import annotations

from typing import Dict, Optional, Tuple

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


def validate_id(value: object) -> Optional[str]:
    """Return the id when it is on the allowlist, None when absent; raise ValueError otherwise."""
    if value is None:
        return None
    if not isinstance(value, str) or value not in SUGGESTED_PROMPTS:
        raise ValueError("unknown suggested prompt")
    return value
