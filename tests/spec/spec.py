#!/usr/bin/env python3
"""마크다운 스펙 예제로 렌더러를 검사한다.

  spec.py cases <cases.json>
      스펙 데이터에서 예제를 모은다. 묶음은 둘이다.
        commonmark  CommonMark 0.31.2 (commonmark-0.31.2.json)
        gfm         GitHub Flavored Markdown 0.29, cmark-gfm이 따르는 스펙 (gfm-spec.txt)
  spec.py compare <cases.json> <rendered.json> [--update]
      렌더 결과를 기대 HTML과 정규화해 비교한다. known-failures.txt에 없는 실패가 있으면 종료 코드 1.
      --update 는 지금 실패 목록으로 known-failures.txt를 다시 쓴다(의도한 변화를 확인한 뒤에만).

비교는 공식 테스트 도구처럼 공백·속성 순서·따옴표 차이를 무시하고, mdair가 img에 붙이는 style은 뺀다.
"""
import json
import os
import re
import sys
from html import escape
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
KNOWN = os.path.join(HERE, "known-failures.txt")
BLOCK = {"p", "ul", "ol", "li", "blockquote", "pre", "table", "thead", "tbody", "tr", "th", "td",
         "h1", "h2", "h3", "h4", "h5", "h6", "hr", "div", "section"}


def make_cases():
    cases = [{"suite": "commonmark", "section": c["section"], "example": c["example"],
              "markdown": c["markdown"], "html": c["html"]}
             for c in json.load(open(os.path.join(HERE, "commonmark-0.31.2.json"), encoding="utf-8"))]
    fence = "`" * 32
    section, n = "", 0
    lines = open(os.path.join(HERE, "gfm-spec.txt"), encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r"^#{1,6} (.*)", lines[i])
        if m:
            section = m.group(1).strip()
        if lines[i].startswith(fence + " example"):
            n += 1
            tag = lines[i][len(fence) + len(" example"):].strip()
            md, html = [], []
            part = md
            i += 1
            while not lines[i].startswith(fence):
                if lines[i] == ".":
                    part = html
                else:
                    part.append(lines[i])
                i += 1
            if tag != "disabled":
                cases.append({"suite": "gfm", "section": section, "example": n,
                              "markdown": "\n".join(md).replace("→", "\t") + "\n",
                              "html": "\n".join(html).replace("→", "\t") + ("\n" if html else "")})
        i += 1
    return cases


class Norm(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.in_pre = [], 0

    def attrs(self, tag, attrs):
        return "".join(f' {k}="{escape(v or "", quote=True)}"' for k, v in sorted(attrs)
                       if not (tag == "img" and k == "style"))

    def handle_starttag(self, tag, attrs):
        if tag == "pre":
            self.in_pre += 1
        self.out.append(f"<{tag}{self.attrs(tag, attrs)}>")

    def handle_startendtag(self, tag, attrs):
        self.out.append(f"<{tag}{self.attrs(tag, attrs)}>")

    def handle_endtag(self, tag):
        if tag == "pre":
            self.in_pre -= 1
        self.out.append(f"</{tag}>")

    def handle_data(self, data):
        self.out.append(escape(data if self.in_pre else re.sub(r"\s+", " ", data), quote=False))

    def handle_comment(self, data):
        self.out.append(f"<!--{data}-->")


def norm(html):
    p = Norm()
    p.feed(html)
    p.close()
    s = "".join(p.out)
    return re.sub(r"\s*(</?(?:%s)\b[^>]*>)\s*" % "|".join(BLOCK), r"\1", s).strip()


def compare(cases_path, rendered_path, update):
    cases = json.load(open(cases_path, encoding="utf-8"))
    rendered = json.load(open(rendered_path, encoding="utf-8"))
    assert len(cases) == len(rendered), "cases와 렌더 결과 개수가 다르다"
    failing = {f'{c["suite"]} #{c["example"]}': c for c, r in zip(cases, rendered) if norm(c["html"]) != norm(r)}
    for suite in ("commonmark", "gfm"):
        total = sum(c["suite"] == suite for c in cases)
        bad = sum(k.startswith(suite + " ") for k in failing)
        print(f"  {suite}: {total - bad}/{total} 통과")

    if update:
        with open(KNOWN, "w", encoding="utf-8") as f:
            f.write("# 렌더러가 스펙과 다르게 내는 예제. 확장(tagfilter, autolink)을 켜서 GitHub과 같게 동작하는 경우,\n")
            f.write("# GFM 스펙(0.29) 이후 CommonMark 0.31.2에서 바뀐 규칙을 따르는 경우 등.\n")
            f.write("# tests/spec/spec.py compare … --update 로 다시 만든다.\n")
            for key in sorted(failing, key=lambda k: (k.split()[0], int(k.split("#")[1]))):
                f.write(f'{key}\t{failing[key]["section"]}\n')
        print(f"  known-failures.txt 갱신: {len(failing)}개")
        return 0

    known = {line.split("\t")[0] for line in open(KNOWN, encoding="utf-8") if line.strip() and not line.startswith("#")}
    new = sorted(set(failing) - known)
    fixed = sorted(known - set(failing))
    for key in new:
        c = failing[key]
        print(f"  새로 실패: {key} ({c['section']})\n    입력: {c['markdown']!r}\n    기대: {c['html']!r}")
    if fixed:
        print(f"  새로 통과(known-failures.txt에서 지워도 됨): {', '.join(fixed)}")
    return 1 if new else 0


if __name__ == "__main__":
    if sys.argv[1] == "cases":
        cases = make_cases()
        json.dump(cases, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
        print(f"  예제 {len(cases)}개")
    elif sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3], "--update" in sys.argv))
    else:
        sys.exit(__doc__)
