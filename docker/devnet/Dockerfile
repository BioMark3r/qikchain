# syntax=docker/dockerfile:1.6
FROM golang:1.20.14-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git make ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make build

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash curl jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /src/bin/ ./bin/
COPY --from=build /src/config/ ./config/
COPY docker/devnet/entrypoint.sh /usr/local/bin/devnet-entrypoint.sh
COPY docker/devnet/healthcheck.sh /usr/local/bin/devnet-healthcheck.sh

RUN chmod +x /usr/local/bin/devnet-entrypoint.sh /usr/local/bin/devnet-healthcheck.sh

ENTRYPOINT ["/usr/local/bin/devnet-entrypoint.sh"]
