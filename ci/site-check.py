#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Checks the website (site/) beyond HTML validity (html-validate does that): every page has a
title, a description, a language and a canonical link; links between pages and to #sections
point at something that exists; nothing the Content-Security-Policy in _headers would block (no
scripts, inline styles, or resources from other sites); _headers keeps that policy.

    site-check.py [site folder]
"""
import html.parser, os, re, sys

SITE = sys.argv[1] if len(sys.argv) > 1 else "site"
problems = []


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.links, self.resources, self.head = set(), [], [], {}
        self.title = ""
        self.in_title = False
        self.inline = []

    def handle_starttag(self, tag, attributes):
        a = dict(attributes)
        if "id" in a:
            self.ids.add(a["id"])
        if "style" in a:
            self.inline.append(f"style attribute on <{tag}>")
        if tag in ("script", "style", "iframe", "object", "embed"):
            self.inline.append(f"<{tag}>")
        if tag == "html":
            self.head["lang"] = a.get("lang")
        if tag == "title":
            self.in_title = True
        if tag == "meta" and a.get("name") == "description":
            self.head["description"] = a.get("content")
        if tag == "link" and a.get("rel") == "canonical":
            self.head["canonical"] = a.get("href")
        if tag == "link" and a.get("rel") == "stylesheet":
            self.resources.append(a.get("href", ""))
        if tag in ("img", "source", "video", "audio") and a.get("src"):
            self.resources.append(a["src"])
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        for key, value in a.items():
            if key.startswith("on"):
                self.inline.append(f"{key} handler on <{tag}>")

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data


def page_file(path):
    """The file a site path is served from (Cloudflare Pages: /setup → setup.html)."""
    path = path.split("#")[0].split("?")[0]
    if path in ("", "/"):
        return "index.html"
    name = path.strip("/")
    return name if name.endswith(".html") else name + ".html"


pages = {}
for name in sorted(os.listdir(SITE)):
    if name.endswith(".html"):
        page = Page()
        page.feed(open(os.path.join(SITE, name), encoding="utf-8").read())
        pages[name] = page

for name, page in pages.items():
    where = f"{SITE}/{name}"
    if not page.title.strip():
        problems.append(f"{where}: no <title>")
    for key in ("lang",) + (() if name == "404.html" else ("description", "canonical")):
        if not page.head.get(key):
            problems.append(f"{where}: no {key}")
    problems += [f"{where}: {item} (the Content-Security-Policy blocks it)" for item in page.inline]
    for resource in page.resources:
        if re.match(r"^(https?:)?//", resource):
            problems.append(f"{where}: {resource} is on another site (the Content-Security-Policy blocks it)")
        elif not os.path.exists(os.path.join(SITE, resource.lstrip("/"))):
            problems.append(f"{where}: {resource} doesn't exist")
    for link in page.links:
        if re.match(r"^[a-z]+:", link):
            continue
        target = name if link.startswith("#") else page_file(link)
        if target not in pages:
            problems.append(f"{where}: link to {link}, but there's no {SITE}/{target}")
            continue
        anchor = link.split("#", 1)[1] if "#" in link else ""
        if anchor and anchor not in pages[target].ids:
            problems.append(f"{where}: link to {link}, but {target} has no id=\"{anchor}\"")

headers = os.path.join(SITE, "_headers")
policy = open(headers).read() if os.path.exists(headers) else ""
if "Content-Security-Policy: default-src 'none'" not in policy:
    problems.append(f"{headers}: the Content-Security-Policy (default-src 'none') is missing")

print("\n".join(problems) or f"{len(pages)} pages: titles, links, anchors and the Content-Security-Policy check out.")
sys.exit(1 if problems else 0)
