#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <image-ref> <expected-version> <certificate-identity>" >&2
  exit 64
fi

image_ref="$1"
expected_version="$2"
certificate_identity="$3"

if [[ ! "$image_ref" =~ ^ghcr\.io/zed-pkg/zed-oci@sha256:[0-9a-f]{64}$ ]]; then
  echo "zed-oci target must be the canonical GHCR repository at an exact sha256 digest" >&2
  exit 64
fi
if [[ ! "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "expected Zed version must be a three-part semantic version" >&2
  exit 64
fi
if [[ ! "$certificate_identity" =~ ^https://github\.com/zed-pkg/zed-oci/\.github/workflows/publish\.yml@refs/(heads/main|tags/v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "certificate identity must be the canonical zed-oci publisher on main or an exact release tag" >&2
  exit 64
fi
if [[ "$certificate_identity" =~ @refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] \
  && [[ "${BASH_REMATCH[1]}" != "$expected_version" ]]; then
  echo "release certificate identity does not match expected Zed version" >&2
  exit 64
fi
