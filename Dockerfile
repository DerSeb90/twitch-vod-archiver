# syntax=docker/dockerfile:1.7
# One image: Go server + Flutter web app + streamlink + ffmpeg.

# ---- Flutter web (architecture independent, always built on the runner's native platform)
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
RUN flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
 && find build/web -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' -o -name '*.css' -o -name '*.otf' -o -name '*.ttf' -o -name '*.symbols' \) -exec gzip -9 -k {} \;

# ---- Go server (cross-compiled, no cgo)
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS server
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/archiver ./cmd/archiver

# ---- runtime
FROM python:3.13-alpine
ARG STREAMLINK_VERSION=
RUN apk add --no-cache ffmpeg tzdata ca-certificates \
 && pip install --no-cache-dir --root-user-action=ignore "streamlink${STREAMLINK_VERSION:+==$STREAMLINK_VERSION}" \
 && addgroup -g 1000 app && adduser -D -u 1000 -G app app \
 && mkdir -p /data /recordings /archive && chown app:app /data /recordings /archive
COPY --from=server /out/archiver /usr/local/bin/archiver
COPY --from=web /src/app/build/web /app/web
ENV HTTP_ADDR=:8080 DATA_DIR=/data RECORDINGS_DIR=/recordings ARCHIVE_DIR=/archive WEB_DIR=/app/web TZ=Europe/Berlin
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD wget -qO- http://127.0.0.1:8080/api/health >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/archiver"]
