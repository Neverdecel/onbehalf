#!/usr/bin/env bash
# Install onbehalf from this checkout on an Ubuntu or Arch host. Run as root.
#
#   sudo ./install.sh                 check the host, then install
#   sudo ./install.sh --install-deps  also install missing system packages
#
# Safe to run again: an update installs over the old files and keeps
# /etc/onbehalf, the shared stack and all users.
set -euo pipefail

src=$(dirname "$(readlink -f "$0")")
prefix=${PREFIX:-/usr/local}
install_deps=no
for a in "$@"; do
  case $a in
    --install-deps) install_deps=yes ;;
    -h | --help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $a" >&2
      exit 2
      ;;
  esac
done

ONBEHALF_LIB="$src/lib/onbehalf"
. "$ONBEHALF_LIB/ui.sh"

heading "onbehalf $(cat "$src/lib/onbehalf/VERSION") installer"
[ "$(id -u)" = 0 ] || {
  err "run the installer as root"
  fix "sudo $0 $*"
  exit 1
}
ok "the installer runs as root"

. /etc/os-release
case $ID in
  ubuntu)
    ok "$PRETTY_NAME"
    pm_install="apt-get install -y"
    pm_update="apt-get update"
    declare -A pkg=([curl]=curl [jq]=jq [git]=git [runuser]=util-linux [getent]=libc-bin
      [useradd]=passwd [usermod]=passwd [userdel]=passwd [pkill]=procps [pgrep]=procps)
    ;;
  arch)
    ok "$PRETTY_NAME"
    pm_install="pacman -S --noconfirm --needed"
    pm_update="pacman -Sy"
    declare -A pkg=([curl]=curl [jq]=jq [git]=git [runuser]=util-linux [getent]=glibc
      [useradd]=shadow [usermod]=shadow [userdel]=shadow [pkill]=procps-ng [pgrep]=procps-ng)
    ;;
  *)
    err "$PRETTY_NAME is not supported. onbehalf supports Ubuntu and Arch"
    exit 1
    ;;
esac

missing=()
for t in "${!pkg[@]}"; do command -v "$t" >/dev/null || missing+=("${pkg[$t]}"); done
if [ ${#missing[@]} -gt 0 ]; then
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  if [ "$install_deps" = yes ]; then
    $pm_update >/dev/null && $pm_install "${missing[@]}" >/dev/null
    ok "installed ${missing[*]}"
  else
    err "missing packages: ${missing[*]}"
    fix "sudo $0 --install-deps"
    exit 1
  fi
else
  ok "required tools are installed"
fi

if command -v opencode >/dev/null && [[ $(command -v opencode) != /home/* ]]; then
  ok "$(opencode --version 2>/dev/null) is installed for the full host"
else
  warn "OpenCode is not installed for the full host. Every user must use the same version"
  fix "install OpenCode for the full host with the OpenCode documentation. See $prefix/share/onbehalf/docs/operator-guide.md#opencode"
fi

install -d -m 0755 "$prefix/bin" "$prefix/lib/onbehalf" "$prefix/lib/onbehalf/tools" "$prefix/share/onbehalf"
install -m 0644 "$src"/lib/onbehalf/*.sh "$src/lib/onbehalf/VERSION" "$prefix/lib/onbehalf/"
rm -f "$prefix"/lib/onbehalf/tools/*.sh
install -m 0644 "$src"/lib/onbehalf/tools/*.sh "$prefix/lib/onbehalf/tools/"
install -m 0755 "$src/bin/onbehalf" "$prefix/bin/onbehalf"
install -d -m 0755 /etc/profile.d
install -m 0644 "$src/lib/onbehalf/login-profile.sh" /etc/profile.d/onbehalf.sh
rm -rf "$prefix/share/onbehalf/docs" "$prefix/share/onbehalf/examples"
cp -R "$src/docs" "$src/examples" "$prefix/share/onbehalf/"
chmod -R u=rwX,go=rX "$prefix/share/onbehalf"
ok "installed onbehalf to $prefix (docs in $prefix/share/onbehalf/docs)"

heading "Next"
if [ -r /etc/onbehalf/onbehalf.conf ]; then
  echo "  This host is already set up. Check it:  sudo onbehalf doctor"
else
  cat <<EOF
  1. Run a model gateway             $prefix/share/onbehalf/docs/operator-guide.md#model-gateway
  2. Prepare the stack source        $prefix/share/onbehalf/docs/operator-guide.md#step-2-prepare-the-stack-source
  3. Run the host setup wizard       sudo onbehalf setup
     Or use init, stack install, user add and doctor in your automation.
EOF
fi
