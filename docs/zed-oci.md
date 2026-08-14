# zed-oci independent acceptance

This product-owned lane verifies the public `zed-pkg/zed-oci` builder without
using source-repository credentials or a mutable image tag. The scheduled
target lives in `config/zed-oci.env`; manual runs may substitute another exact
digest, expected semantic version, and canonical GitHub OIDC publisher
identity.

The lane accepts only references shaped like:

```text
ghcr.io/zed-pkg/zed-oci@sha256:<64 lowercase hexadecimal characters>
```

It then independently proves:

- the OCI index has exactly one Linux amd64 image and one Linux arm64 image;
- the index has a valid keyless Sigstore signature from
  `zed-pkg/zed-oci/.github/workflows/publish.yml` on `main` or the matching
  release tag;
- every platform digest is paired with an in-toto SPDX SBOM and SLSA v1
  provenance predicate;
- the Zed release executable is static, the builder configuration is non-root,
  and the recorded OCI source, revision, creation time, base name, and base
  digest are present;
- Node and Python can be installed in separate OCI layers and copied into a
  final runtime without the Zed executable, home, store, cache, or credentials;
- the final runtime works with networking disabled, a read-only filesystem,
  all Linux capabilities dropped, and `no-new-privileges`;
- the GNU/Linux Node runtime fails in a musl-only Alpine final stage instead of
  presenting that ABI combination as portable;
- Zed rejects a registry endpoint presenting an untrusted self-signed TLS
  certificate; and
- the same separate-layer build succeeds through rootless Podman, not only
  Docker/BuildKit.

The workflow also rejects fixable high or critical package vulnerabilities.
Unfixed findings remain visible in scanner output but do not make a base image
unusable merely because no upstream remediation exists.

This directory is intentionally separate from the generated fleet manifest,
README, source pins, and generated contract workflow. Fleet regeneration can
therefore update its owned files without erasing the product-specific OCI
acceptance lane.
