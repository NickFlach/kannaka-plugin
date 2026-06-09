#!/bin/sh
# Build kannaka-setup-macos.pkg — wraps install/install.sh. The postinstall runs
# the engine as the logged-in console user (pkg scripts run as root).
set -eu
VER="${1:-1.3.0}"
ROOT="$(pwd)/_pkgroot"
SCRIPTS="$(pwd)/_pkgscripts"
rm -rf "$ROOT" "$SCRIPTS"
mkdir -p "$ROOT/usr/local/share/kannaka" "$SCRIPTS"

cp install/install.sh "$ROOT/usr/local/share/kannaka/install.sh"
chmod 0755 "$ROOT/usr/local/share/kannaka/install.sh"

cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/sh
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  sudo -u "$CONSOLE_USER" sh /usr/local/share/kannaka/install.sh || true
else
  echo "Kannaka: run 'sh /usr/local/share/kannaka/install.sh' as your user."
fi
exit 0
EOF
chmod 0755 "$SCRIPTS/postinstall"

pkgbuild --root "$ROOT" --scripts "$SCRIPTS" \
  --identifier com.kannaka.setup --version "$VER" \
  --install-location / kannaka-setup-macos.pkg
echo "built kannaka-setup-macos.pkg (v${VER})"
