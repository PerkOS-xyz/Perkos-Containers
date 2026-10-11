# A2A 0.12.71 consumer release

## Scope and decision

The approved continuation updates release consumers, then validates coordinated Dev before QA/production. A2A 0.12.71 is already published from merge 437534b39c7c579a9b890dfcd35f476642ac9ee2. Its canonical npm tarball has SHA256 69a38789fc89075aa377d49b9b33408a3af82d3187f950d70f8c84261ddfd982 and SHA512 matching registry metadata. Preserve existing archives, including separately served 0.12.70.

Alternatives: use mutable latest (not reproducible); require the application artifact to be deployed in production before building (unnecessary environment coupling); or build from the immutable published npm version with the verified hash. Choose the third; still add the identical archive and checksum to App for native invitations and rollout parity.

## Changes

App adds the published archive/checksum and regression coverage without changing framework routes, flags, authentication or old artifacts. API updates native invitation version/hash and public Docker default in lockstep. The managed ECR default uses the same semver; Dev operations must verify the published image digest and override with its exact CI-stamped tag before rollout. No reprovision or private-agent upgrade follows from changing a default.

Containers aligns workflow, Dockerfile and compose version/hash. Artifact base URL is explicitly configurable and defaults to the canonical npm registry path; all paths retain checksum verification. A release selector limits bridge-only pushes and manual bridge dispatch to the bridge job. Existing runtime builds and behavior tests remain available for runtime changes or explicit all dispatch. Missing Git history/input fails closed. Bridge-only releases publish versioned ECR/GHCR references without moving latest; full releases retain existing aliases. Add a network-isolated bridge package/actor smoke and local scope/pin tests.

Native OpenClaw invitations download the identical verified archive from npm too, so a Dev API release does not depend on first deploying App production. App retains the matching mirror for compatibility and verification. PR CI builds/smokes the installed bridge package without publication or cloud-agent provisioning.

## Verification and rollout

Validate archive hashes and manifests, focused/full App and API tests/types, Container pin/scope tests, script syntax and CI. Docker CI must inspect and smoke the installed 0.12.71 package, actor claim and compiled emitters. No real cloud runtime is provisioned by bridge-only CI. Human merges precede the coordinated Dev release. Record exact revisions/digests and rollback; preserve private Compose layers, flags, idle policy and credentials. Deploy only after image/actor compatibility and synthetic checks pass.

New server-created conversations or approved provenance migration are required for legacy data. Do not infer authority from editable metadata or backfill. A real managed-agent E2E requires a known authorized test agent and budget; no private host access, gateway restart, secret/identity logging, automatic private-agent update, QA/Prod promotion, payment activation or public signup in this preparation stage.

## Approved follow-up: native multi-platform publication

Containers80 merged as 0bacc376d6992eb6c485498838b3bcb57d6f040e. Its main unit CI passed, and release38104525835 selected bridge-only: runtime/paid behavior jobs were skipped. The installed amd64 image passed its smoke. Multi-platform publication failed during arm64 npm dependency preparation with QEMU SIGILL. No image release or Dev rollout is certified by that run. App470 and API347 main CI passed.

The user explicitly approved repairing this pipeline with native amd64 and arm64 runners. Alternatives are retrying the recurring emulator crash, dropping arm64, or building/testing each architecture natively. Select native runners; keep both architectures, the published package/hash, runtime behavior and environment scope unchanged. Standard GitHub-hosted runners are available for this public repository; no VPS/cloud agent or private runtime is needed.

Graph: release-scope -> native build/smoke matrix -> successful matrix gate -> publish verified image archives -> assemble/verify OCI indexes -> version aliases. Each native job builds and runs the existing network-isolated installed-package/actor smoke. It exports the exact tested image and checksum into a run-scoped artifact with one-day retention, without registry credentials. PR CI runs the same two native builds without publication.

Only after both build jobs succeed does a separate publisher download/check the two archives, validate loaded architecture/version/revision, and push those exact images under CI-stamped per-platform references. No second npm install/build can introduce an untested image. Assemble CI-stamped indexes in ECR/GHCR, verify both architecture descriptors and expected child digests, and require registry parity before moving the semver alias. Bridge-only still never moves latest; full scope retains its existing aliases. Artifact failure, missing architecture, revision mismatch or registry verification failure prevents successful publication. Cross-registry alias changes are not atomic; deployments use verified immutable CI tags/digests, never assume a failed publish completed.

Regressions cover native runner mappings, no bridge QEMU, both-smoke publication gate, image transfer checks, index validation, scope/pins and latest behavior. Human merge and successful exact-main publication/index verification remain necessary before Dev. No runtime provisioning, agents, gateways, credentials changes, QA/Prod deployment or public opening.

References: https://docs.github.com/en/actions/reference/runners/github-hosted-runners and https://docs.docker.com/build/ci/github-actions/multi-platform/ .
