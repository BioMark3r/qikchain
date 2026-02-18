#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${ROOT}/third_party/polygon-edge"

# Pin this to a known-good tag or commit for reproducibility
EDGE_REPO_URL="${EDGE_REPO_URL:-https://github.com/BioMark3r/polygon-edge.git}"
EDGE_REF="${EDGE_REF:-v1.1.1}"   # e.g. v1.3.0 or a commit SHA

if [[ -d "${DST}/.git" ]]; then
  echo "polygon-edge already present: ${DST}"
  exit 0
fi

echo "Fetching polygon-edge into ${DST}"
mkdir -p "$(dirname "${DST}")"
git clone --depth 1 --branch "${EDGE_REF}" "${EDGE_REPO_URL}" "${DST}" 2>/dev/null || {
  # If EDGE_REF is a commit SHA, clone then checkout
  git clone "${EDGE_REPO_URL}" "${DST}"
  (cd "${DST}" && git checkout "${EDGE_REF}")
}

echo "Done."
