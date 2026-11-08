# Linux build and native startup validation

Date: 2026-11-08. Target: Debian 13 x86-64, Flutter 3.47.9 / Dart 3.13.7.

## Dependency installation

This cloud machine has neither `sudo` nor the managed system-package helper. Its GTK runtime is installed, while compiler and GTK development packages were initially absent.

`scripts/setup-linux.sh` installs development dependencies in a user-owned prefix. It creates a separate APT configuration and package cache, authenticates official Debian main/updates/security metadata with the existing Debian archive keyring, downloads the resolved packages with normal APT checksum verification, and extracts them without changing system packages or sources. It relocates local pkg-config paths and connects development links to existing compatible runtime libraries.

The script also installs a complete OpenJDK 21 toolchain in the prefix. The pre-existing system Java installation was a runtime without `javac`; Gradle requires the compiler.

Tested installation and repeat execution:

```sh
scripts/setup-linux.sh /workspace/.toolchains/local-linux
source /workspace/.toolchains/local-linux/env.sh
```

Verified probes: clang 19.1.7, CMake 3.31.6, Ninja 1.12.1, GTK 3.24.49, and `javac 21.0.13`. The script records downloaded package SHA-256 values in `packages.json`. It targets Debian 13; other distributions should use their normal development-package installation workflow.

For this cloud instance, `source /workspace/.toolchains/linux-env.sh` additionally loads the previously installed Flutter and Android SDK paths.

## Native integration defect found and fixed

The first successful native build exposed a startup segmentation fault that pure Dart and widget tests had not detected. The Linux storage loader opened system `libsqlite3.so.0` while Flutter had already loaded `libsqlite3_flutter_libs_plugin.so`. A native backtrace showed `sqlite3_initialize` from one library calling `sqlite3_mutex_enter` exported by the other, resulting in a null function-pointer call.

The storage loader now prefers the bundled Flutter SQLite library and uses the system library only as a fallback for standalone Dart execution. A new native build passed, and startup subsequently created the SQLite workspace and rendered the application.

The diagnostic backtrace is retained locally at `artifacts/screenshots/linux-native-backtrace.log`. Generated logs and screenshots are ignored by Git.

## Executed validation

```sh
source /workspace/.toolchains/linux-env.sh
cd apps/joy
flutter build linux --debug
cd ../..
scripts/smoke-linux.sh
```

- Native Linux debug build: **passed**; output is `apps/joy/build/linux/x64/debug/bundle/joy`.
- Native startup and visible first frame under Xvfb: **passed** after the SQLite fix.
- Native Inbox capture: **passed**. Mouse focus, keyboard typing and Enter created exactly one task in the isolated SQLite workspace. The harness waits for focus before sending text.
- Native application restart: **passed**. The same isolated database retained that single task, and the restarted application displayed its title, task number and UTC creation time.
- Wide viewport, 1200 × 820: **rendered and visually inspected**; composer, navigation and header are readable.
- Narrow viewport, 430 × 820: **rendered and visually inspected**; sidebar becomes a menu, composer and header remain readable without overlap.
- Initial screenshots: `artifacts/screenshots/desktop-inbox.png` and `artifacts/screenshots/desktop-narrow-inbox.png`.
- Capture/restart screenshot: `artifacts/screenshots/desktop-capture-restart.png`; the generated test card is visibly present.
- `bash -n scripts/setup-linux.sh scripts/smoke-linux.sh`: **passed**.

The Xvfb smoke script uses Flutter's supported debug engine environment switches to disable Impeller and enable software rendering. This applies to headless validation only; it does not alter application code or production rendering defaults. The process needs the prefix runtime-library path, including `libGLESv2.so.2`, because that library is absent from the system runtime.

The smoke command fails when no visible frame appears within its polling window or the captured frame is black. It uses an isolated temporary data directory and terminates only the application and virtual display it started.

This smoke validates initial native rendering and the capture/save/restart path. It does not validate physical Android gestures or cross-device Wi-Fi. Additional functional storage, UI and peer-transfer checks are recorded separately in [QA_REPORT.md](QA_REPORT.md).
