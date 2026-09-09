#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/config"

# Load only the helpers under test; never execute the installer's main menu.
for name in prompt_read is_valid_port read_xray_port prepare_xray_config restart_xray_checked activate_xray_config; do
  awk -v name="$name" '$0 == name "() {" {inside=1} inside {print} inside && /^}$/ {exit}' "$repo/xrayvless.sh"
done | sed "s|/usr/local/etc/xray|$scratch/config|g" > "$scratch/helpers.sh"
source "$scratch/helpers.sh"
green() { :; }
red() { :; }

read_xray_port <<< ''
test "$PORT" = 443
read_xray_port <<< '00080'
test "$PORT" = 80
read_xray_port <<< $'0\n65536\ninvalid\n-1\n999999999999999999999\n65535'
test "$PORT" = 65535
if read_xray_port < /dev/null; then
  echo 'EOF must fail' >&2
  exit 1
fi

cat > "$scratch/xray" <<'EOF'
#!/usr/bin/env bash
set -eu
test "$1" = run && test "$2" = -test && test "$3" = -config
[[ "$4" == *.json ]]
jq -e '.inbounds[0].port | type == "number"' "$4" >/dev/null
EOF
chmod +x "$scratch/xray"
XRAY_BIN="$scratch/xray"
restart_xray_checked() {
  printf 'restart\n' >> "$scratch/restarts"
  if [ -f "$scratch/fail-next" ]; then
    rm "$scratch/fail-next"
    return 1
  fi
}

printf '{"inbounds":[{"port":12345}]}\n' > "$scratch/config/config.json"
cp "$scratch/config/config.json" "$scratch/original.json"
prepare_xray_config
printf '{"inbounds":[{"port":,}]}\n' > "$XRAY_CONFIG_CANDIDATE"
if activate_xray_config 2>/dev/null; then
  echo 'Malformed config was accepted' >&2
  exit 1
fi
cmp "$scratch/original.json" "$scratch/config/config.json"
test ! -f "$scratch/restarts"
test ! -e "$XRAY_CONFIG_CANDIDATE"

prepare_xray_config
printf '{"inbounds":[{"port":443}]}\n' > "$XRAY_CONFIG_CANDIDATE"
touch "$scratch/fail-next"
if activate_xray_config; then
  echo 'Failed restart was accepted' >&2
  exit 1
fi
cmp "$scratch/original.json" "$scratch/config/config.json"
test "$(wc -l < "$scratch/restarts")" -eq 2

prepare_xray_config
printf '{"inbounds":[{"port":443}]}\n' > "$XRAY_CONFIG_CANDIDATE"
activate_xray_config
test "$(jq '.inbounds[0].port' "$scratch/config/config.json")" = 443
test -z "$(find "$scratch/config" -name '.backup.*' -o -name '.candidate.*')"
echo 'Xray port validation and config rollback tests passed'
