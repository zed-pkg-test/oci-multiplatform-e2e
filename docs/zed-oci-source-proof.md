# zed-oci exact-source proof

This repository can act as an **evidence-only CI carrier** for public `zed-pkg/zed-oci` source commits when the source organization cannot obtain hosted runner capacity.

The carrier does not replace source review, publish images, sign artifacts, or relax the source repository's merge requirements. It answers one narrow question: does this exact immutable source commit pass the same static, multi-arch builder/runtime, and fixable HIGH/CRITICAL vulnerability checks on an independently funded runner?

## When to use it

Use the source-proof lane when a `zed-pkg/zed-oci` pull request is otherwise ready for exact-head execution but source-org runner capacity is unavailable. Do not use it to reinterpret an executed source failure as green.

For base-image maintenance, promote in this order:

1. repair the shared pinned base image and provenance metadata;
2. prove that exact source head;
3. merge the base repair only when its substantive gates pass;
4. rebase dependent Dependabot/action/tooling PRs onto the repaired base;
5. prove each rebased exact head normally.

The fixable HIGH/CRITICAL vulnerability scanner is never waived.

## Running the carrier

Dispatch **zed-oci exact-source proof** with a full 40-hex `zed-pkg/zed-oci` commit SHA. The workflow rejects mutable refs, checks out the public repository without persistent credentials, verifies `git rev-parse HEAD` equals the requested SHA, then runs both `linux/amd64` and `linux/arm64` lanes.

Each lane runs:

- the source repository's static `scripts/verify.sh` policy path;
- the source repository's builder-to-runtime canaries;
- the same Trivy policy for fixable `CRITICAL,HIGH` vulnerabilities.

Record the carrier run URL on the source pull request together with the exact source SHA. If the source head moves, the prior carrier run is stale and must not be used as merge evidence.

## Tracking

- upstream GitHub issue: https://github.com/zed-pkg/zed-oci/issues/28
- test-carrier issue: https://github.com/zed-pkg-test/oci-multiplatform-e2e/issues/6
- historical Linear hardening ticket: `DEN-3722`
