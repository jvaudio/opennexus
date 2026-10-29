# The OpenNexus Server (M44). Builds on Linux with the Swift toolchain, then runs as an
# unprivileged user with shares in the /data volume.
FROM swift:6.4-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib --product opennexus-server \
    && cp "$(swift build -c release --show-bin-path)/opennexus-server" /opennexus-server

FROM ubuntu:noble
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /data opennexus \
    && mkdir -p /data && chown opennexus /data
COPY --from=build /opennexus-server /usr/local/bin/opennexus-server
USER opennexus
ENV OPENNEXUS_DATA_DIR=/data OPENNEXUS_PORT=8787
VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s CMD ["opennexus-server", "healthcheck"]
ENTRYPOINT ["opennexus-server"]
