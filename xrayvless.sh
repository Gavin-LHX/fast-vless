#!/bin/bash
set -e
#====== 彩色输出函数 (必须放前面) ======
green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; } 

if [ "$(id -u)" -ne 0 ]; then
  red "❌ 请使用 root 权限运行本脚本"
  exit 1
fi

LINK_HISTORY_FILE="/root/xray_link_history.txt"
REALITY_CERT_MAX=8192
REALITY_LAST_RESORT_DOMAIN="www.microsoft.com"
SS_RUST_FALLBACK_VERSION="v1.24.0"
SS2022_METHOD="2022-blake3-aes-128-gcm"
SNELL_VERSION="v5.0.1"
SNELL_DOWNLOAD_BASE="https://dl.nssurge.com/snell"

prompt_read() {
  local prompt="$1"
  local var_name="$2"

  if [ -t 0 ]; then
    read -e -r -p "$prompt" "${var_name?}"
  else
    read -r -p "$prompt" "${var_name?}"
  fi
}

url_encode() {
  jq -nr --arg v "$1" '$v|@uri'
}

base64_urlsafe() {
  printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | sed 's/=*$//'
}

get_public_ip() {
  local ip

  ip=$(curl -fsSL --max-time 8 https://ipv4.ip.sb 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)
  fi
  printf '%s\n' "$ip"
}

#====== 安装依赖 ======
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    OS=$(uname -s)
  fi
  echo "$OS"
}
OS=$(detect_os)
install_dependencies() {
  green "检测到系统: $OS，安装依赖..."
  case "$OS" in
    ubuntu|debian)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip xz-utils jq xxd openssl tar >/dev/null 2>&1
      ;;
    centos|rhel|rocky|alma)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y curl wget unzip xz jq vim-common openssl tar >/dev/null 2>&1
      else
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y curl wget unzip xz jq vim-common openssl tar >/dev/null 2>&1
      fi
      ;;
    alpine)
      apk update
      apk add --no-cache curl wget unzip xz jq vim bash openssl tar openrc
      ;;
    *)
      red "不支持的系统: $OS"
      exit 1
      ;;
  esac
}
# 安装前置
install_dependencies

install_chrony_package() {
  local package_manager

  if command -v chronyc >/dev/null 2>&1; then
    if [ "$OS" = "alpine" ] && [ ! -x /etc/init.d/chronyd ]; then
      green "正在补装 Chrony OpenRC 服务..."
      if ! apk add --no-cache chrony-openrc >/dev/null 2>&1; then
        red "❌ 未找到 Alpine Chrony OpenRC 服务脚本"
        return 1
      fi
    fi
    return 0
  fi

  green "正在安装 Chrony..."
  case "$OS" in
    ubuntu|debian)
      if ! apt-get update >/dev/null 2>&1; then
        red "❌ apt 软件源更新失败，无法安装 Chrony"
        return 1
      fi
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1; then
        red "❌ Chrony 安装失败"
        return 1
      fi
      ;;
    centos|rhel|rocky|alma)
      if command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
      else
        package_manager="yum"
      fi
      if ! "$package_manager" install -y chrony >/dev/null 2>&1; then
        red "❌ Chrony 安装失败"
        return 1
      fi
      ;;
    alpine)
      if ! apk add --no-cache chrony >/dev/null 2>&1; then
        red "❌ Chrony 安装失败"
        return 1
      fi
      if [ ! -x /etc/init.d/chronyd ]; then
        apk add --no-cache chrony-openrc >/dev/null 2>&1 || true
      fi
      if [ ! -x /etc/init.d/chronyd ]; then
        red "❌ Chrony 已安装，但未找到 Alpine OpenRC 服务脚本"
        return 1
      fi
      ;;
    *)
      red "❌ 当前系统不支持自动安装 Chrony: $OS"
      return 1
      ;;
  esac

  if ! command -v chronyc >/dev/null 2>&1; then
    red "❌ Chrony 安装完成后仍未找到 chronyc"
    return 1
  fi
  green "✅ Chrony 安装完成"
}

start_chrony_service() {
  local service_name alternate_service

  if [ "$OS" = "alpine" ]; then
    if ! command -v rc-service >/dev/null 2>&1; then
      red "❌ 未找到 OpenRC，无法启动 Chrony"
      return 1
    fi
    rc-update add chronyd default >/dev/null 2>&1 || true
    if ! rc-service chronyd status >/dev/null 2>&1; then
      if ! rc-service chronyd start >/dev/null 2>&1; then
        red "❌ chronyd 服务启动失败"
        return 1
      fi
    fi
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    red "❌ 未找到 systemd，无法启动 Chrony"
    return 1
  fi

  case "$OS" in
    ubuntu|debian)
      service_name="chrony"
      alternate_service="chronyd"
      ;;
    *)
      service_name="chronyd"
      alternate_service="chrony"
      ;;
  esac

  if systemctl enable --now "$service_name" >/dev/null 2>&1; then
    return 0
  fi
  if systemctl enable --now "$alternate_service" >/dev/null 2>&1; then
    return 0
  fi

  red "❌ Chrony 服务启动失败"
  return 1
}

sync_time_with_chrony() {
  local tracking

  green "正在使用 Chrony 同步系统时间..."
  if ! install_chrony_package; then
    return 1
  fi
  if ! start_chrony_service; then
    return 1
  fi

  chronyc -a online >/dev/null 2>&1 || true
  chronyc -a makestep 0.1 1 >/dev/null 2>&1 || true
  chronyc -a burst 4/4 >/dev/null 2>&1 || true

  if ! chronyc waitsync 15 1.0 0.0 1 >/dev/null 2>&1; then
    chronyc -a makestep >/dev/null 2>&1 || true
    if ! chronyc waitsync 3 1.0 0.0 1 >/dev/null 2>&1; then
      yellow "⚠️ Chrony 服务已启用，但暂未确认时间同步完成"
      return 1
    fi
  fi

  chronyc -a makestep >/dev/null 2>&1 || true
  tracking=$(chronyc tracking 2>/dev/null | awk -F': ' '
    /Stratum|System time|Last offset|Leap status/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      printf "%s: %s; ", $1, $2
    }
  ')
  green "✅ Chrony 时间同步完成，服务已设为开机启动"
  [ -n "$tracking" ] && echo "$tracking"
  green "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

sync_time_before_node_creation() {
  if ! sync_time_with_chrony; then
    yellow "⚠️ 将继续创建节点。部分 LXC 容器没有调整系统时钟的权限，请确认宿主机时间准确。"
  fi
}

#====== 检测xray是否安装 =====
check_and_install_xray() {
  if command -v xray >/dev/null 2>&1; then
    green "✅ Xray 已安装，跳过安装"
  else
    green "❗检测到 Xray 未安装，正在安装..."
	if [ "$OS" = "alpine" ]; then
		bash <(curl -L https://raw.githubusercontent.com/Gavin-LHX/fast-vless/main/xrayinstall-alpine.sh)
	else
		bash <(curl -L https://raw.githubusercontent.com/Gavin-LHX/fast-vless/main/xrayinstall.sh)
	fi
    
    XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
    if [ ! -x "$XRAY_BIN" ]; then
      red "❌ Xray 安装失败，请检查"
      exit 1
    fi
    green "✅ Xray 安装完成"
  fi
}
#====== 流媒体解锁检测 ======
check_streaming_unlock() {
  bash <(curl -L ip.check.place) -y
  read -rp "按任意键返回菜单..."
}

#====== IP 纯净度检测 ======
check_ip_clean() {
  bash <(curl -L ip.check.place) -y
  read -rp "按任意键返回菜单..."
}

save_link_history() {
  local protocol="$1"
  local remark="$2"
  local link="$3"

  {
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') | $protocol | $remark ====="
    echo "$link"
    echo
  } >> "$LINK_HISTORY_FILE"
}

show_link_history() {
  clear
  green "======= 历史节点链接 ======="
  if [ -s "$LINK_HISTORY_FILE" ]; then
    cat "$LINK_HISTORY_FILE"
  else
    yellow "暂无历史节点配置。安装 VLESS、Trojan、SS2022 或 Snell 节点后会自动保存。"
  fi
  read -rp "按任意键返回菜单..."
}

normalize_reality_domain() {
  local raw="$1"
  local domain

  domain=$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  domain=${domain#http://}
  domain=${domain#https://}
  domain=${domain%%/*}
  domain=${domain%%\?*}
  domain=${domain%%#*}
  domain=${domain##*@}
  domain=${domain%%:*}
  domain=${domain%.}
  printf '%s\n' "$domain"
}

detect_server_country() {
  local info country

  info=$(curl -fsSL --max-time 8 https://ipinfo.io/json 2>/dev/null || true)
  country=$(printf '%s\n' "$info" | jq -r '.country // empty' 2>/dev/null || true)
  printf '%s\n' "$country" | tr '[:lower:]' '[:upper:]'
}

get_reality_candidates() {
  local country="$1"

  case "$country" in
    CN|HK|MO|TW)
      cat <<EOF
autopatchcn.yuanshen.com
autopatchhk.yuanshen.com
autopatchcn.bhsr.com
bundle.bh3.com
game.gtimg.cn
ossweb-img.qq.com
nie.res.netease.com
adl.netease.com
EOF
      ;;
    JP|KR)
      cat <<EOF
autopatchos.starrails.com
launcher-webstatic.hoyoverse.com
download-porter.hoyoverse.com
autopatchhk.yuanshen.com
game.gtimg.cn
EOF
      ;;
    SG|MY|TH|VN|PH|ID)
      cat <<EOF
sg-public-api.hoyoverse.com
sg-public-data-api.hoyoverse.com
sg-hk4e-api.hoyoverse.com
sg-public-api.hoyolab.com
launcher-webstatic.hoyoverse.com
download-porter.hoyoverse.com
sdk-os-static.hoyoverse.com
g.alicdn.com
img.alicdn.com
gw.alipayobjects.com
www.alibabagroup.com
EOF
      ;;
    US|CA|GB|IE|FR|DE|NL|BE|LU|CH|AT|ES|PT|IT|SE|NO|DK|FI|PL|CZ|HU|RO|BG|GR|AU|NZ)
      cat <<EOF
launcher-webstatic.hoyoverse.com
download-porter.hoyoverse.com
autopatchos.starrails.com
game.gtimg.cn
nie.res.netease.com
EOF
      ;;
  esac
}

get_global_reality_candidates() {
  cat <<EOF
launcher-webstatic.hoyoverse.com
download-porter.hoyoverse.com
autopatchcn.yuanshen.com
game.gtimg.cn
nie.res.netease.com
EOF
}

probe_reality_domain() {
  local xray_bin="$1"
  local domain="$2"
  local output sni_ok max_len

  domain=$(normalize_reality_domain "$domain")
  if [ -z "$domain" ]; then
    yellow "跳过空域名"
    return 1
  fi

  yellow "探测 Reality 域名: $domain"
  output=$("$xray_bin" tls ping "$domain" 2>&1 || true)
  sni_ok=$(printf '%s\n' "$output" | awk 'BEGIN { in_sni=0 } /Pinging with SNI/ { in_sni=1 } in_sni && /Handshake succeeded/ { print "1"; exit }')
  max_len=$(printf '%s\n' "$output" | awk '
    BEGIN { in_sni=0; max=0 }
    /Pinging with SNI/ { in_sni=1; next }
    in_sni && /Certificate chain.*total length:/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+$/) {
          if ($i > max) max=$i
          break
        }
      }
    }
    END { if (max > 0) print max }
  ')

  if [ "$sni_ok" = "1" ] && [ -n "$max_len" ] && [ "$max_len" -lt "$REALITY_CERT_MAX" ]; then
    green "✅ $domain 可用，证书链长度: $max_len"
    return 0
  fi

  if [ -n "$max_len" ]; then
    yellow "跳过 $domain，证书链长度 $max_len 不满足 < $REALITY_CERT_MAX"
  else
    yellow "跳过 $domain，SNI 握手失败或无法读取证书链长度"
  fi
  return 1
}

select_reality_domain() {
  local xray_bin="$1"
  local country="$2"
  local domain seen

  seen=" "
  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    case "$seen" in
      *" $domain "*) continue ;;
    esac
    seen="$seen$domain "

    if [ "$domain" = "$REALITY_LAST_RESORT_DOMAIN" ]; then
      yellow "CDN 候选均不可用，开始测试微软最后兜底域名。"
    fi

    if probe_reality_domain "$xray_bin" "$domain"; then
      SNI="$domain"
      return 0
    fi
  done <<EOF
$(get_reality_candidates "$country")
$(get_global_reality_candidates)
$REALITY_LAST_RESORT_DOMAIN
EOF

  return 1
}

choose_reality_domain() {
  local xray_bin="$1"
  local manual normalized country

  while true; do
    prompt_read "Reality 域名/SNI（回车自动按地区选择，手动输入则先探测）: " manual
    normalized=$(normalize_reality_domain "$manual")
    if [ -n "$normalized" ]; then
      if [ "$normalized" != "$manual" ]; then
        yellow "已识别域名: $normalized"
      fi

      if probe_reality_domain "$xray_bin" "$normalized"; then
        SNI="$normalized"
        REALITY_COUNTRY="MANUAL"
        green "已使用手动指定的 Reality 域名: $SNI"
        return 0
      fi
      red "该域名未通过 Xray 探测，请重新输入，或直接回车自动选择。"
      continue
    fi

    country=$(detect_server_country)
    country=${country:-UNKNOWN}
    REALITY_COUNTRY="$country"
    green "检测到服务器地区: $country"

    if select_reality_domain "$xray_bin" "$country"; then
      green "Reality 已选择: $SNI (地区: $REALITY_COUNTRY)"
      return 0
    fi

    red "自动候选域名均未通过探测，请手动输入可用域名，或按 Ctrl+C 退出。"
  done
}

get_latest_shadowsocks_rust_version() {
  local version

  version=$(curl -fsSL --max-time 10 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
  version=${version:-$SS_RUST_FALLBACK_VERSION}
  printf '%s\n' "$version"
}

get_shadowsocks_rust_target() {
  local flavor="$1"
  local arch
  local float_suffix

  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      printf 'x86_64-unknown-linux-%s\n' "$flavor"
      ;;
    aarch64|arm64)
      printf 'aarch64-unknown-linux-%s\n' "$flavor"
      ;;
    armv7l|armv7)
      if [ "$flavor" = "musl" ]; then
        printf 'armv7-unknown-linux-musleabihf\n'
      else
        printf 'armv7-unknown-linux-gnueabihf\n'
      fi
      ;;
    armv6l|arm)
      if grep -qw vfp /proc/cpuinfo 2>/dev/null; then
        float_suffix="eabihf"
      else
        float_suffix="eabi"
      fi
      if [ "$flavor" = "musl" ]; then
        printf 'arm-unknown-linux-musl%s\n' "$float_suffix"
      else
        printf 'arm-unknown-linux-gnu%s\n' "$float_suffix"
      fi
      ;;
    i386|i686)
      printf 'i686-unknown-linux-musl\n'
      ;;
    mips)
      [ "$flavor" = "musl" ] && return 1
      printf 'mips-unknown-linux-gnu\n'
      ;;
    mipsel)
      [ "$flavor" = "musl" ] && return 1
      printf 'mipsel-unknown-linux-gnu\n'
      ;;
    mips64el)
      [ "$flavor" = "musl" ] && return 1
      printf 'mips64el-unknown-linux-gnuabi64\n'
      ;;
    riscv64)
      printf 'riscv64gc-unknown-linux-%s\n' "$flavor"
      ;;
    loongarch64)
      printf 'loongarch64-unknown-linux-%s\n' "$flavor"
      ;;
    *)
      return 1
      ;;
  esac
}

check_and_install_shadowsocks_rust() {
  local flavor version target url tmp_dir ssserver_path sslocal_path

  if command -v ssserver >/dev/null 2>&1; then
    green "✅ shadowsocks-rust 已安装，跳过下载"
    return 0
  fi

  if [ "$OS" = "alpine" ]; then
    flavor="musl"
  else
    flavor="gnu"
  fi

  if ! target=$(get_shadowsocks_rust_target "$flavor"); then
    red "❌ 当前架构不支持 shadowsocks-rust 自动安装: $(uname -m) / $flavor"
    exit 1
  fi

  version=$(get_latest_shadowsocks_rust_version)
  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$version/shadowsocks-$version.$target.tar.xz"
  tmp_dir=$(mktemp -d)

  green "正在下载 shadowsocks-rust $version ($target)..."
  if ! wget -q -O "$tmp_dir/shadowsocks.tar.xz" "$url"; then
    if [ "$version" != "$SS_RUST_FALLBACK_VERSION" ]; then
      yellow "latest 下载失败，回退到 $SS_RUST_FALLBACK_VERSION"
      version="$SS_RUST_FALLBACK_VERSION"
      url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$version/shadowsocks-$version.$target.tar.xz"
      wget -q -O "$tmp_dir/shadowsocks.tar.xz" "$url" || {
        rm -rf "$tmp_dir"
        red "❌ shadowsocks-rust 下载失败: $url"
        exit 1
      }
    else
      rm -rf "$tmp_dir"
      red "❌ shadowsocks-rust 下载失败: $url"
      exit 1
    fi
  fi

  tar -xJf "$tmp_dir/shadowsocks.tar.xz" -C "$tmp_dir"
  ssserver_path=$(find "$tmp_dir" -type f -name ssserver | head -n 1)
  sslocal_path=$(find "$tmp_dir" -type f -name sslocal | head -n 1)
  if [ -z "$ssserver_path" ] || [ -z "$sslocal_path" ]; then
    rm -rf "$tmp_dir"
    red "❌ shadowsocks-rust 压缩包中未找到 ssserver/sslocal"
    exit 1
  fi

  mv "$ssserver_path" /usr/local/bin/ssserver
  mv "$sslocal_path" /usr/local/bin/sslocal
  chmod +x /usr/local/bin/ssserver /usr/local/bin/sslocal
  rm -rf "$tmp_dir"
  green "✅ shadowsocks-rust 安装完成"
}

install_ss2022() {
  local port remark password encoded_userinfo encoded_remark ip link

  sync_time_before_node_creation
  check_and_install_shadowsocks_rust
  prompt_read "SS2022 监听端口（默认 8388）: " port
  port=${port:-8388}
  prompt_read "节点备注（默认 SS2022）: " remark
  remark=${remark:-SS2022}
  password=$(openssl rand -base64 16)

  mkdir -p /etc/shadowsocks
  cat > /etc/shadowsocks/config.json <<EOF
{
  "server": "::",
  "server_port": $port,
  "password": "$password",
  "method": "$SS2022_METHOD",
  "mode": "tcp_and_udp",
  "fast_open": true,
  "timeout": 300
}
EOF

  if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/shadowsocks <<'EOF'
#!/sbin/openrc-run

name="shadowsocks"
description="Shadowsocks-Rust Server"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks/config.json"
command_background="yes"
pidfile="/run/${name}.pid"

depend() {
    need net
}

start_pre() {
    ulimit -Sn 51200 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/shadowsocks
    rc-update add shadowsocks default
    rc-service shadowsocks restart || rc-service shadowsocks start
  else
    cat > /etc/systemd/system/shadowsocks.service <<'EOF'
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable shadowsocks
    systemctl restart shadowsocks
  fi

  ip=$(get_public_ip)
  encoded_userinfo=$(base64_urlsafe "$SS2022_METHOD:$password")
  encoded_remark=$(url_encode "$remark")
  link="ss://$encoded_userinfo@$ip:$port#$encoded_remark"
  save_link_history "SS2022" "$remark" "$link"
  green "✅ SS2022 节点链接如下："
  echo "$link"
  read -rp "按任意键返回菜单..."
}

uninstall_ss2022() {
  if [ "$OS" = "alpine" ]; then
    rc-service shadowsocks stop >/dev/null 2>&1 || true
    rc-update del shadowsocks default >/dev/null 2>&1 || true
    rm -f /etc/init.d/shadowsocks
  else
    systemctl stop shadowsocks >/dev/null 2>&1 || true
    systemctl disable shadowsocks >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/shadowsocks.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -rf /etc/shadowsocks
  rm -f /usr/local/bin/ssserver /usr/local/bin/sslocal
  green "✅ SS2022 已卸载"
  read -rp "按任意键返回菜单..."
}

get_snell_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'amd64\n'
      ;;
    i386|i486|i586|i686)
      printf 'i386\n'
      ;;
    aarch64|arm64)
      printf 'aarch64\n'
      ;;
    armv7l|armv7)
      printf 'armv7l\n'
      ;;
    *)
      return 1
      ;;
  esac
}

get_snell_sha256() {
  case "$1" in
    amd64)
      printf '9bea1c2b9e35b73b31634856c04d18c393072b9e5dcde6a32781d8b8f908c539\n'
      ;;
    i386)
      printf '6a3e30928315427d6f747f26408d0f74eb88f460344d0e1fcb3f7c32c708a09d\n'
      ;;
    aarch64)
      printf '2f178bf5ac468ce1a130454efa40a0603fbbe4e47ecc4880a989f4abc7f824cf\n'
      ;;
    armv7l)
      printf '14489f3e857569c8835dd3598b7ea6bca5371d4290ac7cf0f6c8dfb3381c1fb2\n'
      ;;
    *)
      return 1
      ;;
  esac
}

check_and_install_snell_server() {
  local arch url tmp_dir version_output expected_sha actual_sha

  if [ "$OS" = "alpine" ]; then
    green "正在检查 Snell 的 Alpine glibc 兼容运行库..."
    if ! apk add --no-cache gcompat libstdc++ libgcc libcap-utils >/dev/null 2>&1; then
      red "❌ Alpine gcompat 安装失败，无法运行官方 Snell 内核"
      return 1
    fi
  fi

  if [ -x /usr/local/bin/snell-server ]; then
    version_output=$(/usr/local/bin/snell-server -v 2>&1 || true)
    if printf '%s\n' "$version_output" | grep -q "snell-server $SNELL_VERSION"; then
      if [ "$OS" = "alpine" ]; then
        if setcap cap_net_bind_service=+ep /usr/local/bin/snell-server 2>/dev/null && \
          getcap /usr/local/bin/snell-server 2>/dev/null | grep -q 'cap_net_bind_service'; then
          SNELL_ALPINE_LOW_PORT_SUPPORTED=1
        else
          SNELL_ALPINE_LOW_PORT_SUPPORTED=0
        fi
      fi
      green "✅ 官方 Snell Server $SNELL_VERSION 已安装，跳过下载"
      return 0
    fi
  fi

  if ! arch=$(get_snell_arch); then
    red "❌ 官方 Snell Server 不支持当前架构: $(uname -m)"
    return 1
  fi

  url="$SNELL_DOWNLOAD_BASE/snell-server-$SNELL_VERSION-linux-$arch.zip"
  tmp_dir=$(mktemp -d)
  green "正在下载官方 Snell Server $SNELL_VERSION ($arch)..."

  if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp_dir/snell-server.zip" "$url"; then
    rm -rf "$tmp_dir"
    red "❌ Snell Server 下载失败: $url"
    return 1
  fi
  expected_sha=$(get_snell_sha256 "$arch")
  actual_sha=$(sha256sum "$tmp_dir/snell-server.zip" | awk '{print $1}')
  if [ "$actual_sha" != "$expected_sha" ]; then
    rm -rf "$tmp_dir"
    red "❌ Snell Server SHA-256 校验失败"
    return 1
  fi
  if ! unzip -q "$tmp_dir/snell-server.zip" -d "$tmp_dir"; then
    rm -rf "$tmp_dir"
    red "❌ Snell Server 解压失败"
    return 1
  fi
  if [ ! -f "$tmp_dir/snell-server" ]; then
    rm -rf "$tmp_dir"
    red "❌ 官方压缩包中未找到 snell-server"
    return 1
  fi

  if [ "$OS" = "alpine" ]; then
    if ! apk add --no-cache --virtual .snell-install-deps upx >/dev/null 2>&1; then
      rm -rf "$tmp_dir"
      red "❌ Alpine UPX 安装失败，无法转换官方 Snell 内核"
      return 1
    fi
    if ! upx -d "$tmp_dir/snell-server" >/dev/null 2>&1; then
      apk del .snell-install-deps >/dev/null 2>&1 || true
      rm -rf "$tmp_dir"
      red "❌ 官方 Snell 内核的 UPX 解包失败"
      return 1
    fi
    apk del .snell-install-deps >/dev/null 2>&1 || true
  fi

  chmod +x "$tmp_dir/snell-server"
  version_output=$("$tmp_dir/snell-server" -v 2>&1 || true)
  if ! printf '%s\n' "$version_output" | grep -q "snell-server $SNELL_VERSION"; then
    rm -rf "$tmp_dir"
    red "❌ 下载的 Snell Server 版本校验失败"
    return 1
  fi

  install -m 0755 "$tmp_dir/snell-server" /usr/local/bin/snell-server
  if [ "$OS" = "alpine" ]; then
    if setcap cap_net_bind_service=+ep /usr/local/bin/snell-server 2>/dev/null && \
      getcap /usr/local/bin/snell-server 2>/dev/null | grep -q 'cap_net_bind_service'; then
      SNELL_ALPINE_LOW_PORT_SUPPORTED=1
    else
      SNELL_ALPINE_LOW_PORT_SUPPORTED=0
      yellow "⚠️ 当前 Alpine 文件系统不支持低端口 capability，请使用 1024-65535 端口"
    fi
  fi
  rm -rf "$tmp_dir"
  green "✅ 官方 Snell Server $SNELL_VERSION 安装完成"
}

ensure_snell_user() {
  local user_created=0

  mkdir -p /etc/snell
  if [ "$OS" = "alpine" ]; then
    if ! grep -q '^snell:' /etc/group 2>/dev/null; then
      addgroup -S snell >/dev/null
    fi
    if ! id snell >/dev/null 2>&1; then
      adduser -S -D -H -s /sbin/nologin -G snell snell >/dev/null
      user_created=1
    fi
  else
    if ! grep -q '^snell:' /etc/group 2>/dev/null; then
      groupadd --system snell
    fi
    if ! id snell >/dev/null 2>&1; then
      useradd --system --gid snell --no-create-home --shell /usr/sbin/nologin snell
      user_created=1
    fi
  fi

  if [ "$user_created" -eq 1 ]; then
    touch /etc/snell/.managed-user
  fi
}

write_snell_service() {
  if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/snell <<'EOF'
#!/sbin/openrc-run

name="Snell v5 Server"
description="Official Snell v5 Proxy Server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_user="snell:snell"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    ulimit -Sn 65535 2>/dev/null || true
}
EOF
    chmod +x /etc/init.d/snell
  else
    cat > /etc/systemd/system/snell.service <<'EOF'
[Unit]
Description=Official Snell v5 Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snell
Group=snell
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  fi
}

start_snell_service() {
  if [ "$OS" = "alpine" ]; then
    rc-update add snell default >/dev/null 2>&1 || true
    if rc-service snell status >/dev/null 2>&1; then
      rc-service snell restart
    else
      rc-service snell start
    fi
    sleep 1
    if ! rc-service snell status >/dev/null 2>&1; then
      red "❌ Snell OpenRC 服务启动失败"
      return 1
    fi
  else
    systemctl daemon-reload
    systemctl enable snell >/dev/null
    systemctl restart snell
    if ! systemctl is-active --quiet snell; then
      systemctl status snell --no-pager || true
      red "❌ Snell systemd 服务启动失败"
      return 1
    fi
  fi
}

open_snell_firewall_port() {
  local port="$1"
  local proto
  local state_file="/etc/snell/.managed-firewall"
  local ufw_added=0 firewalld_added=0

  if [ -f "$state_file" ]; then
    close_snell_firewall_ports
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for proto in tcp udp; do
      if ! ufw show added 2>/dev/null | grep -Eq "^ufw allow ${port}/${proto}([[:space:]]|$)"; then
        if ufw allow "$port/$proto" >/dev/null; then
          printf 'ufw|%s|%s\n' "$port" "$proto" >> "$state_file"
          ufw_added=1
        else
          yellow "⚠️ UFW 放行 $port/$proto 失败，请手动检查防火墙"
        fi
      fi
    done
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for proto in tcp udp; do
      if ! firewall-cmd --permanent --query-port="$port/$proto" >/dev/null 2>&1; then
        if firewall-cmd --permanent --add-port="$port/$proto" >/dev/null; then
          printf 'firewalld|%s|%s\n' "$port" "$proto" >> "$state_file"
          firewalld_added=1
        else
          yellow "⚠️ firewalld 放行 $port/$proto 失败，请手动检查防火墙"
        fi
      fi
    done
    if [ "$firewalld_added" -eq 1 ]; then
      firewall-cmd --reload >/dev/null
    fi
  fi

  if [ -s "$state_file" ]; then
    chmod 0600 "$state_file"
  else
    rm -f "$state_file"
  fi
  [ "$ufw_added" -eq 1 ] && green "✅ UFW 已放行 Snell 所需端口"
  [ "$firewalld_added" -eq 1 ] && green "✅ firewalld 已放行 Snell 所需端口"
  return 0
}

close_snell_firewall_ports() {
  local firewall port proto
  local state_file="/etc/snell/.managed-firewall"
  local reload_firewalld=0

  [ -f "$state_file" ] || return 0
  while IFS='|' read -r firewall port proto; do
    if ! is_valid_port "$port" || { [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; }; then
      continue
    fi
    case "$firewall" in
      ufw)
        if command -v ufw >/dev/null 2>&1; then
          ufw --force delete allow "$port/$proto" >/dev/null 2>&1 || true
        fi
        ;;
      firewalld)
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
          firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null 2>&1 || true
          reload_firewalld=1
        fi
        ;;
    esac
  done < "$state_file"
  if [ "$reload_firewalld" -eq 1 ]; then
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  rm -f "$state_file"
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

install_snell_v5() {
  local port remark psk ip surge_name surge_config yaml_name yaml_server yaml_psk yaml_config history_config

  SNELL_ALPINE_LOW_PORT_SUPPORTED=1
  sync_time_before_node_creation
  check_and_install_snell_server || return 1

  while true; do
    prompt_read "Snell 监听端口（默认 6160，TCP/UDP 同端口）: " port
    port=${port:-6160}
    if is_valid_port "$port" && { [ "$OS" != "alpine" ] || [ "$port" -ge 1024 ] || [ "$SNELL_ALPINE_LOW_PORT_SUPPORTED" -eq 1 ]; }; then
      break
    fi
    if is_valid_port "$port" && [ "$OS" = "alpine" ] && [ "$port" -lt 1024 ]; then
      red "❌ 当前 Alpine 文件系统无法授予低端口权限，请选择 1024-65535"
    else
      red "❌ 端口必须是 1-65535 之间的整数"
    fi
  done
  prompt_read "节点备注（默认 Snell-v5）: " remark
  remark=${remark:-Snell-v5}
  psk=$(openssl rand -hex 24)

  ensure_snell_user
  cat > /etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:$port
psk = $psk
EOF
  chown root:snell /etc/snell/snell-server.conf
  chmod 0640 /etc/snell/snell-server.conf

  write_snell_service
  start_snell_service || return 1
  open_snell_firewall_port "$port"

  ip=$(get_public_ip)
  if [ -z "$ip" ]; then
    red "❌ 无法获取服务器公网 IPv4，请检查网络"
    return 1
  fi

  surge_name=$(printf '%s' "$remark" | tr ',=' '__')
  surge_config="$surge_name = snell, $ip, $port, psk=$psk, version=5, reuse=false"
  yaml_name=$(jq -Rn --arg v "$remark" '$v')
  yaml_server=$(jq -Rn --arg v "$ip" '$v')
  yaml_psk=$(jq -Rn --arg v "$psk" '$v')
  yaml_config=$(cat <<EOF
- name: $yaml_name
  type: snell
  server: $yaml_server
  port: $port
  psk: $yaml_psk
  version: 5
  udp: true
  reuse: false
EOF
)
  history_config=$(cat <<EOF
Surge:
$surge_config

YAML:
$yaml_config
EOF
)
  save_link_history "Snell v5" "$remark" "$history_config"

  green "✅ Snell v5 节点部署完成"
  green "协议参数: version=5, udp=true, reuse=false, TLS/obfs=关闭"
  echo
  yellow "Surge 配置（v5 UDP 自动启用）:"
  echo "$surge_config"
  echo
  yellow "YAML 配置:"
  echo "$yaml_config"
  read -rp "按任意键返回菜单..."
}

uninstall_snell_v5() {
  local remove_managed_user=0

  [ -f /etc/snell/.managed-user ] && remove_managed_user=1
  if [ "$OS" = "alpine" ]; then
    rc-service snell stop >/dev/null 2>&1 || true
    rc-update del snell default >/dev/null 2>&1 || true
    rm -f /etc/init.d/snell
  else
    systemctl stop snell >/dev/null 2>&1 || true
    systemctl disable snell >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/snell.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  close_snell_firewall_ports
  rm -rf /etc/snell
  rm -f /usr/local/bin/snell-server
  if [ "$remove_managed_user" -eq 1 ]; then
    if [ "$OS" = "alpine" ]; then
      deluser snell >/dev/null 2>&1 || true
      delgroup snell >/dev/null 2>&1 || true
    else
      userdel snell >/dev/null 2>&1 || true
      groupdel snell >/dev/null 2>&1 || true
    fi
  fi
  green "✅ Snell v5 已卸载"
  read -rp "按任意键返回菜单..."
}

generate_vless_enc_pair() {
  local xray_bin="$1"
  local output section

  output=$("$xray_bin" vlessenc 2>&1 || true)
  section=$(printf '%s\n' "$output" | awk '
    /Authentication: ML-KEM-768/ { flag=1; next }
    /^Authentication:/ && flag { flag=0 }
    flag { print }
  ')
  VLESS_DECRYPTION=$(printf '%s\n' "$section" | awk -F'"' '/"decryption":/ { print $4; exit }')
  VLESS_ENCRYPTION=$(printf '%s\n' "$section" | awk -F'"' '/"encryption":/ { print $4; exit }')

  if [ -z "$VLESS_DECRYPTION" ] || [ -z "$VLESS_ENCRYPTION" ]; then
    red "❌ 无法解析 xray vlessenc 的 ML-KEM-768 输出"
    echo "$output"
    exit 1
  fi
}

install_trojan_reality() {
  sync_time_before_node_creation
  check_and_install_xray
  XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
  read -rp "监听端口（如 443）: " PORT
  read -rp "节点备注（如：trojanNode）: " REMARK
  choose_reality_domain "$XRAY_BIN"

  PASSWORD=$(openssl rand -hex 8)
  KEYS=$($XRAY_BIN x25519)
  PRIV_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/Private(Key| key)/ {print $2; exit}')
  PUB_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/PublicKey|Public key|Password \(PublicKey\)/ {print $2; exit}')
  if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
    red "Failed to parse x25519 keypair. Please check Xray output."
    echo "$KEYS"
    exit 1
  fi
  SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)

  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "trojan",
    "settings": {
      "clients": [{ "password": "$PASSWORD", "email": "$REMARK"}]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  if [ "$OS" = "alpine" ]; then
      rc-service xray restart
      rc-update add xray default
  else
      systemctl daemon-reexec
      systemctl restart xray
      systemctl enable xray
  fi
  IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
  LINK="trojan://$PASSWORD@$IP:$PORT?security=reality&sni=$SNI&pbk=$PUB_KEY&sid=$SHORT_ID&type=tcp&headerType=none#$REMARK"
  save_link_history "Trojan Reality" "$REMARK" "$LINK"
  green "✅ Trojan Reality 节点链接如下："
  echo "$LINK"
  read -rp "按任意键返回菜单..."
}

install_vless_enc_vision_flow() {
  sync_time_before_node_creation
  check_and_install_xray
  XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
  read -rp "监听端口（如 443）: " PORT
  read -rp "节点备注: " REMARK
  generate_vless_enc_pair "$XRAY_BIN"

  UUID=$(cat /proc/sys/kernel/random/uuid)

  mkdir -p /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "email": "$REMARK" , "flow": "xtls-rprx-vision"}],
      "decryption": "$VLESS_DECRYPTION"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "none"
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  "$XRAY_BIN" run -test -config /usr/local/etc/xray/config.json >/dev/null
  if [ "$OS" = "alpine" ]; then
      rc-service xray restart
      rc-update add xray default
  else
      systemctl daemon-reexec
      systemctl restart xray
      systemctl enable xray
  fi

  IP=$(get_public_ip)
  ENCRYPTION_PARAM=$(url_encode "$VLESS_ENCRYPTION")
  REMARK_PARAM=$(url_encode "$REMARK")
  LINK="vless://$UUID@$IP:$PORT?type=tcp&security=none&encryption=$ENCRYPTION_PARAM&flow=xtls-rprx-vision#$REMARK_PARAM"
  save_link_history "VLESS enc Vision flow" "$REMARK" "$LINK"
  green "✅ VLESS + enc + Vision flow 节点链接如下："
  echo "$LINK"
  read -rp "按任意键返回菜单..."
}

#====== 主菜单 ======
while true; do
  clear
  green "======= VLESS Reality 一键脚本V6.3正式版 by L.H.X ======="
  echo "1) 安装并配置 VLESS Reality Vision节点"  
  echo "2）生成Trojan Reality节点"
  echo "3) 生成 VLESS 中转链接"
  echo "4) 开启 BBR 加速"
  echo "5) 检查 IP 纯净度 & 流媒体解锁"
  echo "6) Ookla Speedtest 测试"
  echo "7) 卸载 Xray"
  echo "8) 查看历史节点链接"
  echo "9) 安装并配置 SS2022 节点"
  echo "10) 安装并配置 VLESS + enc + Vision flow 节点"
  echo "11) 卸载 SS2022"
  echo "12) 安装 Chrony 并同步系统时间"
  echo "13) 安装并配置 Snell v5 节点"
  echo "14) 卸载 Snell v5"
  echo "0) 退出"
  echo
  read -rp "请选择操作: " choice

  case "$choice" in
    1)
      sync_time_before_node_creation
      check_and_install_xray
      XRAY_BIN=$(command -v xray || echo "/usr/local/bin/xray")
      read -rp "监听端口（如 443）: " PORT
      read -rp "节点备注: " REMARK
      choose_reality_domain "$XRAY_BIN"
      UUID=$(cat /proc/sys/kernel/random/uuid)
      KEYS=$($XRAY_BIN x25519)
      PRIV_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/Private(Key| key)/ {print $2; exit}')
      PUB_KEY=$(printf '%s\n' "$KEYS" | awk -F': ' '/PublicKey|Public key|Password \(PublicKey\)/ {print $2; exit}')
      if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
        red "Failed to parse x25519 keypair. Please check Xray output."
        echo "$KEYS"
        exit 1
      fi
      SHORT_ID=$(head -c 4 /dev/urandom | xxd -p)

      mkdir -p /usr/local/etc/xray
      cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "email": "$REMARK" , "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

	  if [ "$OS" = "alpine" ]; then
	      rc-service xray restart
	      rc-update add xray default
	  else
	      systemctl daemon-reexec
          systemctl restart xray
          systemctl enable xray
	  fi
      IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
      LINK="vless://$UUID@$IP:$PORT?type=tcp&security=reality&flow=xtls-rprx-vision&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#$REMARK"
      save_link_history "VLESS Reality Vision" "$REMARK" "$LINK"
      green "✅ 节点链接如下："
      echo "$LINK"
      read -rp "按任意键返回菜单..."
      ;;
    2)
      install_trojan_reality
      ;;
    3)
      read -rp "请输入原始 VLESS 链接: " old_link
      read -rp "请输入中转服务器地址（IP 或域名）: " new_server
      new_link=$(echo "$old_link" | sed -E "s#(@)[^:]+#\\1$new_server#")
      green "🎯 生成的新中转链接："
      echo "$new_link"
      read -rp "按任意键返回菜单..."
      ;;

    4)
	  cat > /etc/sysctl.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
	  sysctl -p && sysctl --system
      green "✅ BBR 加速已启用"
      read -rp "按任意键返回菜单..."
      ;;

    5)
      check_streaming_unlock
      ;;

    6)
      wget -q https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz
      tar -zxf ookla-speedtest-1.2.0-linux-x86_64.tgz
      chmod +x speedtest
      ./speedtest --accept-license --accept-gdpr
      rm -f speedtest speedtest.5 speedtest.md ookla-speedtest-1.2.0-linux-x86_64.tgz
      read -rp "按任意键返回菜单..."
      ;;

    7)
      if [ "$OS" = "alpine" ]; then
	   	rc-service xray stop
        rc-update del xray
	  else
	  	systemctl stop xray
        systemctl disable xray
	  fi
      
      
      rm -rf /usr/local/etc/xray /usr/local/bin/xray
      green "✅ Xray 已卸载"
      read -rp "按任意键返回菜单..."
      ;;

    8)
      show_link_history
      ;;

    9)
      install_ss2022
      ;;

    10)
      install_vless_enc_vision_flow
      ;;

    11)
      uninstall_ss2022
      ;;

    12)
      if ! sync_time_with_chrony; then
        yellow "⚠️ 请检查网络、NTP 可达性，或容器是否具有调整系统时间的权限。"
      fi
      read -rp "按任意键返回菜单..."
      ;;

    13)
      install_snell_v5
      ;;

    14)
      uninstall_snell_v5
      ;;

    0)
      exit 0
      ;;

    *)
      red "❌ 无效选项，请重试"
      sleep 1
      ;;
  esac
done
