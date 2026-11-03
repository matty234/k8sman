#!/usr/bin/env python3
"""Write a Sparkle appcast for one k8sman release and EdDSA-sign it.

    tools/appcast.py --zip dist/k8sman-0.1.1-macos.zip --version 0.1.1 \\
        --download-url https://github.com/matty234/k8sman/releases/download/v0.1.1/k8sman-0.1.1-macos.zip \\
        --sparkle-bin build/sparkle/bin --out dist/appcast.xml [--notes notes.md]

The feed holds only the newest release: Sparkle needs nothing else, and the
app's feed URL (releases/latest/download/appcast.xml) always points at the
newest release's copy. The archive signature (sparkle:edSignature) and the
feed signature (SURequireSignedFeed) both come from Sparkle's `sign_update`.

The private EdDSA key is read, in order, from --ed-key-file, from the
SPARKLE_PRIVATE_ED_KEY environment variable (piped to sign_update on stdin, so
it never touches disk or argv), or from the login keychain (`generate_keys`).
"""

import argparse
import email.utils
import html
import os
import re
import subprocess
import sys
import time
from xml.sax.saxutils import escape, quoteattr


def sign(sparkle_bin, path, key_file, *extra):
    cmd = [os.path.join(sparkle_bin, "sign_update"), *extra]
    stdin = None
    if key_file:
        cmd += ["--ed-key-file", key_file]
    elif os.environ.get("SPARKLE_PRIVATE_ED_KEY"):
        cmd += ["--ed-key-file", "-"]
        stdin = os.environ["SPARKLE_PRIVATE_ED_KEY"].strip() + "\n"
    cmd.append(path)
    res = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"sign_update failed for {path}: {res.stderr.strip() or res.stdout.strip()}")
    return res.stdout.strip()


def notes_html(text):
    """Very small Markdown subset (headings, bullets, paragraphs) to HTML."""
    out, items, para = [], [], []

    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
            items.clear()
        if para:
            out.append("<p>" + " ".join(para) + "</p>")
            para.clear()

    def inline(s):
        s = html.escape(s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
        return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)

    for line in text.splitlines():
        s = line.strip()
        if not s:
            flush()
        elif s.startswith("#"):
            flush()
            out.append(f"<h3>{inline(s.lstrip('#').strip())}</h3>")
        elif s[:2] in ("- ", "* "):
            if para:
                flush()
            items.append(inline(s[2:]))
        else:
            if items:
                flush()
            para.append(inline(s))
    flush()
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--zip", required=True)
    p.add_argument("--version", required=True, help="CFBundleShortVersionString (= CFBundleVersion)")
    p.add_argument("--build", help="CFBundleVersion, if it differs from --version")
    p.add_argument("--download-url", required=True)
    p.add_argument("--release-url", help="Release page (full release notes link)")
    p.add_argument("--notes", help="Markdown or text release notes to embed")
    p.add_argument("--minimum-system-version", default="12.0")
    p.add_argument("--sparkle-bin", required=True)
    p.add_argument("--ed-key-file")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    # 'sparkle:edSignature="…" length="…"'
    enclosure_sig = sign(a.sparkle_bin, a.zip, a.ed_key_file)
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+(?:sparkle:)?length="(\d+)"', enclosure_sig)
    if not m:
        sys.exit(f"unexpected sign_update output: {enclosure_sig}")
    signature, length = m.group(1), m.group(2)

    body = ""
    if a.notes and os.path.exists(a.notes):
        with open(a.notes, encoding="utf-8") as f:
            body = notes_html(f.read())
    if a.release_url:
        body += f'\n<p><a href="{html.escape(a.release_url)}">Full release notes on GitHub</a></p>'
    body = body.strip() or f"<p>k8sman {html.escape(a.version)}</p>"

    build = a.build or a.version
    links = ""
    if a.release_url:
        links = (f"      <link>{escape(a.release_url)}</link>\n"
                 f"      <sparkle:fullReleaseNotesLink>{escape(a.release_url)}</sparkle:fullReleaseNotesLink>\n")
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>k8sman</title>
    <link>https://github.com/matty234/k8sman</link>
    <description>k8sman updates</description>
    <language>en</language>
    <item>
      <title>Version {escape(a.version)}</title>
      <pubDate>{email.utils.formatdate(time.time(), usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.minimum_system_version)}</sparkle:minimumSystemVersion>
{links}      <description><![CDATA[{body.replace(']]>', ']]&gt;')}]]></description>
      <enclosure url={quoteattr(a.download_url)} length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(xml)
    # Embeds the feed signature (checked because of SURequireSignedFeed).
    sign(a.sparkle_bin, a.out, a.ed_key_file, "--disable-signing-warning")
    print(a.out)


if __name__ == "__main__":
    main()
