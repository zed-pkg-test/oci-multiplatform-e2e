# syntax=docker/dockerfile:1.26@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32

ARG ZED_OCI_IMAGE=scratch
FROM ${ZED_OCI_IMAGE} AS zed-builder

ARG EXPECTED_ZED_VERSION
RUN test "$(zed --version)" = "zed ${EXPECTED_ZED_VERSION}"

WORKDIR /workspace
RUN zed init project --org zed-pkg-test

WORKDIR /workspace/project
RUN zed install --cli nodejs
RUN zed install --cli python3

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

WORKDIR /app
COPY --from=zed-builder --chown=65532:65532 /workspace/project/ /app/
ENV PATH="/app/.zed/tools/bin:${PATH}"

RUN test "$(node --version)" = "v24.19.0" \
    && test "$(nodejs --version)" = "v24.19.0" \
    && test "$(python3 --version)" = "Python 3.14.7" \
    && test "$(python --version)" = "Python 3.14.7" \
    && npm --version \
    && pip3 --version \
    && ! command -v zed \
    && test ! -e /home/zed \
    && test -s /app/.zpkg.toml \
    && test -s /app/.zed/environment.lock.toml \
    && test -z "$(find /app/.zed/tools -type l -lname '/*' -print -quit)" \
    && test -z "$(find /app/.zed/tools -type f -perm -0002 -print -quit)"

USER 65532:65532
CMD ["sh", "-euc", "node --version; python3 --version"]
