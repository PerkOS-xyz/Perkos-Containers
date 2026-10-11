from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERSION = "0.12.72"
SHA256 = "8ca6552cc3f03ce2e57958159900ffd7f0298f04a9e58d356188137a94941647"
BASE_URL = "https://registry.npmjs.org/@perkos/perkos-a2a/-"


class ReleasePinTests(unittest.TestCase):
    def test_workflow_dockerfile_and_compose_pins_agree(self):
        dockerfile = (ROOT / "images/perkos-a2a-bridge/Dockerfile").read_text()
        workflow = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        compose = (ROOT / "deploy/perkos-assistant/docker-compose.yml").read_text()
        self.assertIn(f"ARG PERKOS_A2A_VERSION={VERSION}\n", dockerfile)
        self.assertIn(f"ARG PERKOS_A2A_SHA256={SHA256}\n", dockerfile)
        self.assertIn(f"ARG PERKOS_A2A_ARTIFACT_BASE_URL={BASE_URL}\n", dockerfile)
        self.assertIn(f"  PERKOS_A2A_VERSION: {VERSION}\n", workflow)
        self.assertIn(f"  PERKOS_A2A_SHA256: {SHA256}\n", workflow)
        self.assertIn(f"  PERKOS_A2A_ARTIFACT_BASE_URL: {BASE_URL}\n", workflow)
        self.assertEqual(compose.count(f'PERKOS_A2A_VERSION: "{VERSION}"'), 2)
        self.assertEqual(compose.count(f'PERKOS_A2A_SHA256: "{SHA256}"'), 2)
        self.assertIn(f'PERKOS_A2A_ARTIFACT_BASE_URL: "{BASE_URL}"', compose)
        self.assertIn('"${PERKOS_A2A_ARTIFACT_BASE_URL}/perkos-a2a-${PERKOS_A2A_VERSION}.tgz"', dockerfile)
        self.assertIn('sha256sum -c -', dockerfile)

    def test_heavy_jobs_are_gated_by_successful_scope_selection(self):
        workflow = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z0-9-]+):\n(.*?)(?=^  [a-z0-9-]+:|\Z)", workflow, re.M | re.S))
        for job in ("build-hermes", "build-openclaw", "build-zeroclaw", "behavior-test"):
            self.assertIn("release-scope", jobs[job])
            self.assertIn("if: needs.release-scope.outputs.scope == 'all'", jobs[job])
        bridge = jobs["build-perkos-a2a-bridge"]
        self.assertIn("needs: release-scope", bridge)
        self.assertEqual(bridge.count("PERKOS_A2A_ARTIFACT_BASE_URL=${{ env.PERKOS_A2A_ARTIFACT_BASE_URL }}"), 2)
        self.assertIn('if [[ "$RELEASE_SCOPE" == "all" ]]; then', bridge)
        self.assertIn("tags: ${{ steps.tags.outputs.publish_tags }}", bridge)
        self.assertIn('${ECR_REGISTRY}/perkos-a2a-bridge:${PERKOS_A2A_VERSION}', bridge)
        self.assertIn("scripts/select-build-scope.py", jobs["release-scope"])
        self.assertIn("fetch-depth: 0", jobs["release-scope"])

    def test_pr_verifies_real_image_without_publish_or_cloud_credentials(self):
        workflow = (ROOT / ".github/workflows/unit-tests.yml").read_text()
        job = workflow.split("  a2a-installed-package:\n", 1)[1].split("  perkos-tools-python:\n", 1)[0]
        self.assertIn("push: false", job)
        self.assertIn(f"smoke.sh perkos-a2a-bridge:test {VERSION}", job)
        self.assertNotIn("secrets.", job)
        smoke = (ROOT / "tests/perkos-a2a-bridge/smoke.sh").read_text()
        self.assertEqual(smoke.count("docker run"), 5)  # Four invocations + error text.
        self.assertEqual(smoke.count("--network none"), 4)

    def test_bridge_scope_never_moves_latest_aliases(self):
        workflow = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        bridge = workflow.split("  build-perkos-a2a-bridge:\n", 1)[1]
        script = textwrap.dedent(re.search(r"        run: \|\n((?:          [^\n]*\n)+)", bridge).group(1))
        for scope in ("bridge", "all"):
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "outputs"
                env = {**os.environ, "TAG_SUFFIX": "", "RELEASE_SCOPE": scope,
                       "GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(output),
                       "PERKOS_A2A_VERSION": VERSION, "ECR_REGISTRY": "ecr.example",
                       "GHCR_ORG": "ghcr.example"}
                subprocess.run(["bash", "-e", "-c", script], env=env, check=True, capture_output=True)
                tags = output.read_text()
                self.assertIn(f"ecr.example/perkos-a2a-bridge:{VERSION}\n", tags)
                self.assertIn(f"ghcr.example/perkos-a2a:{VERSION}\n", tags)
                self.assertEqual(tags.count(":latest\n"), 2 if scope == "all" else 0)

    def test_tag_suffix_is_not_interpolated_as_shell_code(self):
        workflow = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        bridge = workflow.split("  build-perkos-a2a-bridge:\n", 1)[1]
        script = textwrap.dedent(re.search(r"        run: \|\n((?:          [^\n]*\n)+)", bridge).group(1))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {**os.environ, "TAG_SUFFIX": "$(exit 0)", "RELEASE_SCOPE": "bridge",
                   "GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(output)}
            result = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
