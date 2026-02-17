# syntax=docker/dockerfile:1.6
FROM golang:1.20.14-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git make ca-certificates bash \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make all

# (optional) runtime image just to hold artifacts or run node
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/bin/ ./bin/
ENTRYPOINT ["/app/bin/qikchain"]
