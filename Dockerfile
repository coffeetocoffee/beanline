# Build stage: a static musl binary so the runtime image stays tiny and
# dependency-free.
#
# There is no official Zig image on Docker Hub or ghcr.io, so fetch the
# upstream tarball directly and verify its published SHA-256 before use.
FROM alpine:3.20 AS build

ARG ZIG_VERSION=0.14.1
# BuildKit sets TARGETARCH (amd64/arm64/...) automatically.
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl xz
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) zig_arch=x86_64; \
             zig_sha=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c ;; \
      arm64) zig_arch=aarch64; \
             zig_sha=f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"; \
    echo "fetching ${url}"; \
    curl -fsSL -o /tmp/zig.tar.xz "${url}"; \
    echo "${zig_sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    rm /tmp/zig.tar.xz; \
    ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    zig version

WORKDIR /src
# Copy the build files first so dependency-free edits do not bust the cache.
COPY build.zig ./
COPY src ./src
COPY tests ./tests
COPY migrations ./migrations
COPY bench ./bench

ARG TARGET=x86_64-linux-musl
ARG OPTIMIZE=ReleaseSafe
RUN zig build -Doptimize=${OPTIMIZE} -Dtarget=${TARGET} --prefix /out

# Runtime stage.
FROM alpine:3.20

# ca-certificates: TLS to Postgres/Redis. tzdata: the scheduler reads IANA
# zones from its own compiled table, but operators expect a sane system zone.
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 10001 beanline

COPY --from=build /out/bin/beanline /usr/local/bin/beanline

USER beanline
EXPOSE 9484

# The worker tier is the default; override with "server" for the dashboard
# tier or "migrate" for a one-shot migration job.
ENTRYPOINT ["beanline"]
CMD ["worker"]
