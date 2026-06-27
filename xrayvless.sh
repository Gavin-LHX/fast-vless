#!/bin/bash
set -e
#====== 彩色输出函数 (必须放前面) ======
green() { echo -e "\033[32m$1\033[0m"; }
red()   { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; } 
LINK_HISTORY_FILE="/root/xray_link_history.txt"
REALITY_CERT_MAX=8192
REALITY_LAST_RESORT_DOMAIN="www.microsoft.com"

prompt_read() {
  local prompt="$1"
  local var_name="$2"

  if [ -t 0 ]; then
    read -e -r -p "$prompt" "$var_name"
  else
    read -r -p "$prompt" "$var_name"
  fi
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
      sudo apt update
      sudo apt install -y curl wget xz-utils jq xxd >/dev/null 2>&1
      ;;
    centos|rhel|rocky|alma)
      sudo yum install -y epel-release
      sudo yum install -y curl wget xz jq vim-common >/dev/null 2>&1
      ;;
    alpine)
      sudo apk update
      sudo apk add --no-cache curl wget xz jq vim bash openssl
      ;;
    *)
      red "不支持的系统: $OS"
      exit 1
      ;;
  esac
}
# 安装前置
install_dependencies

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
    yellow "暂无历史节点链接。安装 VLESS 或 Trojan 节点后会自动保存。"
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

install_trojan_reality() {
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
#====== 主菜单 ======
while true; do
  clear
  green "======= VLESS Reality 一键脚本V6.2正式版 by L.H.X ======="
  echo "1) 安装并配置 VLESS Reality Vision节点"  
  echo "2）生成Trojan Reality节点"
  echo "3) 生成 VLESS 中转链接"
  echo "4) 开启 BBR 加速"
  echo "5) 检查 IP 纯净度 & 流媒体解锁"
  echo "6) Ookla Speedtest 测试"
  echo "7) 卸载 Xray"
  echo "8) 查看历史节点链接"
  echo "0) 退出"
  echo
  read -rp "请选择操作: " choice

  case "$choice" in
    1)
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

    0)
      exit 0
      ;;

    *)
      red "❌ 无效选项，请重试"
      sleep 1
      ;;
  esac
done
