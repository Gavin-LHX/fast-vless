#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Source only platform helpers, without installing packages or opening the menu.
for name in detect_os install_dependencies install_chrony_package start_chrony_service; do
  awk -v name="$name" '$0 == name "() {" {inside=1} inside {print} inside && /^}$/ {exit}' "$repo/xrayvless.sh"
done > "$scratch/helpers.sh"
# shellcheck source=/dev/null
source "$scratch/helpers.sh"
green() { :; }
red() { :; }

assert_os() {
  local id="$1" like="$2" expected="$3"
  printf 'NAME="Oracle Linux Server"\nVERSION_ID="9.8"\nID="%s"\nID_LIKE="%s"\n' "$id" "$like" > "$scratch/os-release"
  test "$(detect_os "$scratch/os-release")" = "$expected"
}

assert_os ol 'fedora' ol
assert_os oracle 'rhel fedora' ol
assert_os oraclelinux 'rhel' ol
assert_os rhel 'fedora' rhel
assert_os redhat '' rhel
assert_os redhatenterpriseserver '' rhel
assert_os redhatenterprise '' rhel
assert_os centos 'rhel fedora' centos
assert_os rocky 'rhel centos fedora' rocky
assert_os almalinux 'rhel centos fedora' almalinux
assert_os alma 'rhel' almalinux
assert_os custom 'fedora rhel' rhel
assert_os custom 'ubuntu debian' debian
assert_os custom '' custom
assert_os fedora '' fedora
assert_os ubuntu 'debian' ubuntu
assert_os debian '' debian
assert_os alpine '' alpine
test "$(detect_os "$scratch/missing-os-release")" = "$(uname -s)"

mock_manager=dnf
mock_has_curl=1
mock_has_chrony=0
mock_install_fail=0

command() {
  if [ "${1-}" = '-v' ]; then
    case "${2-}" in
      dnf|yum) test "$2" = "$mock_manager"; return ;;
      curl) test "$mock_has_curl" -eq 1; return ;;
      chronyc) test "$mock_has_chrony" -eq 1; return ;;
    esac
  fi
  builtin command "$@"
}

mock_install() {
  printf '%s\n' "$*" >> "$scratch/packages"
  if [ "$mock_install_fail" -eq 1 ]; then
    return 1
  fi
  if [ "${*: -1}" = chrony ]; then
    mock_has_chrony=1
  fi
}
dnf() { mock_install dnf "$@"; }
yum() { mock_install yum "$@"; }
systemctl() { printf '%s\n' "$*" >> "$scratch/services"; }

for OS in ol rhel centos rocky almalinux; do
  for mock_manager in dnf yum; do
    for mock_has_curl in 0 1; do
      : > "$scratch/packages"
      install_dependencies
      grep -q "^$mock_manager install -y " "$scratch/packages"
      grep -q 'ca-certificates' "$scratch/packages"
      grep -q 'vim-common' "$scratch/packages"
      if [ "$mock_has_curl" -eq 1 ]; then
        if grep -Eq '(^| )curl( |$)' "$scratch/packages"; then
          echo 'Existing curl/curl-minimal must be reused' >&2
          exit 1
        fi
      else
        grep -Eq '(^| )curl( |$)' "$scratch/packages"
      fi
      if [ "$OS" = centos ]; then
        grep -qx "$mock_manager install -y epel-release" "$scratch/packages"
      elif grep -q 'epel' "$scratch/packages"; then
        echo 'Oracle Linux and RHEL base dependencies must not add EPEL' >&2
        exit 1
      fi
    done
    : > "$scratch/packages"
    mock_has_chrony=0
    install_chrony_package
    grep -qx "$mock_manager install -y chrony" "$scratch/packages"
    : > "$scratch/services"
    start_chrony_service
    grep -qx 'enable --now chronyd' "$scratch/services"
  done
done

export OS=ol
mock_manager=dnf
mock_install_fail=1
if install_dependencies; then
  echo 'Dependency installation failures must propagate' >&2
  exit 1
fi
mock_has_chrony=0
if install_chrony_package; then
  echo 'Chrony installation failures must propagate' >&2
  exit 1
fi
mock_install_fail=0
mock_manager=none
if install_dependencies || install_chrony_package; then
  echo 'A missing RPM package manager must fail' >&2
  exit 1
fi

echo 'OS detection, RPM dependencies and Chrony platform tests passed'
