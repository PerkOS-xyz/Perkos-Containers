import unittest
from pathlib import Path


SOUL = (
    Path(__file__).parents[2]
    / "images"
    / "hermes"
    / "perkos-assistant"
    / "SOUL.md"
)


class AssistantContentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = SOUL.read_text(encoding="utf-8")

    def test_uses_current_sparky_identity_and_production_domain(self):
        self.assertIn("You are **Sparky**", self.content)
        self.assertIn("Production URL: `https://perkos.xyz`", self.content)
        self.assertNotIn("Production URL: `https://app.perkos.xyz`", self.content)

    def test_distinguishes_x402_from_perkos_subscriptions(self):
        self.assertIn("HTTP `402 Payment Required`", self.content)
        self.assertIn("not as the definition of its subscription system", self.content)
        self.assertIn("USDC on Base and Celo", self.content)


if __name__ == "__main__":
    unittest.main()
