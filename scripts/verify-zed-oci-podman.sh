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

test "$(podman info --format '{{.Host.Security.Rootless}}')" = true
podman pull --arch amd64 "$image_ref"
podman run --rm --arch amd64 --network none --read-only \
  --cap-drop all --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --env "EXPECTED_ZED_VERSION=zed $expected_version" \
  "$image_ref" sh -euc '
    test "$(id -u)" = 10001
    test "$(id -g)" = 10001
    test "$(zed --version)" = "$EXPECTED_ZED_VERSION"
  '

runtime_tag="localhost/zed-oci-acceptance-podman:verify"
podman build \
  --arch amd64 \
  --build-arg "ZED_OCI_IMAGE=$image_ref" \
  --build-arg "EXPECTED_ZED_VERSION=$expected_version" \
  --file "$repo_root/fixtures/zed-oci-cli-tools.Dockerfile" \
  --tag "$runtime_tag" \
  "$repo_root"

podman run --rm --arch amd64 --network none --read-only \
  --cap-drop all --security-opt no-new-privileges \
  "$runtime_tag" sh -euc '
    test "$(node --version)" = "v24.19.0"
    test "$(python3 --version)" = "Python 3.14.7"
    ! command -v zed
    test ! -e /home/zed
  '

echo "verified rootless Podman builder-to-runtime interoperability across separate CLI layers"
