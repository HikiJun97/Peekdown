# cmark-gfm (vendored)

- Upstream: https://github.com/github/cmark-gfm
- Version: `0.29.0.gfm.13` (commit `587a12bb54`)
- License: see [`COPYING`](COPYING) (BSD-2-Clause and others)

Copied as-is from the release tag, except:

- Omitted because the build doesn't use them: `src/main.c` (command-line tool), the re2c sources (`*.re`),
  and the CMake files (`CMakeLists.txt`, `config.h.in`, `cmark-gfm_version.h.in`, `libcmark-gfm.pc.in`).
- `src/config.h`, `src/cmark-gfm_version.h` and `src/cmark-gfm_export.h` were generated once with
  `cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMARK_SHARED=OFF -DCMARK_TESTS=OFF` so the build needs no CMake.
- `module.modulemap` and this README were added for Peekdown.
