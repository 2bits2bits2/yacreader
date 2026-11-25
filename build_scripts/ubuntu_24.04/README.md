## Ubuntu 24.04 build script
You can use `build.sh` to build YACReader from scratch in `Ubuntu 24.04` with `7zip` (including `RAR5` support) and `poppler` (pdf). This build uses `Qt6`.

The script will create a folder next to it where all the downloads and building will happen, it will also install all the required dependencies. The script builds it and installs 7z.so in /usr/lib/7zip/. Once the scrip finishes succesfully `YACReader`, `YACReaderLibrary` and `YACReaderLibraryServer` should be installed in your system.

WARNIG: This doesn't work with the latest release (9.14), there is a bug and some of the code is still looking for the old p7zip library, you need to build from develop, to do so run: `build.sh develop`.

## .deb package (no root required to build)
`build_deb.sh` builds a self-contained `.deb` for Ubuntu 24.04 based systems
(Ubuntu 24.04, Linux Mint 22.x):

* bundles the official **Qt 6.9 LTS** binaries (via `aqtinstall`, needs `uv`)
  into `/opt/yacreader` because the distro Qt (6.4) is too old for the GUI,
* links the system `poppler` for PDF support (dev headers are fetched via
  `apt-get download` into a local sysroot, no root needed),
* uses the in-tree 7zip backend with a bundled `7z.so` (RAR5 support),
* installs thin `/usr/bin` wrappers, desktop files, icons, man pages and a
  systemd user unit.

Result: `dist/yacreader_<version>_amd64.deb`.

Verify it with the e2e test, which installs the package in a pristine
`ubuntu:24.04` container and checks that it installs, runs headless commands
and starts the GUI on a sample comic without crashing:

```bash
./build_deb.sh
./e2e_deb_test_docker.sh
```

See `PLAN.md` in the repository root for the design rationale.