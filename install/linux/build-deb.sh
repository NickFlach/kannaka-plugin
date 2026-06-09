#!/bin/sh
# Build kannaka-setup-linux.deb — wraps install/install.sh. The postinst runs the
# engine as the invoking (non-root) user so paths land in their home, not root's.
set -eu
VER="${1:-1.3.0}"
ROOT="$(pwd)/_deb"
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/kannaka" "$ROOT/usr/bin"

cp install/install.sh "$ROOT/usr/share/kannaka/install.sh"
chmod 0755 "$ROOT/usr/share/kannaka/install.sh"

cat > "$ROOT/usr/bin/kannaka-setup" <<'EOF'
#!/bin/sh
exec sh /usr/share/kannaka/install.sh "$@"
EOF
chmod 0755 "$ROOT/usr/bin/kannaka-setup"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: kannaka-setup
Version: ${VER}
Section: utils
Priority: optional
Architecture: all
Depends: curl
Maintainer: Nick Flach <nflach78@gmail.com>
Description: Kannaka installer — HRM memory, NATS swarm, Claude Code statusline
 Installs the kannaka binary plus the Claude Code plugin (live HRM + swarm
 statusline and swarm/memory MCP tools). Re-run 'kannaka-setup' any time.
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
RUNAS="${SUDO_USER:-}"
if [ -n "$RUNAS" ] && [ "$RUNAS" != "root" ]; then
  su - "$RUNAS" -c "sh /usr/share/kannaka/install.sh" || true
else
  echo "Kannaka: run 'kannaka-setup' as your user to finish installation."
fi
exit 0
EOF
chmod 0755 "$ROOT/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$ROOT" "kannaka-setup-linux.deb"
echo "built kannaka-setup-linux.deb (v${VER})"
