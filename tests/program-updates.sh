#!/usr/bin/env bash
# Helpers are sourced dynamically before the deliberate aggregation stubs below.
# shellcheck disable=SC2218
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export UPDATE_TEST_ROOT="$scratch"
mkdir -p "$scratch/bin" "$scratch/staged" "$scratch/etc/xray" "$scratch/etc/shadowsocks" "$scratch/etc/snell"

{
  for name in get_shadowsocks_rust_target get_snell_arch prompt_read select_reality_xray; do
    awk -v name="$name" '$0 == name "() {" {inside=1} inside {print} inside && /^}$/ {exit}' "$repo/xrayvless.sh"
  done
  sed -n '/^update_service_active() {/,/^#====== 主菜单 ======/p' "$repo/xrayvless.sh" | sed '$d'
} | sed "s|/usr/local/bin|$scratch/bin|g; s|/usr/local/etc/xray|$scratch/etc/xray|g; s|/usr/local/share/xray|$scratch/assets|g; s|/etc/shadowsocks|$scratch/etc/shadowsocks|g; s|/etc/snell|$scratch/etc/snell|g; s|/root/fast-vless-backups|$scratch/backups|g" > "$scratch/helpers.sh"
# shellcheck source=/dev/null
source "$scratch/helpers.sh"
green() { :; }
yellow() { :; }
red() { :; }
sleep() { :; }
uname() { echo x86_64; }
export OS=debian
export UPDATE_BACKUP_DIR="$scratch/backups/manual"
export XRAY_COMPAT_VERSION=v26.6.27
export SNELL_VERSION=v5.0.1
export SNELL_DOWNLOAD_BASE=https://dl.nssurge.com/snell

select_reality_xray <<< '' >/dev/null
test "$XRAY_REALITY_VERSION" = latest
select_reality_xray <<< $'invalid\n2' >/dev/null
test "$XRAY_REALITY_VERSION" = "$XRAY_COMPAT_VERSION"

update_version_needed 1.24.0 v1.25.0
if update_version_needed v5.0.1 v5.0.1 || update_version_needed v5.0.2 v5.0.1; then
  echo 'Equal and newer installed versions must not be downgraded' >&2
  exit 1
fi
test "$(get_xray_update_arch)" = 64

systemctl() {
  local action="$1" service="${*: -1}"
  printf '%s\n' "$*" >> "$scratch/services"
  case "$action" in
    is-active) test -e "$scratch/active-$service" ;;
    stop) rm -f "$scratch/active-$service" ;;
    start|restart)
      if [ -f "$scratch/fail-next-start" ]; then
        rm "$scratch/fail-next-start"
        return 1
      fi
      touch "$scratch/active-$service"
      ;;
  esac
}
rc-service() {
  case "$2" in
    status) systemctl is-active --quiet "$1" ;;
    *) systemctl "$2" "$1" ;;
  esac
}

# A two-file failure must roll back both files and restart the old service.
printf 'old-server\n' > "$scratch/bin/ssserver"
printf 'old-local\n' > "$scratch/bin/sslocal"
printf 'new-server\n' > "$scratch/staged/ssserver"
printf 'new-local\n' > "$scratch/staged/sslocal"
touch "$scratch/active-shadowsocks" "$scratch/fail-next-start"
if apply_core_update shadowsocks "$scratch/staged" ssserver sslocal; then
  echo 'A failed service start must reject the update' >&2
  exit 1
fi
grep -qx old-server "$scratch/bin/ssserver"
grep -qx old-local "$scratch/bin/sslocal"
test -e "$scratch/active-shadowsocks"

# Do not start a stopped service or change enablement during binary updates.
rm "$scratch/active-shadowsocks"
: > "$scratch/services"
apply_core_update shadowsocks "$scratch/staged" ssserver sslocal
grep -qx new-server "$scratch/bin/ssserver"
grep -qx new-local "$scratch/bin/sslocal"
if [ -s "$scratch/services" ] && grep -Eq '^(start|enable)' "$scratch/services"; then
  echo 'A stopped service must remain stopped' >&2
  exit 1
fi

# Exercise the OpenRC update branch as well as systemd.
OS=alpine
touch "$scratch/active-shadowsocks"
apply_core_update shadowsocks "$scratch/staged" ssserver sslocal
test -e "$scratch/active-shadowsocks"
OS=debian

mkdir -p "$scratch/fixture"
cat > "$scratch/fixture/xray" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = version ]; then
  echo 'Xray 26.10.21'
else
  test ! -f "$UPDATE_TEST_ROOT/bad-config"
fi
EOF
for binary in ssserver sslocal; do
  printf '#!/bin/sh\necho "shadowsocks 1.25.0"\n' > "$scratch/fixture/$binary"
done
printf '#!/bin/sh\necho "2026-10-29 12:34:56 [info] snell-server v5.0.1"\n' > "$scratch/fixture/snell-server"
chmod +x "$scratch/fixture/"*
tar -cJf "$scratch/ss.tar.xz" -C "$scratch/fixture" ssserver sslocal
python3 - "$scratch" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
for binary in ('xray', 'snell-server'):
    with zipfile.ZipFile(root / (binary + '.zip'), 'w') as archive:
        archive.write(root / 'fixture' / binary, binary)
with zipfile.ZipFile(root / 'xray-compat.zip', 'w') as archive:
    archive.writestr('xray', (root / 'fixture' / 'xray').read_text().replace('26.10.21', '26.6.27'))
PY
get_snell_sha256() { sha256sum "$scratch/snell-server.zip" | awk '{print $1}'; }

curl() {
  local output="" url="" arg previous="" version asset archive repository digest
  for arg in "$@"; do
    if [ "$previous" = -o ]; then output="$arg"; fi
    [[ "$arg" != https://* ]] || url="$arg"
    previous="$arg"
  done
  if [ -f "$scratch/download-fail" ]; then return 22; fi
  case "$url" in
    */XTLS/Xray-core/releases/latest)
      repository=XTLS/Xray-core; version=v26.10.21; asset=Xray-linux-64.zip; archive=xray.zip ;;
    */shadowsocks/shadowsocks-rust/releases/latest)
      repository=shadowsocks/shadowsocks-rust; version=v1.25.0
      asset=shadowsocks-v1.25.0.x86_64-unknown-linux-gnu.tar.xz; archive=ss.tar.xz ;;
    */snell.md)
      printf '### v6.0.0\n### v5.0.1\n### v5.0.0\n' > "$output"
      return ;;
    */v26.6.27/Xray-linux-64.zip) cp "$scratch/xray-compat.zip" "$output"; return ;;
    */v26.6.27/Xray-linux-64.zip.dgst)
      printf 'SHA2-256= %s\n' "$(sha256sum "$scratch/xray-compat.zip" | awk '{print $1}')" > "$output"
      return ;;
    */Xray-linux-64.zip) cp "$scratch/xray.zip" "$output"; return ;;
    */shadowsocks-v1.25.0.*) cp "$scratch/ss.tar.xz" "$output"; return ;;
    */snell-server-v5.0.1-linux-amd64.zip) cp "$scratch/snell-server.zip" "$output"; return ;;
    *) echo "Unexpected URL: $url" >&2; return 1 ;;
  esac
  digest=$(sha256sum "$scratch/$archive" | awk '{print $1}')
  if [ -f "$scratch/bad-digest" ]; then digest=$(printf '%064d' 0); fi
  jq -n --arg version "$version" --arg name "$asset" --arg digest "$digest" \
    --arg url "https://github.com/$repository/releases/download/$version/$asset" \
    '{tag_name:$version,draft:false,prerelease:false,assets:[{name:$name,browser_download_url:$url,digest:("sha256:"+$digest)}]}' > "$output"
}

printf '#!/bin/sh\necho "Xray 26.3.27"\n' > "$scratch/bin/xray"
printf '#!/bin/sh\necho "shadowsocks 1.24.0"\n' > "$scratch/bin/ssserver"
printf '#!/bin/sh\necho "shadowsocks 1.24.0"\n' > "$scratch/bin/sslocal"
printf '#!/bin/sh\necho "snell-server v5.0.0"\n' > "$scratch/bin/snell-server"
chmod +x "$scratch/bin/"*
echo '{"unchanged":true}' > "$scratch/etc/xray/config.json"
echo 'same-password' > "$scratch/etc/shadowsocks/config.json"
echo 'same-psk' > "$scratch/etc/snell/snell-server.conf"

for failure in download-fail bad-digest bad-config; do
  touch "$scratch/$failure"
  if update_xray_core; then
    echo "$failure must reject the new Xray" >&2
    exit 1
  fi
  test "$("$scratch/bin/xray" version)" = 'Xray 26.3.27'
  rm "$scratch/$failure"
done
update_xray_core
update_shadowsocks_rust
update_snell_core
test "$("$scratch/bin/xray" version)" = 'Xray 26.10.21'
test "$("$scratch/bin/ssserver" --version)" = 'shadowsocks 1.25.0'
test "$("$scratch/bin/sslocal" --version)" = 'shadowsocks 1.25.0'
"$scratch/bin/snell-server" -v | grep -q 'snell-server v5.0.1'
grep -qx 'same-password' "$scratch/etc/shadowsocks/config.json"
grep -qx 'same-psk' "$scratch/etc/snell/snell-server.conf"
cmp "$scratch/etc/xray/config.json" "$UPDATE_BACKUP_DIR/xray/xray/config.json"
touch "$scratch/active-xray"
for failure in bad-config fail-next-start; do
  touch "$scratch/$failure"
  if update_xray_core "$XRAY_COMPAT_VERSION"; then
    echo "Compatibility switch should fail with $failure" >&2
    exit 1
  fi
  rm -f "$scratch/$failure"
  test "$("$scratch/bin/xray" version)" = 'Xray 26.10.21'
  test -e "$scratch/active-xray"
done
update_xray_core "$XRAY_COMPAT_VERSION"
update_xray_core
test "$("$scratch/bin/xray" version)" = 'Xray 26.6.27'
test -e "$scratch/active-xray"
cmp "$scratch/etc/xray/config.json" "$UPDATE_BACKUP_DIR/xray/xray/config.json"
update_xray_core latest
test "$("$scratch/bin/xray" version)" = 'Xray 26.10.21'
update_snell_core # The v6 release in the fixture must not trigger an upgrade.
apk() { printf 'apk %s\n' "$*" >> "$scratch/packages"; }
upx() { test "$1" = -d; }
getcap() { echo "$1 cap_net_bind_service=ep"; }
setcap() { printf '%s\n' "$*" >> "$scratch/capabilities"; }
OS=alpine
printf '#!/bin/sh\necho "snell-server v5.0.0"\n' > "$scratch/bin/snell-server"
update_snell_core
grep -qx 'apk add --no-cache --virtual .snell-update-deps upx' "$scratch/packages"
grep -qx 'apk del .snell-update-deps' "$scratch/packages"
grep -q '^cap_net_bind_service=ep ' "$scratch/capabilities"
OS=debian
rm "$scratch/bin/xray"
if update_xray_core; then exit 1; else test "$?" -eq 2; fi

chronyc() { echo 'chronyc 4.6'; }
mock_manager=dnf
command() {
  if [ "${1-}" = -v ] && [ "${2-}" = dnf ]; then
    test "$mock_manager" = dnf
  else
    builtin command "$@"
  fi
}
apt-get() { printf 'apt-get %s\n' "$*" >> "$scratch/packages"; }
dnf() { printf 'dnf %s\n' "$*" >> "$scratch/packages"; }
yum() { printf 'yum %s\n' "$*" >> "$scratch/packages"; }
for OS in debian ubuntu ol rhel centos rocky almalinux alpine; do
  for mock_manager in dnf yum; do
    for running in 0 1; do
      service=chronyd
      if [ "$OS" = debian ] || [ "$OS" = ubuntu ]; then service=chrony; fi
      rm -f "$scratch/active-$service"
      if [ "$running" -eq 1 ]; then touch "$scratch/active-$service"; fi
      : > "$scratch/packages"
      update_chrony_package >/dev/null
      case "$OS" in
        debian|ubuntu) grep -q 'install --only-upgrade -y chrony' "$scratch/packages" ;;
        alpine) grep -qx 'apk upgrade chrony' "$scratch/packages"
          grep -qx 'apk upgrade chrony-openrc' "$scratch/packages" ;;
        *) grep -qx "$mock_manager upgrade -y chrony" "$scratch/packages" ;;
      esac
      if [ "$running" -eq 1 ]; then
        test -e "$scratch/active-$service"
      elif [ -e "$scratch/active-$service" ]; then
        echo 'Chrony must preserve the stopped state' >&2
        exit 1
      fi
    done
  done
done

# The aggregator must continue after a failure and report failure overall.
update_xray_core() { return 1; }
update_shadowsocks_rust() { echo ss >> "$scratch/continued"; return 0; }
update_snell_core() { echo snell >> "$scratch/continued"; return 2; }
update_chrony_package() { echo chrony >> "$scratch/continued"; return 0; }
if update_all_programs; then exit 1; fi
test "$(wc -l < "$scratch/continued")" -eq 3
echo 'Program update downloads, checksums, state preservation and rollback tests passed'
