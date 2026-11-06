# Tests

```bash
tests/run.sh                 # build, then run every suite (exit code 1 on any failure)
tests/run.sh unit spec       # pick suites: unit, spec, webkit, converter
```

`run.sh` builds the app with `scripts/build.sh` (a build warning also counts as a failure), compiles
`harness/main.swift` together with `src/MdairRender.swift`, and writes everything under `build/tests/`.

| Suite | What it checks |
|-------|----------------|
| `unit` | Renderer output for common syntax, footnotes, mermaid blocks, `<script>` filtering; image path decoding; same-document link detection; linear-time asset path fixing; ZIP limits (oversized, duplicate and `../` entries, truncated files) |
| `spec` | 1,322 examples from CommonMark 0.31.2 and GFM 0.29 ([`spec/`](spec/)). Fails on any example not listed in `spec/known-failures.txt` |
| `webkit` | Loads pages in a real `WKWebView`: injected scripts and handlers don't run, non-image and symlinked files aren't inlined, external stylesheets are blocked, Mermaid renders, `<meta refresh>` and forms can't navigate away, footnote links scroll |
| `converter` | Runs `peekdown-convert`: TextPack/TextBundle structure, duplicate images, remote images kept as links, relative `-o`; reading TextPacks made by `zip`, streaming `zip`, Finder (`ditto`) and hostile ZIPs; attack documents (hidden secret references, symlinks, `%2F` path traversal, folder outputs) |

When a renderer change intentionally changes spec results, check the diff and then refresh the list:

```bash
python3 tests/spec/spec.py compare build/tests/spec-cases.json build/tests/spec-rendered.json --update
```

Not covered: the app's Objective-C code paths (export runs the converter off the main thread and drains
its stderr before waiting) and the QuickLook extension inside Finder — check those by hand.
