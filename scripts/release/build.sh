#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"

VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)}"
COMMIT="${COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)}"

if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
  DATE="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
else
  DATE="${DATE:-$(git -C "$ROOT_DIR" show -s --format=%cI HEAD)}"
fi

TARGETS=("${@}")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(
    "linux/amd64"
    "linux/arm64"
  )
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/*.tar.gz "$DIST_DIR"/SHA256SUMS

build_binary() {
  local output="$1"
  local package="$2"
  local ldflags
  ldflags="-s -w -X 'main.version=${VERSION}' -X 'main.commit=${COMMIT}' -X 'main.date=${DATE}'"
  CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" \
    go build -trimpath -buildvcs=false -ldflags "$ldflags" -o "$output" "$package"
}

for target in "${TARGETS[@]}"; do
  GOOS="${target%/*}"
  GOARCH="${target#*/}"

  release_dir="$DIST_DIR/qikchain_${GOOS}_${GOARCH}"
  rm -rf "$release_dir"
  mkdir -p "$release_dir"

  echo "==> Building qikchain for ${GOOS}/${GOARCH}"
  build_binary "$release_dir/qikchain" ./cmd/qikchain

  if [[ -d "$ROOT_DIR/cmd/qikchaind" ]]; then
    echo "==> Building qikchaind for ${GOOS}/${GOARCH}"
    build_binary "$release_dir/qikchaind" ./cmd/qikchaind
  fi

  if [[ -d "$ROOT_DIR/third_party/polygon-edge" ]]; then
    echo "==> Building polygon-edge for ${GOOS}/${GOARCH}"
    build_binary "$release_dir/polygon-edge" ./third_party/polygon-edge
  else
    echo "==> Skipping polygon-edge (third_party/polygon-edge not present)"
  fi

  tarball="$DIST_DIR/qikchain_${GOOS}_${GOARCH}.tar.gz"
  tar -C "$DIST_DIR" -czf "$tarball" "qikchain_${GOOS}_${GOARCH}"
  echo "==> Created $tarball"
done

(
  cd "$DIST_DIR"
  shopt -s nullglob
  artifacts=(qikchain_*.tar.gz)
  if [[ ${#artifacts[@]} -eq 0 ]]; then
    echo "No release archives were produced" >&2
    exit 1
  fi
  sha256sum "${artifacts[@]}" > SHA256SUMS
)

echo "==> Release artifacts available in $DIST_DIR"
