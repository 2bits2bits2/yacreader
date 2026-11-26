#!/bin/bash
# Build a self-contained .deb package of YACReader for Ubuntu 24.04-based systems
# (Ubuntu 24.04 / Linux Mint 22.x), without requiring root.
#
# Why it looks like this:
#   * The GUI (develop branch) requires Qt >= 6.9 (RHI-based coverflow), but
#     Ubuntu 24.04-based distros ship Qt 6.4 in their repositories. The package
#     therefore bundles the official Qt 6.9 LTS binaries (glibc-compatible,
#     built for Ubuntu 22.04+) into /opt/yacreader and puts wrapper scripts in
#     /usr/bin, so it works on any 24.04-based system regardless of the distro
#     Qt version. RPATH + qt.conf keep the bundled Qt fully isolated.
#   * PDF support uses the system poppler (linked from an apt-downloaded
#     "sysroot" so no root is needed to install -dev packages; at runtime the
#     normal system poppler libraries are used and appear in Depends).
#   * Comic archive support uses the in-tree 7zip backend (7z2301 sources are
#     fetched by CMake FetchContent); the bundled 7z.so (with RAR5 support) is
#     shipped in the package itself.
#
# Output: dist/yacreader_<version>_amd64.deb
# Test:   ./e2e_deb_test_docker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/yacreader_build"
STAGE="$BUILD_DIR/stage"
SYSROOT="$BUILD_DIR/sysroot"
DIST_DIR="$SCRIPT_DIR/dist"
YACREADER_PREFIX="/opt/yacreader"
QT_VERSION="6.9.3"

YACREADER_VERSION="$(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
DEB_VERSION="${YACREADER_VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
DEB_FILE="$DIST_DIR/yacreader_${DEB_VERSION}_amd64.deb"

log() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(dpkg --print-architecture)" = "amd64" ] || die "this script builds an amd64 package"

# ---------------------------------------------------------------------------
# 0. Tools
# ---------------------------------------------------------------------------
command -v cmake >/dev/null || die "cmake missing"
command -v g++ >/dev/null || die "g++ missing (apt install build-essential)"

AQT="uvx --from aqtinstall aqt"

# ---------------------------------------------------------------------------
# 1. Qt 6.9 official binaries (cached between runs)
#    CI can override QT_DIR: jurplel/install-qt-action installs to
#    <dir>/Qt/<version>/<arch>
# ---------------------------------------------------------------------------
QT_DIR="${QT_DIR:-$BUILD_DIR/qt/$QT_VERSION/gcc_64}"
if [ ! -f "$QT_DIR/lib/cmake/Qt6/Qt6Config.cmake" ]; then
    command -v uv >/dev/null || die "uv missing (needed to fetch Qt via aqtinstall) or set QT_DIR to an existing Qt install"
    log "Downloading Qt $QT_VERSION (official binaries via aqtinstall)..."
    mkdir -p "$BUILD_DIR/qt"
    $AQT install-qt linux desktop "$QT_VERSION" linux_gcc_64 \
        -m qt5compat qtmultimedia qtshadertools qtspeech qtimageformats \
        --outputdir "$BUILD_DIR/qt"
fi
[ -d "$QT_DIR" ] || die "Qt directory $QT_DIR missing after aqt install"

# ---------------------------------------------------------------------------
# 2. Poppler "sysroot" (headers + link libs, extracted from .debs, no root)
# ---------------------------------------------------------------------------
log "Fetching poppler dev packages into a local sysroot..."
rm -rf "$SYSROOT"
mkdir -p "$SYSROOT" "$BUILD_DIR/debs"
cd "$BUILD_DIR/debs"
rm -f ./*.deb
apt-get download libpoppler-qt6-dev libpoppler-dev libpoppler134 \
    libpoppler-qt6-3t64 libxkbcommon-dev libxkbcommon0 >/dev/null
for f in ./*.deb; do dpkg -x "$f" "$SYSROOT/"; done
[ -f "$SYSROOT/usr/include/poppler/qt6/poppler-qt6.h" ] || die "poppler-qt6.h not found in sysroot"
# fail early on dangling .so symlinks (missing runtime libs)
dangling="$(find -L "$SYSROOT/usr/lib" -maxdepth 2 -type l 2>/dev/null | head -5)"
[ -z "$dangling" ] || die "dangling library symlinks in sysroot (missing runtime packages): $dangling"

# pkg-config only sees the sysroot (poppler-qt6, xkbcommon); host .pc files stay out
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

# ---------------------------------------------------------------------------
# 3. Configure + build
# ---------------------------------------------------------------------------
log "Configuring CMake..."
cd "$REPO_DIR"
cmake -B "$BUILD_DIR/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$YACREADER_PREFIX" \
    -DCMAKE_INSTALL_RPATH="\$ORIGIN/../lib" \
    -DCMAKE_BUILD_RPATH="$QT_DIR/lib" \
    -DCMAKE_PREFIX_PATH="$QT_DIR" \
    -DCMAKE_INCLUDE_PATH="$SYSROOT/usr/include;$SYSROOT/usr/include/x86_64-linux-gnu" \
    -DCMAKE_LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu" \
    -DDECOMPRESSION_BACKEND=7zip \
    -DPDF_BACKEND=poppler \
    -DBUILD_TESTS=ON \
    -DBUILD_SERVER_STANDALONE=OFF \
    -DBUILD_NUMBER="${BUILD_NUMBER}"

log "Building (this takes a while)..."
cmake --build "$BUILD_DIR/build" --parallel "$(nproc)"

# ---------------------------------------------------------------------------
# 4. Sanity: unit tests (offscreen)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 4. Sanity: pre-flight dependency resolution + unit tests (offscreen)
# ---------------------------------------------------------------------------
# The dynamic loader only reports the FIRST unresolved library per binary,
# so a failing test run would reveal missing libs one CI cycle at a time.
# This pre-flight collects the complete list of unresolved libraries across
# every test binary before ctest starts, with the exact search path ctest
# will use.
log "Pre-flight: resolving dependencies of all test binaries (complete report)..."
TEST_LIB_PATH="$QT_DIR/lib:$SYSROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
declare -A MISSING=()
declare -A NEEDERS=()
while IFS= read -r -d '' f; do
    unresolved="$(LD_LIBRARY_PATH="$TEST_LIB_PATH" ldd "$f" 2>/dev/null | awk '/=> not found/ {print $1}')"
    [ -z "$unresolved" ] && continue
    rel="${f#"$BUILD_DIR/build/"}"
    while IFS= read -r soname; do
        [ -z "$soname" ] && continue
        MISSING["$soname"]=1
        NEEDERS["$soname"]+="$rel "
    done < <(printf '%s\n' "$unresolved" | sort -u)
done < <(find "$BUILD_DIR/build/tests" -type f -perm -u+x -print0)

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "" >&2
    echo "PRE-FLIGHT FAILED - unresolved shared libraries (COMPLETE list, not just the first one):" >&2
    for soname in "${!MISSING[@]}"; do
        echo "  - $soname" >&2
        echo "      needed by: ${NEEDERS[$soname]}" >&2
    done
    echo "Fix: add the corresponding runtime + dev packages to the sysroot step in this script." >&2
    die "${#MISSING[@]} distinct unresolved libraries; see the complete list above"
fi
log "Pre-flight OK: every test binary resolves its libraries"

log "Running unit tests (offscreen)..."
# LD_LIBRARY_PATH is needed because DT_RUNPATH is not transitive: system poppler
# pulls in Qt transitively, and without it the loader would mix system Qt 6.4
# libs with the bundled Qt 6.9. The sysroot lib dir covers machines without
# poppler installed (the tests link against libpoppler from the sysroot).
QT_QPA_PLATFORM=offscreen \
LD_LIBRARY_PATH="$TEST_LIB_PATH" \
QT_PLUGIN_PATH="$QT_DIR/plugins" \
QML2_IMPORT_PATH="$QT_DIR/qml" \
XDG_DATA_HOME="$BUILD_DIR/xdg/data" \
XDG_CONFIG_HOME="$BUILD_DIR/xdg/config" \
XDG_CACHE_HOME="$BUILD_DIR/xdg/cache" \
ctest --test-dir "$BUILD_DIR/build" --output-on-failure -j"$(nproc)"

# ---------------------------------------------------------------------------
# 5. Install into staging tree
# ---------------------------------------------------------------------------
log "Installing into staging tree..."
rm -rf "$STAGE"
DESTDIR="$STAGE" cmake --install "$BUILD_DIR/build" --strip

# translations (.qm built by qt_add_translations)
mkdir -p "$STAGE$YACREADER_PREFIX/share/yacreader/languages"
find "$BUILD_DIR/build" -name '*.qm' -exec cp {} "$STAGE$YACREADER_PREFIX/share/yacreader/languages/" \;

# bundled 7z.so with RAR5 support (runtime looks in $LIBDIR/yacreader/7z.so first)
mkdir -p "$STAGE$YACREADER_PREFIX/lib/yacreader"
cp "$REPO_DIR/dependencies/7zip/linux/x86_64/7z.so" "$STAGE$YACREADER_PREFIX/lib/yacreader/7z.so"

# ---------------------------------------------------------------------------
# 6. Bundle Qt (libs, plugins, QML modules) + qt.conf
# ---------------------------------------------------------------------------
log "Bundling Qt runtime into the package..."
QT_LIB="$QT_DIR/lib"
QT_PLUGINS="$QT_DIR/plugins"
QT_QML="$QT_DIR/qml"

mkdir -p "$STAGE$YACREADER_PREFIX/lib" "$STAGE$YACREADER_PREFIX/plugins" "$STAGE$YACREADER_PREFIX/qml"

QT_LIBS=(
    libQt6Core.so.6 libQt6Gui.so.6 libQt6Widgets.so.6 libQt6Network.so.6
    libQt6Concurrent.so.6 libQt6Sql.so.6 libQt6Xml.so.6 libQt6DBus.so.6
    libQt6Qml.so.6 libQt6QmlMeta.so.6 libQt6QmlModels.so.6 libQt6QmlWorkerScript.so.6
    libQt6Quick.so.6 libQt6QuickControls2.so.6 libQt6QuickControls2Impl.so.6
    libQt6QuickTemplates2.so.6 libQt6QuickWidgets.so.6 libQt6QuickShapes.so.6
    libQt6Svg.so.6 libQt6OpenGL.so.6 libQt6OpenGLWidgets.so.6
    libQt6Multimedia.so.6 libQt6MultimediaWidgets.so.6
    libQt6Core5Compat.so.6 libQt6TextToSpeech.so.6 libQt6LabsSettings.so.6
    libicudata.so.73 libicui18n.so.73 libicuuc.so.73 libicutu.so.73 libicuio.so.73
)
for l in "${QT_LIBS[@]}"; do
    [ -f "$QT_LIB/$l" ] || die "bundled Qt lib missing: $l"
    cp -L "$QT_LIB/$l" "$STAGE$YACREADER_PREFIX/lib/"
done

# plugins
PLUGIN_SET=(
    platforms/libqoffscreen.so platforms/libqxcb.so platforms/libqvnc.so platforms/libqminimalegl.so
    imageformats/ iconengines/ sqldrivers/libqsqlite.so
    tls/ networkinformation/ texttospeech/
    platformthemes/ platforminputcontexts/ xcbglintegrations/ printsupport/
)
for p in "${PLUGIN_SET[@]}"; do
    if [ -d "$QT_PLUGINS/$p" ]; then
        cp -rL "$QT_PLUGINS/$p" "$STAGE$YACREADER_PREFIX/plugins/"
    elif [ -f "$QT_PLUGINS/$p" ]; then
        mkdir -p "$STAGE$YACREADER_PREFIX/plugins/$(dirname "$p")"
        cp -L "$QT_PLUGINS/$p" "$STAGE$YACREADER_PREFIX/plugins/$p"
    else
        die "bundled Qt plugin missing: $p"
    fi
done

# QML modules (everything, minus the heavy trees the app never imports)
log "Bundling QML modules..."
rm -rf "$BUILD_DIR/qml_copy"
cp -a "$QT_QML" "$BUILD_DIR/qml_copy"
for exclude in Qt3D QtCharts QtDataVisualization QtGraphs QtGrpc QtHelp QtLocation \
               QtPositioning QtPurchasing QtQuick3D QtRemoteObjects QtScxml QtSensors \
               QtSerialBus QtStateMachine QtTest QtTextToSpeech \
               QtVirtualKeyboard QtWebChannel QtWebEngine QtWebSockets QtWebView; do
    rm -rf "$BUILD_DIR/qml_copy/$exclude"
done
rm -rf "$BUILD_DIR/qml_copy/QtQuick3D" "$BUILD_DIR/qml_copy/Qt/labs/location"
cp -a "$BUILD_DIR/qml_copy/." "$STAGE$YACREADER_PREFIX/qml/"
rm -rf "$BUILD_DIR/qml_copy"

# auto-add every remaining Qt/ICU lib that bundled QML modules or plugins need
for pass in 1 2 3 4; do
    added=0
    while IFS= read -r soname; do
        [ -f "$STAGE$YACREADER_PREFIX/lib/$soname" ] && continue
        case "$soname" in
            libQt6*|libicu*) ;;
            *) continue ;;
        esac
        [ -f "$QT_LIB/$soname" ] || die "needed but not found in Qt install: $soname"
        cp -L "$QT_LIB/$soname" "$STAGE$YACREADER_PREFIX/lib/"
        log "auto-bundled: $soname"
        added=1
    done < <(find "$STAGE$YACREADER_PREFIX/lib" "$STAGE$YACREADER_PREFIX/plugins" "$STAGE$YACREADER_PREFIX/qml" \
        -type f \( -name '*.so*' -o -name '*.so' \) -exec sh -c '
            head -c4 "$1" | grep -q "ELF" && objdump -p "$1" 2>/dev/null | awk "/NEEDED/ {print \$2}"
        ' _ {} \; | sort -u)
    [ "$added" = 0 ] && break
done

# qt.conf next to the binaries keeps the bundled Qt self-contained
cat > "$STAGE$YACREADER_PREFIX/bin/qt.conf" <<EOF
[Paths]
Prefix=$YACREADER_PREFIX
Plugins=plugins
QmlImports=qml
Qml2Imports=qml
Translations=translations
Data=share
Settings=etc
EOF
mkdir -p "$STAGE$YACREADER_PREFIX/etc"

# ---------------------------------------------------------------------------
# 7. System-visible files: wrappers, desktop files, icons, man pages, unit
# ---------------------------------------------------------------------------
log "Adding wrappers and system integration files..."
mkdir -p "$STAGE/usr/bin"
for app in YACReader YACReaderLibrary YACReaderLibraryServer; do
    [ -f "$STAGE$YACREADER_PREFIX/bin/$app" ] || die "missing binary: $app"
    cat > "$STAGE/usr/bin/$app" <<EOF
#!/bin/sh
# LD_LIBRARY_PATH must be set here (not just RPATH): DT_RUNPATH is not
# transitive, so libraries pulled in by system libs (poppler -> Qt) would
# otherwise resolve against the distro's Qt instead of the bundled one.
export LD_LIBRARY_PATH="$YACREADER_PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec $YACREADER_PREFIX/bin/$app "\$@"
EOF
    chmod 755 "$STAGE/usr/bin/$app"
done

# desktop files, icons and man pages must live in the system share tree
mkdir -p "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/scalable/apps" "$STAGE/usr/share/man/man1"
mv "$STAGE$YACREADER_PREFIX/share/applications/"*.desktop "$STAGE/usr/share/applications/"
mv "$STAGE$YACREADER_PREFIX/share/icons/hicolor/scalable/apps/"*.svg "$STAGE/usr/share/icons/hicolor/scalable/apps/"
for m in "$STAGE$YACREADER_PREFIX/share/man/man1/"*.1; do
    gzip -9 -c "$m" > "$STAGE/usr/share/man/man1/$(basename "$m").gz"
done
rm -rf "$STAGE$YACREADER_PREFIX/share/applications" "$STAGE$YACREADER_PREFIX/share/icons" "$STAGE$YACREADER_PREFIX/share/man"

# systemd user unit (ExecStart already points at /usr/bin wrapper)
mkdir -p "$STAGE/usr/lib/systemd/user"
[ -f "$STAGE$YACREADER_PREFIX/lib/systemd/user/yacreaderlibraryserver.service" ] && \
    mv "$STAGE$YACREADER_PREFIX/lib/systemd/user/yacreaderlibraryserver.service" "$STAGE/usr/lib/systemd/user/"

# ---------------------------------------------------------------------------
# 8. Compute Depends from all ELF files in the staging tree
# ---------------------------------------------------------------------------
log "Computing package dependencies..."
# bundled sonames must not become Depends
declare -A BUNDLED=()
while IFS= read -r f; do
    soname="$(objdump -p "$f" 2>/dev/null | awk '/SONAME/ {print $2}')"
    [ -n "$soname" ] && BUNDLED[$soname]=1
    BUNDLED["$(basename "$f")"]=1
done < <(find "$STAGE$YACREADER_PREFIX/lib" "$STAGE$YACREADER_PREFIX/plugins" -type f)

# fallback map for sonames not installed on this host
declare -A SONAME_MAP=(
    [libavcodec.so.60]=libavcodec60 [libavformat.so.60]=libavformat60
    [libavutil.so.58]=libavutil58 [libswresample.so.4]=libswresample4
    [libswscale.so.7]=libswscale7 [libavtp.so.0]=libavtp0
    [libspeechd.so.2]=libspeechd2 [libxkbcommon.so.0]=libxkbcommon0
    [libxkbcommon-x11.so.0]=libxkbcommon-x11-0
)

declare -A DEPS=()
UNRESOLVED=()
NEEDED_LIST="$(find "$STAGE" -type f -exec sh -c '
    head -c4 "$1" | grep -q "ELF" && objdump -p "$1" 2>/dev/null | awk "/NEEDED/ {print \$2}"
' _ {} \; | sort -u)"
for soname in $NEEDED_LIST; do
    [ -n "${BUNDLED[$soname]:-}" ] && continue
    if [ -n "${SONAME_MAP[$soname]:-}" ]; then
        DEPS["${SONAME_MAP[$soname]}"]=1
        continue
    fi
    # dpkg-query may list both a runtime and a -dev package; prefer the runtime one
    # (guard with || true: grep exiting 1 must not trip `set -e`)
    pkg="$(dpkg-query -S "$soname" 2>/dev/null | cut -d: -f1 | grep -v -- '-dev$' | head -n1 || true)"
    if [ -z "$pkg" ]; then
        pkg="$(dpkg-query -S "$soname" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    fi
    if [ -n "$pkg" ]; then
        DEPS["$pkg"]=1
    else
        UNRESOLVED+=("$soname")
    fi
done

if [ "${#UNRESOLVED[@]}" -gt 0 ]; then
    echo "" >&2
    echo "DEPENDENCY MAPPING FAILED - unmapped shared libraries (COMPLETE list, not just the first one):" >&2
    for soname in "${UNRESOLVED[@]}"; do
        echo "  - $soname" >&2
    done
    echo "Fix: either install the owning package on the build machine, or add entries to" >&2
    echo "     SONAME_MAP in build_deb.sh (soname -> distro package name)." >&2
    die "${#UNRESOLVED[@]} unmapped libraries; see the complete list above"
fi

DEPENDS="$(printf '%s\n' "${!DEPS[@]}" | sort -u | paste -sd, -)"
log "Depends: $DEPENDS"

# ---------------------------------------------------------------------------
# 9. Control file + maintainer scripts
# ---------------------------------------------------------------------------
INSTALLED_SIZE_KB="$(du -sk "$STAGE" | cut -f1)"

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: yacreader
Version: $DEB_VERSION
Section: graphics
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_SIZE_KB
Maintainer: YACReader packaging <contact@yacreader.com>
Depends: $DEPENDS
Homepage: https://www.yacreader.com
Description: Yet Another Comic Reader - viewer, library manager and server
 YACReader is a full featured comic reader with support for .cbr, .cbz, .cb7,
 .cbt, .zip, .rar and PDF files. This package includes:
 .
  * YACReader - the comic viewer with a 3D cover flow
  * YACReaderLibrary - the library manager with Comic Vine integration
  * YACReaderLibraryServer - a headless web/comic server
 .
 This build is self-contained: it bundles Qt 6.9 into /opt/yacreader so it runs
 on any Ubuntu 24.04 based system (Ubuntu 24.04, Linux Mint 22.x), independent
 of the distro's Qt version. PDF support uses the system poppler.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database -q /usr/share/mime || true
fi
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

# ---------------------------------------------------------------------------
# 10. Build the .deb
# ---------------------------------------------------------------------------
log "Building $DEB_FILE ..."
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/yacreader_*.deb
dpkg-deb --build --root-owner-group "$STAGE" "$DEB_FILE"

log "Done: $DEB_FILE ($(du -h "$DEB_FILE" | cut -f1))"
echo "Next: run ./e2e_deb_test_docker.sh"
