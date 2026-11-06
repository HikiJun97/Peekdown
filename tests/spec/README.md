# Spec fixtures

Example data used by `spec.py` to check the renderer against the Markdown specs.

| File | Source | License |
|------|--------|---------|
| `commonmark-0.31.2.json` | https://spec.commonmark.org/0.31.2/spec.json — CommonMark Spec, John MacFarlane | [CC-BY-SA 4.0](http://creativecommons.org/licenses/by-sa/4.0/) |
| `gfm-spec.txt` | https://github.com/github/cmark-gfm/blob/master/test/spec.txt — GitHub Flavored Markdown Spec 0.29 | [CC-BY-SA 4.0](http://creativecommons.org/licenses/by-sa/4.0/) |

Both files are unmodified copies. `known-failures.txt` lists the examples the renderer is expected
to differ on (mostly where the GFM extensions intentionally change the output, as on GitHub).
