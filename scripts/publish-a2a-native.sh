#!/usr/bin/env bash
# Publish only archives produced by this run's successful native smoke matrix.
# No builds, runtime provisioning, credentials/identity dumps or QEMU here.
set -euo pipefail

fail() { echo "Bridge publication validation failed: $1" >&2; exit 1; }
digest_for() {
  local digest
  digest=$(docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}')
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "invalid registry digest"
  printf '%s' "$digest"
}

[[ "${RELEASE_SCOPE:-}" == bridge || "${RELEASE_SCOPE:-}" == all ]] || fail "invalid scope"
[[ "${BRIDGE_VERIFY_ONLY:-false}" == true || "${BRIDGE_VERIFY_ONLY:-false}" == false ]] || fail "invalid verification mode"
[[ "${GITHUB_SHA:-}" =~ ^[a-f0-9]{40}$ ]] || fail "missing source revision"
[[ "${PERKOS_A2A_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid package version"
[[ "${BRIDGE_IMAGE_TAG:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,110}$ ]] || fail "invalid image tag"
[[ "${ECR_REGISTRY:-}" =~ ^[a-z0-9.-]+$ ]] || fail "invalid ECR registry"
[[ "${GHCR_ORG:-}" =~ ^[a-z0-9.-]+/[a-z0-9_-]+$ ]] || fail "invalid GHCR namespace"
[[ -d "${BRIDGE_ARTIFACT_DIR:-}" ]] || fail "missing image artifacts"

repos=("${ECR_REGISTRY}/perkos-a2a-bridge" "${GHCR_ORG}/perkos-a2a")
arches=(amd64 arm64)
cd "$BRIDGE_ARTIFACT_DIR"

# Validate BOTH images before the first registry write. The publisher never
# executes an arm64 container on amd64; native execution already passed CI.
for arch in "${arches[@]}"; do
  archive="bridge-${arch}.tar.gz"
  [[ -f "$archive" && -f "${archive}.sha256" ]] || fail "missing native image archive"
  sha256sum --check "${archive}.sha256"
  gzip -dc "$archive" | docker load
  docker image inspect "perkos-a2a-bridge:test-${arch}" --format '{{json .}}' |
    jq -e --arg arch "$arch" --arg version "$PERKOS_A2A_VERSION" --arg revision "$GITHUB_SHA" '
      .Os == "linux" and .Architecture == $arch and
      .Config.Labels["perkos.a2a-version"] == $version and
      .Config.Labels["org.opencontainers.image.revision"] == $revision
    ' >/dev/null || fail "native image metadata mismatch"
done

if [[ "${BRIDGE_VERIFY_ONLY:-false}" == true ]]; then
  echo "Both tested native image archives verified; no registry writes."
  exit 0
fi

digests=()
for arch in "${arches[@]}"; do
  reference_digest=""
  for repo in "${repos[@]}"; do
    ref="${repo}:${BRIDGE_IMAGE_TAG}-${arch}"
    docker tag "perkos-a2a-bridge:test-${arch}" "$ref"
    docker push "$ref"
    digest=$(digest_for "$ref")
    [[ -z "$reference_digest" || "$digest" == "$reference_digest" ]] || fail "registry image parity mismatch"
    reference_digest="$digest"
  done
  digests+=("$reference_digest")
done
[[ "${digests[0]}" != "${digests[1]}" ]] || fail "architecture digests are identical"

# Validate immutable CI indexes and parity before touching semver/latest.
index_digest=""
for repo in "${repos[@]}"; do
  ci_ref="${repo}:${BRIDGE_IMAGE_TAG}"
  docker buildx imagetools create --tag "$ci_ref" "${repo}@${digests[0]}" "${repo}@${digests[1]}"
  docker buildx imagetools inspect "$ci_ref" --raw |
    jq -e --arg amd "${digests[0]}" --arg arm "${digests[1]}" '
      (.manifests | length == 2) and
      ([.manifests[] | {os: .platform.os, architecture: .platform.architecture, digest}] | sort_by(.architecture)) ==
      [{os: "linux", architecture: "amd64", digest: $amd}, {os: "linux", architecture: "arm64", digest: $arm}]
    ' >/dev/null || fail "OCI index does not match both tested images"
  digest=$(digest_for "$ci_ref")
  [[ -z "$index_digest" || "$digest" == "$index_digest" ]] || fail "registry index parity mismatch"
  index_digest="$digest"
done

for repo in "${repos[@]}"; do
  aliases=("$PERKOS_A2A_VERSION")
  # Bridge-only must never move either latest alias.
  if [[ "$RELEASE_SCOPE" == all ]]; then aliases+=(latest); fi
  for alias in "${aliases[@]}"; do
    ref="${repo}:${alias}"
    docker buildx imagetools create --tag "$ref" "${repo}@${index_digest}"
    [[ "$(digest_for "$ref")" == "$index_digest" ]] || fail "published alias digest mismatch"
  done
done

echo "Native bridge publication verified: ${PERKOS_A2A_VERSION}, linux/amd64 + linux/arm64."
echo "Verified OCI index digest: ${index_digest}"
