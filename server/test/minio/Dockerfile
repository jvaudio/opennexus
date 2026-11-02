# MinIO for the share tests (M44). MinIO no longer publishes images, so this builds its last
# community release from source (AGPL-3.0); it's a test fixture, never shipped.
FROM golang:1.25-alpine AS build
RUN apk add --no-cache git
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
RUN git clone --depth 1 --branch "$MINIO_RELEASE" https://github.com/minio/minio /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/minio .

FROM alpine:3.22
COPY --from=build /out/minio /usr/local/bin/minio
EXPOSE 9000
ENTRYPOINT ["minio"]
CMD ["server", "/data"]
