"""The suggested-prompt allowlist must be identical in the handler,
the SQL meter and the iOS chips (#209). Source-only
check: reads the three files, runs nothing else."""
import re
import unittest
from pathlib import Path

from backend.spatter import suggested_prompts

ROOT = Path(__file__).resolve().parents[2]


class SuggestedPromptAllowlistTests(unittest.TestCase):
    def test_sql_allowlist_matches_python(self):
        sql = (ROOT / "backend/sql/spatter-draft-jobs.sql").read_text()
        match = re.search(r"spatter_suggested_prompt_ids\(\).*?select array\[(.*?)\]::text\[\]", sql, re.S)
        self.assertIsNotNone(match)
        ids = tuple(re.findall(r"'([a-z_]+)'", match.group(1)))
        self.assertEqual(ids, suggested_prompts.SUGGESTED_PROMPT_IDS)

    def test_ios_chips_match_python_ids_and_labels(self):
        swift = (ROOT / "StickDeathInfinity/App/SpatterBackendClient.swift").read_text()
        block = swift.split("static let all: [SpatterSuggestedPrompt] = [", 1)[1].split("]", 1)[0]
        entries = re.findall(r'\.init\(id: "([a-z_]+)", label: "([^"]+)"', block)
        self.assertEqual(tuple(i for i, _ in entries), suggested_prompts.SUGGESTED_PROMPT_IDS)
        self.assertEqual([label for _, label in entries], [v[0] for v in suggested_prompts.SUGGESTED_PROMPTS.values()])

    def test_ids_are_validated_and_the_free_only_path_is_gone(self):
        # Owner decision 2026-10-15: Free is never served, so no Free-only message path exists.
        self.assertFalse(hasattr(suggested_prompts, "free_messages"))
        for prompt_id in suggested_prompts.SUGGESTED_PROMPT_IDS:
            self.assertEqual(suggested_prompts.validate_id(prompt_id), prompt_id)
        self.assertIsNone(suggested_prompts.validate_id(None))
        for bad in ("", "Animation tips", 7, "animation_tips "):
            with self.assertRaises(ValueError):
                suggested_prompts.validate_id(bad)


if __name__ == "__main__":
    unittest.main()
