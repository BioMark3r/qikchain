#!/usr/bin/env bash
set -euo pipefail

json_get() {
  local file="$1"
  local query="$2"
  jq -r "$query" "$file"
}

json_set() {
  local file="$1"
  local query="$2"
  local value="$3"
  jq --arg value "$value" "$query = \$value" "$file"
}

json_merge() {
  local base_file="$1"
  local overlay_file="$2"
  jq -S -s '.[0] * .[1]' "$base_file" "$overlay_file"
}

json_template_replace() {
  local input_file="$1"
  local output_file="$2"
  shift 2

  local args=("$@")
  python3 - "$input_file" "$output_file" "${args[@]}" <<'PY'
import pathlib
import sys

input_file = pathlib.Path(sys.argv[1])
output_file = pathlib.Path(sys.argv[2])
text = input_file.read_text()

for pair in sys.argv[3:]:
    if "=" not in pair:
        raise SystemExit(f"invalid replacement pair: {pair}")
    key, value = pair.split("=", 1)
    text = text.replace("{{" + key + "}}", value)

output_file.parent.mkdir(parents=True, exist_ok=True)
output_file.write_text(text)
PY
}
