# Tests

```bash
tests/run.sh                 # build, then run every suite (exit code 1 on any failure)
tests/run.sh unit spec       # pick suites: unit, spec, webkit, converter
```

`run.sh` builds the app with `scripts/build.sh` (which builds the Rust core in `core/`), the Rust test harness
(`core/examples/harness.rs`) and the WebKit harness (`harness/main.swift` with `src/CoreBridge.swift`), and writes
everything under `build/`. A build warning from any of them counts as a failure.

| Suite | What it checks |
|-------|----------------|
| `unit` | `cargo test` in `core/`: renderer output for common syntax, footnotes, mermaid blocks, raw HTML filtering (`<script>`, `<style/x>`, tags hidden in comments); image path decoding; only Markdown images are inlined, and an `<img src>` hidden inside another attribute is left alone; same-document link detection; linear-time asset path fixing; ZIP limits (oversized, duplicate and `../` entries, truncated files) |
| `spec` | 1,322 examples from CommonMark 0.31.2 and GFM 0.29 ([`spec/`](spec/)). Fails on any example not listed in `spec/known-failures.txt` |
| `webkit` | Loads pages in a real `WKWebView`, made through the same C interface the app uses: injected scripts and handlers don't run, non-image and symlinked files aren't inlined, raw HTML `<img>` isn't inlined, a local image can't be smuggled into a remote URL, external stylesheets are blocked, Mermaid renders, `<meta refresh>` and forms can't navigate away, footnote links scroll; the QuickLook body/notice path and TextBundle pages |
| `converter` | Runs the app's `peekdown-convert`: TextPack/TextBundle structure, duplicate images, remote images kept as links, relative `-o`; reading TextPacks made by `zip`, streaming `zip`, Finder (`ditto`) and hostile ZIPs; attack documents (hidden secret references, symlinks, `%2F` path traversal, folder outputs); only images visible in the document are packed (not ones in HTML comments or code); images in lists, quotes, tables and reference links are rewritten; names that differ only in Unicode normalization don't collide |

`known-failures.txt` lists the examples where the output intentionally differs from the spec: the tagfilter and
autolink extensions (same as GitHub), and nested strong emphasis, where comrak follows CommonMark 0.31.2 rules that
changed after the GFM 0.29 spec was written.

When a renderer change intentionally changes spec results, check the diff and then refresh the list:

```bash
python3 tests/spec/spec.py compare build/tests/spec-cases.json build/tests/spec-rendered.json --update
```

Not covered: the app's Objective-C code paths (export runs the converter off the main thread and drains its stderr
before waiting) and the QuickLook extension inside Finder — check those by hand.
