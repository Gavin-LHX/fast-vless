#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Source only helpers; keep installation and service operations inside a sandbox.
sed "s|/usr/local/|$scratch/local/|g; s|/etc/init.d/|$scratch/init.d/|g" \
  "$repo/xrayinstall-alpine.sh" > "$scratch/installer.sh"
source "$scratch/installer.sh"
mkdir -p "$scratch/init.d" "$scratch/bin"
for pair in 'x86_64 64' 'amd64 64' 'i686 32' 'aarch64 arm64-v8a' \
  'arm64 arm64-v8a' 'armv7l arm32-v7a' 'armv6l arm32-v6'; do
  read -r machine expected <<< "$pair"
  test "$(get_xray_alpine_arch "$machine")" = "$expected"
done
if get_xray_alpine_arch unsupported 2>/dev/null; then
  echo 'Unsupported architectures must fail' >&2
  exit 1
fi

uname() { echo aarch64; }
apk() { :; }
rc-update() { :; }
rc-service() { printf '%s\n' "$*" >> "$scratch/services"; }
sleep() { :; }
pidof() { return 0; }
curl() {
  local output="" previous="" arg
  for arg in "$@"; do
    if [ "$previous" = -o ]; then output="$arg"; fi
    previous="$arg"
  done
  if [[ "${*: -1}" == */releases/latest ]]; then
    printf '{"tag_name":"v26.10.21"}\n'
  elif [[ "${*: -1}" == *.dgst ]]; then
    printf 'SHA2-256= %s\n' "$(sha256sum "${output%.dgst}" | awk '{print $1}')" > "$output"
  else
    printf '%s\n' "${*: -1}" > "$scratch/url"
    test "$mode" != download-fail || return 1
    printf 'archive\n' > "$output"
  fi
}
unzip() {
  mkdir -p "$4"
  if [ "$mode" = invalid-binary ]; then
    printf '#!/bin/sh\nexit 126\n' > "$4/xray"
  else
    local version
    version=$(sed -E 's|.*/download/v([^/]+)/.*|\1|' "$scratch/url")
    printf '#!/bin/sh\necho "Xray %s"\n' "$version" > "$4/xray"
  fi
}

# Run failure cases in fresh Bash processes, so errexit remains enabled.
export scratch
export -f uname apk rc-update rc-service sleep pidof curl unzip
for mode in download-fail invalid-binary; do
  export mode
  mkdir -p "$scratch/local/bin"
  printf 'original-core\n' > "$scratch/local/bin/xray"
  if bash "$scratch/installer.sh"; then
    echo "$mode must fail" >&2
    exit 1
  fi
  grep -qx original-core "$scratch/local/bin/xray"
  test ! -e "$scratch/services"
done

export mode=success
bash "$scratch/installer.sh"
grep -q '/Xray-linux-arm64-v8a.zip$' "$scratch/url"
test "$("$scratch/local/bin/xray" version)" = 'Xray 26.10.21'
test ! -e "$scratch/services" # No config yet: no false service success.
bash "$scratch/installer.sh" --version v26.6.27
grep -q '/v26.6.27/Xray-linux-arm64-v8a.zip$' "$scratch/url"
test "$("$scratch/local/bin/xray" version)" = 'Xray 26.6.27'
mkdir -p "$scratch/local/etc/xray"
echo '{}' > "$scratch/local/etc/xray/config.json"
bash "$scratch/installer.sh"
grep -qx 'xray restart' "$scratch/services"
grep -qx 'xray status' "$scratch/services"

# Main installer must reject an executable that cannot actually run.
awk '/^check_and_install_xray\(\) \{/ {inside=1} inside {print} inside && /^}$/ {exit}' \
  "$repo/xrayvless.sh" > "$scratch/check.sh"
source "$scratch/check.sh"
green() { :; }
red() { :; }
printf '#!/bin/sh\nexit 126\n' > "$scratch/bin/xray"
chmod +x "$scratch/bin/xray"
PATH="$scratch/bin:$PATH"
if check_and_install_xray; then
  echo 'Broken installed core must be rejected' >&2
  exit 1
fi
echo 'Alpine architecture, download failures, binary execution and service checks passed'
