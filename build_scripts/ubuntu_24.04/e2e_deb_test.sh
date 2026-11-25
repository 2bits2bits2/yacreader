#!/bin/bash
# E2E test for the yacreader .deb package.
#
# Verifies that the package:
#   1. exists and is a valid .deb for package "yacreader" with the version from VERSION
#   2. installs via apt (dependencies auto-resolved)
#   3. ships all expected files (binaries, desktop files, icons, man pages,
#      server web assets, bundled 7z.so)
#   4. runs headless commands without crashing
#   5. starts the GUI (offscreen) on a sample .cbz and stays alive (no crash),
#      exercising the 7zip decompression backend
#   6. uninstalls cleanly
#
# Usage: sudo ./e2e_deb_test.sh [path/to/yacreader_*.deb]
#        or:    ./e2e_deb_test_docker.sh   (runs this script as root in an
#               ubuntu:24.04 container - same noble ABI as Linux Mint 22.x)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"

if [ "$(id -u)" -ne 0 ]; then
    echo "This test installs/removes packages and must run as root."
    echo "Either:  sudo $0"
    echo "or run the docker variant:  $SCRIPT_DIR/e2e_deb_test_docker.sh"
    exit 1
fi

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
    # check <description> <command...>
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

run_capture() {
    # run_capture <description> <command...> - passes if exit code 0 AND no crash signal
    local desc="$1"
    shift
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    case $rc in
        0) ok "$desc (exit 0)" ;;
        139 | 134 | 136 | 135) fail "$desc (crashed, exit $rc: $out)" ;;
        *) fail "$desc (exit $rc: $out)" ;;
    esac
}

echo "=== E2E test for yacreader .deb (version $VERSION) ==="

# ---------------------------------------------------------------------------
# 1. Package sanity
# ---------------------------------------------------------------------------
echo "[1/6] Package sanity"
DEB=""
if [ -n "${1:-}" ]; then
    if [ -f "$1" ]; then
        DEB="$1"
    else
        fail "given .deb does not exist: $1"
    fi
else
    DEB="$(ls "$DIST_DIR"/yacreader_"${VERSION}"*_amd64.deb 2>/dev/null | head -n 1)"
fi

if [ -z "${DEB:-}" ]; then
    fail "no .deb found in $DIST_DIR (yacreader_${VERSION}*_amd64.deb)"
    echo "$FAIL failing checks. Test aborted before install."
    exit 1
fi
ok "found .deb: $DEB"

check "dpkg-deb --info parses the package" dpkg-deb --info "$DEB"
check "package name is yacreader" bash -c "[ \"\$(dpkg-deb -f '$DEB' Package)\" = 'yacreader' ]"
PKG_VERSION="$(dpkg-deb -f "$DEB" Version)"
check "upstream version in $PKG_VERSION matches VERSION ($VERSION)" bash -c "[ \"\${PKG_VERSION%%-*}\" = '$VERSION' ]"

# ---------------------------------------------------------------------------
# 2. Install
# ---------------------------------------------------------------------------
echo "[2/6] Install"
apt-get remove -y yacreader >/dev/null 2>&1 || true
if apt-get install -y "$DEB" >/dev/null 2>&1; then
    ok "apt-get install succeeded (all dependencies resolved)"
else
    fail "apt-get install failed"
    echo "$FAIL failing checks. Aborting remaining tests."
    exit 1
fi
check "dpkg reports yacreader as installed" bash -c "dpkg -s yacreader | grep -q 'Status: install ok installed'"

# ---------------------------------------------------------------------------
# 3. Files present
# ---------------------------------------------------------------------------
echo "[3/6] Files present"
LIBDIR="/usr/lib/x86_64-linux-gnu"
check "/usr/bin/YACReader exists" test -x /usr/bin/YACReader
check "/usr/bin/YACReaderLibrary exists" test -x /usr/bin/YACReaderLibrary
check "/usr/bin/YACReaderLibraryServer exists" test -x /usr/bin/YACReaderLibraryServer
check "desktop file YACReader.desktop installed" test -f /usr/share/applications/YACReader.desktop
check "desktop file YACReaderLibrary.desktop installed" test -f /usr/share/applications/YACReaderLibrary.desktop
check "icon YACReader.svg installed" test -f /usr/share/icons/hicolor/scalable/apps/YACReader.svg
check "icon YACReaderLibrary.svg installed" test -f /usr/share/icons/hicolor/scalable/apps/YACReaderLibrary.svg
check "man page YACReader(1) installed" test -f /usr/share/man/man1/YACReader.1.gz
check "man page YACReaderLibrary(1) installed" test -f /usr/share/man/man1/YACReaderLibrary.1.gz
check "server web assets installed" test -f /usr/share/yacreader/server/index.html
check "bundled 7z.so installed (RAR5 support)" test -f "$LIBDIR/yacreader/7z.so"

# ---------------------------------------------------------------------------
# 4. Headless runs without crashing
# ---------------------------------------------------------------------------
echo "[4/6] Headless runs (isolated config)"
ISOLATED_HOME="$(mktemp -d)"
mkdir -p "$ISOLATED_HOME/config" "$ISOLATED_HOME/cache" "$ISOLATED_HOME/data" "$ISOLATED_HOME/state"
export HOME="$ISOLATED_HOME/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$ISOLATED_HOME/config"
export XDG_CACHE_HOME="$ISOLATED_HOME/cache"
export XDG_DATA_HOME="$ISOLATED_HOME/data"
export XDG_STATE_HOME="$ISOLATED_HOME/state"

run_capture "YACReaderLibraryServer --version" /usr/bin/YACReaderLibraryServer --version
run_capture "YACReaderLibraryServer --system-info" /usr/bin/YACReaderLibraryServer --system-info
run_capture "YACReaderLibraryServer list-libraries" /usr/bin/YACReaderLibraryServer list-libraries

export QT_QPA_PLATFORM=offscreen
run_capture "YACReader --help (offscreen)" /usr/bin/YACReader --help
run_capture "YACReaderLibrary --help (offscreen)" /usr/bin/YACReaderLibrary --help
unset QT_QPA_PLATFORM

# ---------------------------------------------------------------------------
# 5. Real GUI startup + archive decompression (7zip backend)
# ---------------------------------------------------------------------------
echo "[5/6] GUI startup on a sample .cbz (offscreen)"

# Build a tiny 3-page .cbz fixture
WORK="$(mktemp -d)"
PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
for i in 1 2 3; do
    echo "$PNG_B64" | base64 -d > "$WORK/page$i.png"
done
CBZ="$WORK/sample.cbz"
if (cd "$WORK" && python3 -c '
import sys, zipfile
with zipfile.ZipFile("sample.cbz", "w") as z:
    for i in (1, 2, 3):
        z.write(f"page{i}.png")
' 2>/dev/null); then
    ok "sample.cbz fixture created"
else
    fail "could not create sample.cbz fixture"
fi

if [ -f "$CBZ" ]; then
    QT_QPA_PLATFORM=offscreen /usr/bin/YACReader "$CBZ" >/dev/null 2>&1 &
    APP_PID=$!
    sleep 5
    if kill -0 "$APP_PID" 2>/dev/null; then
        ok "YACReader alive after 5s (started and kept running, no crash)"
    else
        wait "$APP_PID"
        rc=$?
        if [ "$rc" -eq 139 ] || [ "$rc" -eq 134 ]; then
            fail "YACReader CRASHED (exit $rc) while opening sample.cbz"
        else
            fail "YACReader exited early (exit $rc)"
        fi
    fi
    kill "$APP_PID" 2>/dev/null
    sleep 1
    kill -9 "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
else
    fail "skipping GUI startup test (no fixture)"
fi

# ---------------------------------------------------------------------------
# 6. Uninstall
# ---------------------------------------------------------------------------
echo "[6/6] Uninstall"
if apt-get remove -y yacreader >/dev/null 2>&1; then
    ok "apt-get remove succeeded"
else
    fail "apt-get remove failed"
fi
check "dpkg no longer reports yacreader as installed" bash -c "! dpkg -s yacreader 2>/dev/null | grep -q 'Status: install ok installed'"
check "/usr/bin/YACReader removed" bash "! -x /usr/bin/YACReader"
check "/usr/bin/YACReaderLibrary removed" bash "! -x /usr/bin/YACReaderLibrary"
check "/usr/bin/YACReaderLibraryServer removed" bash "! -x /usr/bin/YACReaderLibraryServer"

# cleanup
rm -rf "$WORK" "$ISOLATED_HOME"

echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
