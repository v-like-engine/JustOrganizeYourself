# Windows packaging validation

Date: 2026-11-09. Platform: GitHub-hosted `windows-2022`, x64 release build. Flutter version: 3.47.9.

## Executed checks

The [first Windows run](https://github.com/v-like-engine/JustOrganizeYourself/actions/runs/42539623824), source commit `9fccd2814e790ebde2e2b031b2d48205624fd6ba`, completed successfully:

| Check | Result |
| --- | --- |
| Official Flutter SDK SHA-256 and installation | Passed |
| `flutter analyze` | Passed |
| `flutter build windows --release` | Passed |
| Core tests on Windows, using packaged SQLite | 66 passed |
| Flutter tests on Windows | 42 passed, 1 skipped |
| Native portable startup with SDK-free `PATH` | Passed |
| Window visible and SQLite header initialized | Passed |
| Flutter, SQLite and C++ runtime loaded from the package | Passed |
| Per-user installer and installed executable startup | Passed |
| Uninstaller preserves SQLite database and WAL bytes | Passed |

The skipped test needs a running Python model service. It is optional and is not part of the default Windows package; the real-model path was exercised separately in the original development validation.

Downloaded ZIP and installer checksums matched `SHA256SUMS.txt`. Independent inspection of the portable ZIP confirmed AMD64 EXE/Flutter/SQLite/C++ libraries, ICU and AOT assets. No user database, debug PDB files or JVM library are included. Approximate compressed sizes are 14 MiB for the ZIP and 12 MiB for the installer; exact sizes and hashes belong to each release's assets.

## Delivery

The workflow builds on pushes to `main`, relevant pull requests and Windows-preview tags. A tagged run attaches checked artifacts to a **draft** release only after all build, test and packaging checks pass. It refuses to replace an already published release. Publishing the reviewed draft is a separate operation.

The [tagged delivery run](https://github.com/v-like-engine/JustOrganizeYourself/actions/runs/42540354478), commit `f29ca1adc825f3a2d85dd700fd1644d9134c0f1c`, completed successfully: Windows build, 66 core tests, 42 Flutter tests with 1 optional model test skipped, portable startup, installer startup, uninstall retention, artifact upload and draft delivery all passed.

The reviewed [Windows preview release](https://github.com/v-like-engine/JustOrganizeYourself/releases/tag/v0.1.0-windows-preview.1) was then published. Final downloaded artifacts were independently checked against the checksum file and their executable/runtime AMD64 headers were inspected. The installer download returned HTTP 200 without a GitHub CLI login step.

| Asset | Bytes |
| --- | --- |
| `JOY-Windows-Setup.exe` | 12,358,043 |
| `JOY-Windows-Portable.zip` | 14,755,167 |

Publishing the final release metadata worked through the configured GitHub API access. Direct asset upload from the cloud machine was rejected with HTTP 401 by the upload endpoint; standard GitHub Actions repository credentials were used for the draft asset upload instead. No credential was extracted or copied into the package.

## Packaging decisions

- Microsoft C++ redistributable DLLs are copied app-locally from the builder's Visual Studio redist directory. End users do not install compiler tools or a separate runtime.
- Optional JNI discovery is disabled for Windows. The application does not need Java there, and a JDK present on a builder must not introduce `jvm.dll` into the end-user dependencies.
- `CompanyName=dev.justorganize` and `ProductName=joy` remain unchanged, preserving the existing roaming data path. Executable name and visible window title use Just Organize Yourself.
- The installer requests the current user's privileges and writes into Local AppData. There are no installer rules that remove the roaming user database.
- This preview is unsigned. A code-signing certificate is not fabricated or presented as trusted.

The runner has development tools installed, so this is not a test on every clean consumer Windows image. Native startup deliberately excludes SDK/tool directories from the child process's `PATH` and verifies the actual module paths. No claim is made about all Windows devices, macOS, physical Android, or real household Wi-Fi from this run.
