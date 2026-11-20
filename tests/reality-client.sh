#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
awk '/^save_vless_reality_client_config\(\) \{/ {inside=1} inside {print} inside && /^}$/ {exit}' \
  "$repo/xrayvless.sh" > "$scratch/helper.sh"
source "$scratch/helper.sh"

REMARK=$'name: "quoted"\nsecond line # text'
IP=example.com
PORT=21121
UUID=00000000-0000-4000-8000-000000000001
SNI=example.org
PUB_KEY=fixture-public-key
SHORT_ID=00001234
export IP PORT UUID SNI PUB_KEY
save_vless_reality_client_config "$scratch/client.yaml"
jq -e --arg name "$REMARK" --arg sid "$SHORT_ID" '
  .proxies | length == 1 and (.[0] |
    .name == $name and .server == "example.com" and .port == 21121 and
    .uuid == "00000000-0000-4000-8000-000000000001" and
    .type == "vless" and .network == "tcp" and .tls == true and
    .flow == "xtls-rprx-vision" and .servername == "example.org" and
    .["client-fingerprint"] == "chrome" and
    .["reality-opts"]["short-id"] == $sid and
    .["reality-opts"]["public-key"] == "fixture-public-key" and
    .["reality-opts"]["support-x25519mlkem768"] == true)
' "$scratch/client.yaml" >/dev/null
test "$(stat -c %a "$scratch/client.yaml")" = 600
save_vless_reality_client_config "$scratch/compat.yaml" false
jq -e --arg sid "$SHORT_ID" '.proxies[0]["reality-opts"] |
  .["public-key"] == "fixture-public-key" and .["short-id"] == $sid and
  (has("support-x25519mlkem768") | not)' "$scratch/compat.yaml" >/dev/null
test "$(stat -c %a "$scratch/compat.yaml")" = 600

# Export failures must not destroy a previously usable client configuration.
cp "$scratch/client.yaml" "$scratch/original.yaml"
PORT=invalid
if save_vless_reality_client_config "$scratch/client.yaml" 2>/dev/null; then
  echo 'Invalid port must fail' >&2
  exit 1
fi
cmp "$scratch/client.yaml" "$scratch/original.yaml"
test -z "$(find "$scratch" -name 'client.yaml.*')"
echo 'Reality client ML-KEM, scalar preservation and safe export tests passed'
