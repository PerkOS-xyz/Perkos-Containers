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
