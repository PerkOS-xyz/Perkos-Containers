import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "images" / "hermes" / "patch-managed-runtime.py"
SPEC = importlib.util.spec_from_file_location("patch_managed_runtime", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture(guard: str) -> str:
    return f'''import logging

logger = logging.getLogger(__name__)

async def handle(self, history):
        {guard}
            return "onboard"
'''


class PatchManagedRuntimeTest(unittest.TestCase):
    def test_patches_async_session_store_guard(self):
        patched = MODULE.patch_source(fixture(MODULE.FIRST_MESSAGE_GUARDS[0]))
        self.assertIn("await self.async_session_store.has_any_sessions()", patched)
        self.assertIn("PERKOS_DISABLE_FIRST_MESSAGE_ONBOARDING", patched)

    def test_patches_legacy_sync_session_store_guard(self):
        patched = MODULE.patch_source(fixture(MODULE.FIRST_MESSAGE_GUARDS[1]))
        self.assertIn("self.session_store.has_any_sessions()", patched)
        self.assertIn("PERKOS_DISABLE_FIRST_MESSAGE_ONBOARDING", patched)

    def test_fails_closed_when_upstream_anchor_is_unknown(self):
        with self.assertRaisesRegex(RuntimeError, "expected exactly one supported"):
            MODULE.patch_source(fixture("if not history:"))


if __name__ == "__main__":
    unittest.main()
