#!/bin/bash
set -euo pipefail

get_xray_alpine_arch() {
  case "${1:-$(uname -m)}" in
    x86_64|amd64) echo 64 ;;
    i386|i486|i586|i686|x86) echo 32 ;;
    aarch64|arm64|armv8) echo arm64-v8a ;;
    armv7|armv7l) echo arm32-v7a ;;
    armv6l) echo arm32-v6 ;;
    *) echo "不支持的 Xray 架构: ${1:-$(uname -m)}" >&2; return 1 ;;
  esac
}

install_xray_alpine() (
  set -euo pipefail
  local arch version work
  arch=$(get_xray_alpine_arch "$(uname -m)")
  apk add --no-cache ca-certificates curl unzip jq openrc
  version=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er '.tag_name | select(type == "string" and test("^v[0-9][0-9.]*$"))')
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$work/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/download/$version/Xray-linux-$arch.zip"
  unzip -q "$work/xray.zip" -d "$work/unpacked"
  chmod +x "$work/unpacked/xray"
  # Execute before replacing the installed core: +x alone does not prove it runs.
  if ! "$work/unpacked/xray" version; then
    echo '❌ 下载的 Xray 内核无法运行，保留原有安装' >&2
    return 1
  fi
  if [ -f /usr/local/etc/xray/config.json ]; then
    "$work/unpacked/xray" run -test -config /usr/local/etc/xray/config.json
  fi
  mkdir -p /usr/local/bin /usr/local/etc/xray
  install -m 755 "$work/unpacked/xray" /usr/local/bin/xray.new
  mv -f /usr/local/bin/xray.new /usr/local/bin/xray
  cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF

  chmod +x /etc/init.d/xray
  rc-update add xray default
  if [ -f /usr/local/etc/xray/config.json ]; then
    rc-service xray restart
    sleep 1
    rc-service xray status
    pidof xray >/dev/null
  else
    echo '✅ Xray 内核安装完成，等待创建节点配置后启动'
  fi
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_xray_alpine
fi
