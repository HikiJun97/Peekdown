# Tests

```bash
tests/run.sh                 # build, then run every suite (exit code 1 on any failure)
tests/run.sh unit core       # pick suites (names below)
```

`run.sh` builds the app with `scripts/build.sh` and the Rust core with `cargo` (a build warning from either counts as a
failure), compiles `harness/main.swift` together with `src/MdairRender.swift`, and writes everything under `build/`.

The app still renders with the Swift code in `src/`, while the shared logic is being moved to Rust in `core/`. Until the
app switches over, each suite runs against both. The Swift suites go away once nothing uses `src/MdairRender.swift`.

| Swift suite | Rust suite | What it checks |
|-------------|------------|----------------|
| `unit` | `core` (`cargo test`) | Renderer output for common syntax, footnotes, mermaid blocks, `<script>` filtering; image path decoding; same-document link detection; linear-time asset path fixing; ZIP limits (oversized, duplicate and `../` entries, truncated files) |
| `spec` | `core-spec` | 1,322 examples from CommonMark 0.31.2 and GFM 0.29 ([`spec/`](spec/)). Fails on any example not listed in `spec/known-failures.txt` (Swift) or `spec/known-failures-core.txt` (Rust) |
| `webkit` | `core-webkit` | Loads pages in a real `WKWebView`: injected scripts and handlers don't run, non-image and symlinked files aren't inlined, external stylesheets are blocked, Mermaid renders, `<meta refresh>` and forms can't navigate away, footnote links scroll. `core-webkit` loads pages made by `core/examples/harness.rs` |
| `converter` | `core-converter` | Runs `peekdown-convert`: TextPack/TextBundle structure, duplicate images, remote images kept as links, relative `-o`; reading TextPacks made by `zip`, streaming `zip`, Finder (`ditto`) and hostile ZIPs; attack documents (hidden secret references, symlinks, `%2F` path traversal, folder outputs) |

The two spec baselines differ because comrak follows CommonMark 0.31.2, which changed a few emphasis rules after the
GFM 0.29 spec was written, and passes 13 CommonMark examples that cmark-gfm gets wrong.

When a renderer change intentionally changes spec results, check the diff and then refresh the list:

```bash
python3 tests/spec/spec.py compare build/tests/spec-cases.json build/tests/core-spec-rendered.json \
    --known tests/spec/known-failures-core.txt --update
```

Not covered: the app's Objective-C code paths (export runs the converter off the main thread and drains its stderr
before waiting) and the QuickLook extension inside Finder — check those by hand.
