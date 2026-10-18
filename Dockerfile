# Build stage: a static musl binary so the runtime image stays tiny and
# dependency-free.
FROM ziglang/zig:0.14.1 AS build

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
