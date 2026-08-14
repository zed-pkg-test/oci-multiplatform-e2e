#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <image-ref> <expected-version> <certificate-identity> <linux/architecture>" >&2
  exit 64
fi

image_ref="$1"
expected_version="$2"
certificate_identity="$3"
platform="$4"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tls_server_pid=""
tls_dir=""
binary_dir=""
container_id=""
abi_dir=""
abi_container_id=""

cleanup() {
  if [[ -n "$tls_server_pid" ]]; then
    kill "$tls_server_pid" >/dev/null 2>&1 || true
    wait "$tls_server_pid" 2>/dev/null || true
  fi
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$abi_container_id" ]]; then
    docker rm -f "$abi_container_id" >/dev/null 2>&1 || true
  fi
  if [[ -n "$tls_dir" && -d "$tls_dir" ]]; then
    find "$tls_dir" -depth -delete
  fi
  if [[ -n "$binary_dir" && -d "$binary_dir" ]]; then
    find "$binary_dir" -depth -delete
  fi
  if [[ -n "$abi_dir" && -d "$abi_dir" ]]; then
    find "$abi_dir" -depth -delete
  fi
}
trap cleanup EXIT

"$repo_root/scripts/validate-zed-oci-target.sh" \
  "$image_ref" "$expected_version" "$certificate_identity"

case "$platform" in
  linux/amd64|linux/arm64) architecture="${platform#linux/}" ;;
  *) echo "unsupported platform: $platform" >&2; exit 64 ;;
esac

case "$certificate_identity" in
  *@refs/heads/main) expected_label_version="edge" ;;
  *@refs/tags/v*) expected_label_version="$expected_version" ;;
  *) echo "unsupported certificate identity: $certificate_identity" >&2; exit 64 ;;
esac

manifest="$(docker buildx imagetools inspect --raw "$image_ref")"
platform_digests=()
while IFS= read -r digest; do
  platform_digests+=("$digest")
done < <(jq -r --arg architecture "$architecture" '
    .manifests[]
    | select(.platform.os == "linux" and .platform.architecture == $architecture)
    | .digest
  ' <<<"$manifest")
if [[ "${#platform_digests[@]}" -ne 1 ]]; then
  echo "expected exactly one $platform image manifest" >&2
  exit 1
fi
platform_ref="ghcr.io/zed-pkg/zed-oci@${platform_digests[0]}"
builder_tag="zed-oci-acceptance-builder-${architecture}:verify"

docker pull --platform "$platform" "$platform_ref"
docker tag "$platform_ref" "$builder_tag"
config="$(docker image inspect --format '{{json .Config}}' "$platform_ref")"
jq -e --arg label_version "$expected_label_version" '
  .User == "10001:10001"
  and .WorkingDir == "/workspace"
  and .Cmd == ["zed", "--help"]
  and (.Env | sort) == ([
    "HOME=/home/zed",
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "ZED_PKG_HOME=/home/zed/.zed-pkg"
  ] | sort)
  and .Labels["org.opencontainers.image.source"] == "https://github.com/zed-pkg/zed-oci"
  and .Labels["org.opencontainers.image.licenses"] == "MIT"
  and .Labels["org.opencontainers.image.base.name"] == "docker.io/library/debian:bookworm-slim"
  and .Labels["org.opencontainers.image.base.digest"]
    == "sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241"
  and (.Labels["org.opencontainers.image.revision"] | test("^[0-9a-f]{40}$"))
  and (.Labels["org.opencontainers.image.created"] != "1970-01-01T00:00:00Z")
  and .Labels["org.opencontainers.image.version"] == $label_version
' <<<"$config"

docker run --rm --platform "$platform" --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --env "EXPECTED_ZED_VERSION=zed $expected_version" \
  "$platform_ref" sh -euc '
    test "$(id -u)" = 10001
    test "$(id -g)" = 10001
    test "$PWD" = /workspace
    test "$HOME" = /home/zed
    test "$ZED_PKG_HOME" = /home/zed/.zed-pkg
    test "$(zed --version)" = "$EXPECTED_ZED_VERSION"
  '

tls_dir="$(mktemp -d)"
tls_port=18443
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=host.docker.internal" \
  -addext "subjectAltName=DNS:host.docker.internal" \
  -keyout "$tls_dir/key.pem" \
  -out "$tls_dir/cert.pem" \
  >/dev/null 2>&1
openssl s_server -accept "$tls_port" \
  -cert "$tls_dir/cert.pem" -key "$tls_dir/key.pem" -www -quiet \
  >"$tls_dir/server.log" 2>&1 &
tls_server_pid=$!
tls_ready=0
for _ in {1..20}; do
  if curl --fail --insecure --silent --show-error \
    "https://127.0.0.1:${tls_port}/" >/dev/null; then
    tls_ready=1
    break
  fi
  sleep 0.25
done
if [[ "$tls_ready" != 1 ]]; then
  cat "$tls_dir/server.log" >&2
  echo "self-signed TLS fixture did not become ready" >&2
  exit 1
fi
if docker run --rm --platform "$platform" --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --add-host host.docker.internal:host-gateway \
  "$platform_ref" zed \
  --registry "https://host.docker.internal:${tls_port}" find canary \
  >"$tls_dir/client.log" 2>&1; then
  echo "Zed accepted an untrusted self-signed registry certificate" >&2
  exit 1
fi
grep -Eiq 'certificate|unknown.?issuer|tls' "$tls_dir/client.log"
kill "$tls_server_pid"
wait "$tls_server_pid" 2>/dev/null || true
tls_server_pid=""
find "$tls_dir" -depth -delete
tls_dir=""

binary_dir="$(mktemp -d)"
container_id="$(docker create --platform "$platform" "$platform_ref")"
docker cp "$container_id:/usr/local/bin/zed" "$binary_dir/zed"
file "$binary_dir/zed"
if command -v readelf >/dev/null 2>&1; then
  if readelf --program-headers "$binary_dir/zed" \
    | grep -q 'Requesting program interpreter'; then
    echo "zed release binary is dynamically linked" >&2
    exit 1
  fi
elif command -v objdump >/dev/null 2>&1; then
  if objdump -p "$binary_dir/zed" | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)'; then
    echo "zed release binary is dynamically linked" >&2
    exit 1
  fi
else
  echo "readelf or objdump is required to verify the Zed ELF interpreter" >&2
  exit 1
fi

runtime_tag="zed-oci-acceptance-cli-${architecture}:verify"
docker buildx build \
  --platform "$platform" \
  --build-arg "ZED_OCI_IMAGE=$image_ref" \
  --build-arg "EXPECTED_ZED_VERSION=$expected_version" \
  --file "$repo_root/fixtures/zed-oci-cli-tools.Dockerfile" \
  --tag "$runtime_tag" \
  --load \
  "$repo_root"

runtime_config="$(docker image inspect --format '{{json .Config}}' "$runtime_tag")"
jq -e '
  .User == "65532:65532"
  and .WorkingDir == "/app"
  and (.Env | all(test("^(HOME|ZED_PKG_HOME)=") | not))
' <<<"$runtime_config"

docker run --rm --platform "$platform" --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  "$runtime_tag" sh -euc '
    test "$(node --version)" = "v24.19.0"
    test "$(nodejs --version)" = "v24.19.0"
    test "$(python3 --version)" = "Python 3.14.7"
    test "$(python --version)" = "Python 3.14.7"
    npm --version
    pip3 --version
    ! command -v zed
    test ! -e /home/zed
    test -s /app/.zpkg.toml
    test -s /app/.zed/environment.lock.toml
  '

alpine_tag="zed-oci-acceptance-alpine-${architecture}:verify"
abi_dir="$(mktemp -d)"
mkdir "$abi_dir/app"
abi_container_id="$(docker create --platform "$platform" "$runtime_tag")"
docker cp "$abi_container_id:/app/." "$abi_dir/app/"
docker rm "$abi_container_id" >/dev/null
abi_container_id=""
docker buildx build \
  --platform "$platform" \
  --file "$repo_root/fixtures/zed-oci-alpine-abi.Dockerfile" \
  --tag "$alpine_tag" \
  --load \
  "$abi_dir"
if docker run --rm --platform "$platform" --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  "$alpine_tag" node --version; then
  echo "glibc Node unexpectedly ran in the musl-only Alpine compatibility canary" >&2
  exit 1
fi

echo "verified $platform builder, separate CLI layers, hardened runtime, and ABI rejection"
