#!/usr/bin/env bash
set -euo pipefail

# Optional network smoke test: use official release assets in a private sandbox.
# No host binaries, configurations, packages, or services are changed.
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/etc/xray"
{
  for name in get_shadowsocks_rust_target get_snell_arch get_snell_sha256; do
    awk -v name="$name" '$0 == name "() {" {inside=1} inside {print} inside && /^}$/ {exit}' "$repo/xrayvless.sh"
  done
  sed -n '/^update_service_active() {/,/^#====== 主菜单 ======/p' "$repo/xrayvless.sh" | sed '$d'
} | sed "s|/usr/local/bin|$scratch/bin|g; s|/usr/local/etc/xray|$scratch/etc/xray|g; s|/usr/local/share/xray|$scratch/assets|g; s|/etc/shadowsocks|$scratch/etc/shadowsocks|g; s|/etc/snell|$scratch/etc/snell|g" > "$scratch/helpers.sh"
# shellcheck source=/dev/null
source "$scratch/helpers.sh"
green() { echo "$1"; }
yellow() { echo "$1"; }
red() { echo "$1" >&2; }
update_service_active() { return 1; }
export OS=debian
export UPDATE_BACKUP_DIR="$scratch/backups"
export XRAY_COMPAT_VERSION=v26.6.27
export SNELL_VERSION=v5.0.1
export SNELL_DOWNLOAD_BASE=https://dl.nssurge.com/snell
printf '#!/bin/sh\necho "Xray 0.0.0"\n' > "$scratch/bin/xray"
for binary in ssserver sslocal; do
  printf '#!/bin/sh\necho "shadowsocks 0.0.0"\n' > "$scratch/bin/$binary"
done
printf '#!/bin/sh\necho "snell-server v5.0.0"\n' > "$scratch/bin/snell-server"
chmod +x "$scratch/bin/"*
echo '{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}' > "$scratch/etc/xray/config.json"
update_xray_core
update_xray_core "$XRAY_COMPAT_VERSION"
test "$("$scratch/bin/xray" version | awk 'NR==1 {print $2}')" = "${XRAY_COMPAT_VERSION#v}"
cmp "$scratch/etc/xray/config.json" "$UPDATE_BACKUP_DIR/xray/xray/config.json"
update_xray_core # The compatibility release stays in place during a batch update.
test "$("$scratch/bin/xray" version | awk 'NR==1 {print $2}')" = "${XRAY_COMPAT_VERSION#v}"
update_shadowsocks_rust
update_snell_core
"$scratch/bin/xray" version
"$scratch/bin/ssserver" --version
"$scratch/bin/sslocal" --version
"$scratch/bin/snell-server" -v
echo 'Official release download and executable smoke tests passed'
