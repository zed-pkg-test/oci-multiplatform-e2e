#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <image-ref> <expected-version> <certificate-identity>" >&2
  exit 64
fi

image_ref="$1"
expected_version="$2"
certificate_identity="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/scripts/validate-zed-oci-target.sh" \
  "$image_ref" "$expected_version" "$certificate_identity"

for command in cosign docker jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

verification="$(mktemp)"
trap 'rm -f "$verification"' EXIT

cosign verify \
  --certificate-identity "$certificate_identity" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --output json \
  "$image_ref" > "$verification"

image_digest="${image_ref##*@}"
jq -e --arg digest "$image_digest" --arg image_ref "$image_ref" '
  type == "array"
  and length >= 1
  and all(.[]; .critical.image["docker-manifest-digest"] == $digest)
  and all(.[]; .critical.identity["docker-reference"] == $image_ref)
' "$verification"

manifest="$(docker buildx imagetools inspect --raw "$image_ref")"
jq -e '
  .mediaType == "application/vnd.oci.image.index.v1+json"
  and ([.manifests[]
        | select(.platform.os == "linux")
        | select(.platform.architecture == "amd64" or .platform.architecture == "arm64")
        | .digest] | sort) as $images
  | ([.manifests[]
      | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")
      | .annotations["vnd.docker.reference.digest"]] | sort) as $subjects
  | ($images | length) == 2
    and ($subjects | length) == 2
    and $images == $subjects
' <<<"$manifest"

while read -r attestation_digest; do
  attestation="$(docker buildx imagetools inspect --raw \
    "ghcr.io/zed-pkg/zed-oci@${attestation_digest}")"
  jq -e '
    .mediaType == "application/vnd.oci.image.manifest.v1+json"
    and .config.mediaType == "application/vnd.oci.empty.v1+json"
    and all(.layers[]; .mediaType == "application/vnd.in-toto+json")
    and ([.layers[].annotations["in-toto.io/predicate-type"]] | sort)
      == ["https://slsa.dev/provenance/v1", "https://spdx.dev/Document"]
  ' <<<"$attestation"
done < <(jq -r '
  .manifests[]
  | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")
  | .digest
' <<<"$manifest")

docker buildx imagetools inspect "$image_ref"
echo "verified signed zed-oci index, per-platform SBOMs, and SLSA provenance: $image_ref"
