#!/usr/bin/env bash
set -euo pipefail

settings_path="settings.yaml"
registry_path="registry"
output_path=""
settings_output_path=""
private_rpc_csv=""
private_rpc_urls=()
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/build-private-registry-artifact.sh [options]

Build the base64-encoded private registry artifact from registry and settings.yaml.

Options:
  --settings PATH                  settings YAML path (default: settings.yaml)
  --registry PATH                  registry path (default: registry)
  --private-base-rpc-url URL       private Base RPC URL; can be passed more than once
  --private-base-rpc-urls URLS     comma-separated private Base RPC URLs
  --output PATH                    write registry artifact base64 to PATH instead of stdout
  --settings-output PATH           write updated settings YAML to PATH for inspection
  -h, --help                       show this help
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

add_private_url() {
  local url
  url="$(trim "$1")"
  if [[ -n "$url" ]]; then
    private_rpc_urls+=("$url")
  fi
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
    --private-base-rpc-url)
      [[ $# -ge 2 ]] || die "--private-base-rpc-url requires a URL"
      add_private_url "$2"
      shift 2
      ;;
    --private-base-rpc-urls)
      [[ $# -ge 2 ]] || die "--private-base-rpc-urls requires a comma-separated list"
      private_rpc_csv="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      output_path="$2"
      shift 2
      ;;
    --settings-output)
      [[ $# -ge 2 ]] || die "--settings-output requires a path"
      settings_output_path="$2"
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

if [[ -n "$private_rpc_csv" ]]; then
  IFS=',' read -r -a csv_urls <<< "$private_rpc_csv"
  for url in "${csv_urls[@]}"; do
    add_private_url "$url"
  done
fi

[[ -f "$settings_path" ]] || die "settings file not found: $settings_path"
[[ -f "$registry_path" ]] || die "registry file not found: $registry_path"
[[ ${#private_rpc_urls[@]} -gt 0 ]] || die "at least one private Base RPC URL is required"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

private_urls_file="$work_dir/private-rpc-urls.txt"
updated_settings_file="$work_dir/settings.yaml"
final_registry_file="$work_dir/registry"

touch "$private_urls_file"
for url in "${private_rpc_urls[@]}"; do
  if ! grep -Fxq "$url" "$private_urls_file"; then
    printf '%s\n' "$url" >> "$private_urls_file"
  fi
done

awk -v private_urls_file="$private_urls_file" \
  -f "$script_dir/prepend-base-rpcs.awk" \
  "$settings_path" > "$updated_settings_file"

if [[ -n "$settings_output_path" ]]; then
  mkdir -p "$(dirname "$settings_output_path")"
  cp "$updated_settings_file" "$settings_output_path"
fi

settings_b64="$(base64 < "$updated_settings_file" | tr -d '\n')"
{
  printf 'data:application/yaml;base64,%s\n' "$settings_b64"
  tail -n +2 "$registry_path"
} > "$final_registry_file"

registry_b64="$(base64 < "$final_registry_file" | tr -d '\n')"

if [[ -n "$output_path" ]]; then
  mkdir -p "$(dirname "$output_path")"
  printf '%s\n' "$registry_b64" > "$output_path"
else
  printf '%s\n' "$registry_b64"
fi
