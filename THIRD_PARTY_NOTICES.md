# Third-Party Notices

AndroidDSH itself is MIT-licensed (see [LICENSE](LICENSE)). The APKs published on
the Releases page, however, **bundle third-party software**, and the source tree
builds against it. Those components remain under their own licenses.

Unlike the source repository, a release APK is a combined work that contains the
binaries below. If you redistribute a built APK, keep these notices with it.

| Component | Version bundled | License | Role in the APK |
| --- | --- | --- | --- |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) | 0.2.0-rc.2 | MIT | The agent runtime and its Web frontend — the actual application |
| [Node.js](https://nodejs.org/) | 22.23.3 | MIT | JS runtime; shipped as `libnode.so` |
| [GNU bash](https://www.gnu.org/software/bash/) | 5.2.37 | GPL-3.0-or-later | `tool-bash` executor; shipped as `libbash.so` |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | 15.2.0 | MIT OR Unlicense | Backend for the `glob` / `grep` tools; shipped as `libripgrep.so` |
| [PCRE2](https://www.pcre.org/) | 10.45 | BSD-3-Clause | Statically linked into ripgrep (`--features pcre2`) |
| [CPython](https://www.python.org/) | 3.13.15 | PSF-2.0 | `python3` for the agent; shipped as `libpython3.so` |
| [OpenSSL](https://www.openssl.org/) | 3.0.16 | Apache-2.0 | Statically linked into CPython's `_ssl` |
| [SQLite](https://sqlite.org/) | 3.46.1 | Public Domain | Statically linked into CPython's `_sqlite3` |
| [libffi](https://sourceware.org/libffi/) | — | MIT | Statically linked into CPython's `_ctypes` |
| [xz/liblzma](https://tukaani.org/xz/) | — | Public Domain / LGPL-2.1 | Statically linked into CPython's `_lzma` |
| [bzip2](https://sourceware.org/bzip2/) | — | BSD-like | Statically linked into CPython's `_bz2` |
| [readline](https://tiswww.case.edu/php/chet/readline/rltop.html) | 8.2 | GPL-3.0-or-later | CPython `readline` module |
| [ncurses](https://invisible-island.net/ncurses/) | 6.5 | MIT-like (X11) | readline dependency |
| [Apache Commons Compress](https://commons.apache.org/proper/commons-compress/) | 1.27.1 | Apache-2.0 | Unpacks the runtime `tar.gz` assets on device |
| [AndroidX / Jetpack Compose](https://developer.android.com/jetpack) | per `app/build.gradle.kts` | Apache-2.0 | Android UI layer |
| [pnpm](https://pnpm.io/) | 10.34.6 | MIT | Plugin installation (pure-JS build, bundled as an asset) |
| [npm](https://www.npmjs.com/) | bundled with Node | Artistic-2.0 | `pnpm`'s pass-through subcommands (`view`, `search`, …) |

## Notes

- **GPL components (bash, readline).** These are shipped as separate executables
  that the app spawns as subprocesses, not linked into the app's own code. The
  corresponding source, plus the exact cross-compilation recipes used to produce
  them, is available in this repository (`scripts/build-bash-android.sh`,
  `scripts/build-python-android.sh`). If you distribute an APK, you must comply
  with GPL-3.0 for those binaries — including making the corresponding source
  available.
- **DeepSeek Harness patch set.** `scripts/patch-dsh-android.py` modifies the
  bundled `dsh` packages at build time. Those modifications are documented
  anchor-by-anchor in the script and are released under the same MIT terms as
  upstream.
- Version numbers above track the `0.2.0` release. When bumping an upstream
  component, update this table.
