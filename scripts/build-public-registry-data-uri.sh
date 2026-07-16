#!/usr/bin/env bash
set -euo pipefail

settings_path="settings.yaml"
registry_path="registry"
output_path=""

usage() {
  cat <<'USAGE'
Usage: scripts/build-public-registry-data-uri.sh [options]

Build a self-contained data:text/plain;base64 registry URI from registry and settings.yaml
without adding private RPC URLs.

Options:
  --settings PATH    settings YAML path (default: settings.yaml)
  --registry PATH    registry path (default: registry)
  --output PATH      write registry data URI to PATH instead of stdout
  -h, --help         show this help
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)
      [[ $# -ge 2 ]] || die "--settings requires a path"
      settings_path="$2"
      shift 2
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry requires a path"
      registry_path="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      output_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "$settings_path" ]] || die "settings file not found: $settings_path"
[[ -f "$registry_path" ]] || die "registry file not found: $registry_path"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

final_registry_file="$work_dir/registry"
settings_b64="$(base64 < "$settings_path" | tr -d '\n')"

{
  printf 'data:application/yaml;base64,%s\n' "$settings_b64"
  tail -n +2 "$registry_path"
} > "$final_registry_file"

registry_b64="$(base64 < "$final_registry_file" | tr -d '\n')"
registry_data_uri="data:text/plain;base64,${registry_b64}"

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  printf '%s\n' "$registry_data_uri" > "$output_path"
else
  printf '%s\n' "$registry_data_uri"
fi
