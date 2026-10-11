"""Publication orchestration tests with synthetic archives and a fake Docker CLI.

These exercise the real shell publisher and jq validations, not registry access
or real images. Native PR CI separately builds/smokes both installed images.
"""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
REVISION = "a" * 40
VERSION = "0.12.72"
TAG = "v0.12.72-perkos.2026.10.11.aaaaaaa"

FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
mode = os.environ.get("FAKE_MODE", "")
with open(os.environ["DOCKER_TRACE"], "a") as trace:
    trace.write(json.dumps(args) + "\n")
amd, arm, index = ["sha256:" + char * 64 for char in "abc"]
if args == ["load"]:
    sys.stdin.buffer.read()
elif args[:2] == ["image", "inspect"]:
    arch = "arm64" if args[2].endswith("arm64") else "amd64"
    labels = {"perkos.a2a-version": os.environ["PERKOS_A2A_VERSION"],
              "org.opencontainers.image.revision": os.environ["GITHUB_SHA"]}
    if arch == "arm64":
        if mode == "wrong-revision": labels["org.opencontainers.image.revision"] = "b" * 40
        if mode == "wrong-version": labels["perkos.a2a-version"] = "0.0.0"
        if mode == "wrong-architecture": arch = "amd64"
    print(json.dumps({"Os": "linux", "Architecture": arch, "Config": {"Labels": labels}}))
elif args[:3] == ["buildx", "imagetools", "inspect"]:
    ref = args[3]
    if "--raw" in args:
        manifests = [{"platform": {"os": "linux", "architecture": "amd64"}, "digest": amd},
                     {"platform": {"os": "linux", "architecture": "arm64"}, "digest": arm}]
        if mode == "missing-index-arm": manifests.pop()
        if mode == "wrong-index-child": manifests[1]["digest"] = amd
        if mode == "wrong-index-os": manifests[1]["platform"]["os"] = "windows"
        if mode == "extra-index-child": manifests.append(manifests[0])
        print(json.dumps({"manifests": manifests}))
    else:
        child = ref.endswith(("-amd64", "-arm64"))
        digest = amd if ref.endswith("-amd64") else arm if ref.endswith("-arm64") else index
        if mode == "image-parity" and child and ref.startswith("ghcr.example"):
            digest = "sha256:" + "d" * 64
        if mode == "index-parity" and not child and ref.startswith("ghcr.example"):
            digest = "sha256:" + "d" * 64
        if mode == "invalid-digest": digest = "not-a-digest"
        if mode == "alias-mismatch" and ref.endswith(":0.12.72"):
            digest = "sha256:" + "d" * 64
        print(digest)
elif args[:1] == ["push"] and mode == "push-fails":
    sys.exit(1)
elif args[:1] == ["tag"] or args[:3] == ["buildx", "imagetools", "create"] or args[:1] == ["push"]:
    pass
else:
    sys.exit("Unexpected fake Docker invocation")
'''


class NativeWorkflowTests(unittest.TestCase):
    def test_native_matrices_and_gated_credential_free_image_transfer(self):
        release = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        unit = (ROOT / ".github/workflows/unit-tests.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z0-9-]+):\n(.*?)(?=^  [a-z0-9-]+:|\Z)", release, re.M | re.S))
        build, publish = jobs["build-perkos-a2a-bridge"], jobs["publish-perkos-a2a-bridge"]
        for workflow in (build, unit.split("  a2a-installed-package:\n")[1].split("  perkos-tools-python:\n")[0]):
            self.assertIn("arch: amd64\n            runner: ubuntu-24.04", workflow)
            self.assertIn("arch: arm64\n            runner: ubuntu-24.04-arm", workflow)
            self.assertIn("runs-on: ${{ matrix.runner }}", workflow)
            self.assertIn("platforms: linux/${{ matrix.arch }}", workflow)
            self.assertIn("push: false", workflow)
            self.assertIn("smoke.sh", workflow)
            self.assertNotIn("setup-qemu", workflow)
            self.assertNotIn("secrets.", workflow)
            self.assertNotIn("configure-aws", workflow)
        self.assertIn("needs: [release-scope, build-perkos-a2a-bridge]", publish)
        self.assertNotIn("always()", publish)
        self.assertNotIn("continue-on-error", build + publish)
        self.assertNotIn("build-push-action", publish)
        self.assertNotIn("setup-qemu", publish)
        self.assertLess(build.index("run: ./tests/perkos-a2a-bridge/smoke.sh"), build.index("docker save"))
        self.assertIn("sha256sum", build)
        self.assertIn("retention-days: 1", build)
        self.assertIn("if-no-files-found: error", build)
        self.assertIn("pattern: bridge-image-*", publish)
        self.assertIn("cancel-in-progress: false", publish)
        transfer = unit.split("  a2a-native-archive-transfer:\n")[1].split("  perkos-tools-python:\n")[0]
        self.assertIn("needs: a2a-installed-package", transfer)
        self.assertIn('BRIDGE_VERIFY_ONLY: "true"', transfer)
        self.assertIn("run: ./scripts/publish-a2a-native.sh", transfer)
        self.assertNotIn("secrets.", transfer)
        self.assertNotIn("configure-aws", transfer)

    def test_tag_computation_accepts_safe_suffix_and_uses_source_revision(self):
        release = (ROOT / ".github/workflows/build-push-ecr.yml").read_text()
        publisher = release.split("  publish-perkos-a2a-bridge:\n")[1]
        script = textwrap.dedent(re.search(r"        run: \|\n((?:          [^\n]*\n)+)", publisher).group(1))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {**os.environ, "TAG_SUFFIX": "rc1", "RELEASE_SCOPE": "bridge",
                   "GITHUB_SHA": REVISION, "GITHUB_OUTPUT": str(output), "PERKOS_A2A_VERSION": VERSION}
            subprocess.run(["bash", "-e", "-c", script], env=env, check=True, capture_output=True)
            self.assertRegex(output.read_text(), r"^version=v0\.12\.72-perkos\.\d{4}\.\d{2}\.\d{2}\.aaaaaaa-rc1\n$")


@unittest.skipUnless(shutil.which("jq") and shutil.which("sha256sum"), "requires jq and sha256sum")
class NativePublisherTests(unittest.TestCase):
    def run_publisher(self, mode="", scope="bridge", archive_failure="", overrides=None):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            docker = fixture / "docker"
            docker.write_text(FAKE_DOCKER)
            docker.chmod(0o755)
            for arch in ("amd64", "arm64"):
                if archive_failure == "missing" and arch == "arm64":
                    continue
                archive = fixture / f"bridge-{arch}.tar.gz"
                archive.write_bytes(gzip.compress(b"synthetic image fixture"))
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                if archive_failure == "checksum" and arch == "arm64": digest = "0" * 64
                archive.with_suffix(".gz.sha256").write_text(f"{digest}  {archive.name}\n")
            trace = fixture / "trace.jsonl"
            env = {**os.environ, "PATH": f"{directory}:{os.environ['PATH']}", "FAKE_MODE": mode,
                   "DOCKER_TRACE": str(trace), "PERKOS_A2A_VERSION": VERSION, "GITHUB_SHA": REVISION,
                   "BRIDGE_IMAGE_TAG": TAG, "RELEASE_SCOPE": scope, "BRIDGE_ARTIFACT_DIR": directory,
                   "ECR_REGISTRY": "ecr.example", "GHCR_ORG": "ghcr.example/team"}
            env.update(overrides or {})
            result = subprocess.run(["bash", str(ROOT / "scripts/publish-a2a-native.sh")],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            return result, calls

    def aliases(self, calls):
        return [args[4] for args in calls if args[:4] == ["buildx", "imagetools", "create", "--tag"]
                and args[4].endswith((f":{VERSION}", ":latest"))]

    def test_valid_bridge_publishes_exact_images_and_never_latest(self):
        result, calls = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        pushes = [args for args in calls if args[0] == "push"]
        self.assertEqual(len(pushes), 4)
        self.assertEqual(len(self.aliases(calls)), 2)
        self.assertFalse(any(ref.endswith(":latest") for ref in self.aliases(calls)))
        self.assertEqual(sum(args == ["load"] for args in calls), 2)
        first_push = next(i for i, args in enumerate(calls) if args[0] == "push")
        self.assertEqual(sum(args[:2] == ["image", "inspect"] for args in calls[:first_push]), 2)
        first_alias = next(i for i, args in enumerate(calls) if args[:4] == ["buildx", "imagetools", "create", "--tag"]
                           and args[4].endswith(f":{VERSION}"))
        self.assertEqual(sum("--raw" in args for args in calls[:first_alias]), 2)
        self.assertFalse(any("build" in args for args in calls))

    def test_full_scope_retains_both_latest_aliases(self):
        result, calls = self.run_publisher(scope="all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.aliases(calls)), 4)
        self.assertEqual(sum(ref.endswith(":latest") for ref in self.aliases(calls)), 2)

    def test_verify_only_loads_both_images_without_registry_access(self):
        result, calls = self.run_publisher(overrides={"BRIDGE_VERIFY_ONLY": "true"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(args == ["load"] for args in calls), 2)
        self.assertEqual(sum(args[:2] == ["image", "inspect"] for args in calls), 2)
        self.assertFalse(any(args[0] in ("push", "tag", "buildx") for args in calls))

    def test_verify_only_still_rejects_corrupt_or_mismatched_images(self):
        for mode, archive in (("wrong-revision", ""), ("", "checksum")):
            with self.subTest(mode=mode, archive=archive):
                result, calls = self.run_publisher(mode=mode, archive_failure=archive,
                                                  overrides={"BRIDGE_VERIFY_ONLY": "true"})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(args[0] in ("push", "tag", "buildx") for args in calls))

    def test_archive_and_metadata_fail_before_any_push(self):
        cases = [("", "missing"), ("", "checksum"), ("wrong-revision", ""),
                 ("wrong-version", ""), ("wrong-architecture", "")]
        for mode, archive in cases:
            with self.subTest(mode=mode, archive=archive):
                result, calls = self.run_publisher(mode=mode, archive_failure=archive)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(args[0] == "push" for args in calls))
                self.assertFalse(self.aliases(calls))

    def test_registry_or_index_failures_prevent_alias_promotion(self):
        for mode in ("image-parity", "index-parity", "invalid-digest", "push-fails",
                     "missing-index-arm", "wrong-index-child", "wrong-index-os", "extra-index-child"):
            with self.subTest(mode=mode):
                result, calls = self.run_publisher(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.aliases(calls))

    def test_alias_digest_mismatch_never_reports_success(self):
        result, calls = self.run_publisher(mode="alias-mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("publication verified", result.stdout)
        self.assertEqual(len(self.aliases(calls)), 1)

    def test_untrusted_inputs_fail_before_docker(self):
        for overrides in ({"RELEASE_SCOPE": ""}, {"GITHUB_SHA": ""}, {"BRIDGE_IMAGE_TAG": "$(exit 0)"},
                          {"ECR_REGISTRY": "ecr.example;exit 0"}, {"GHCR_ORG": "ghcr.example/team/extra"},
                          {"BRIDGE_VERIFY_ONLY": "invalid"}):
            with self.subTest(overrides=overrides):
                result, calls = self.run_publisher(overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
