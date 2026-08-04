#!/usr/bin/env python3
"""Builds `docs/index.html` — the app's GitHub Pages site.

This file is identical in every one of these app repositories. Everything that differs lives in
`Tools/site.json` beside it, so the five sites stay uniform by construction rather than by
somebody remembering to copy a change across.

Run:  python3 Tools/make-site.py

Fonts are served from `docs/fonts/` rather than Google's CDN: a page that phones out on every
visit is a page that can break, and a 116 KB one-time cost is cheaper than the round trip.
"""

import html
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs")
CONFIG = os.path.join(ROOT, "Tools", "site.json")

# --- palette ------------------------------------------------------------------------------------
INK = "#0d0f11"        # hero background
INK_DEEP = "#0a0c0e"   # marquee strip, one step darker so it reads as a seam
PAPER = "#ffffff"
TEXT_BRIGHT = "#f2f5f8"
TEXT_MUTED = "#96a0aa"
TEXT_DIM = "#6b7681"
TEXT_FAINT = "#5f6a75"
LIGHT_HEAD = "#11151a"
LIGHT_BODY = "#545d66"
HAIRLINE = "#e2e0dc"


def esc(value):
    return html.escape(str(value), quote=True)


def luminance(hex_colour):
    """Perceived brightness of a #RRGGBB, 0–1. Decides whether button text is black or white."""
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def shade(hex_colour, factor):
    """Lightens (factor > 1) or darkens (factor < 1) a #RRGGBB, clamped."""
    parts = [int(hex_colour[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{max(0, min(255, round(c * factor))):02X}" for c in parts)


def stylesheet(accent):
    """One stylesheet, no framework. Classes rather than inline styles, so the markup stays legible."""
    on_accent = "#0b0d0f" if luminance(accent) > 0.6 else "#ffffff"
    return f"""
@font-face{{font-family:'IBM Plex Mono';font-style:normal;font-weight:400;font-display:swap;src:url(fonts/ibm-plex-mono-400.woff2) format('woff2')}}
@font-face{{font-family:'IBM Plex Mono';font-style:normal;font-weight:500;font-display:swap;src:url(fonts/ibm-plex-mono-500.woff2) format('woff2')}}
@font-face{{font-family:'IBM Plex Mono';font-style:normal;font-weight:600;font-display:swap;src:url(fonts/ibm-plex-mono-600.woff2) format('woff2')}}
@font-face{{font-family:'Space Grotesk';font-style:normal;font-weight:400;font-display:swap;src:url(fonts/space-grotesk-400.woff2) format('woff2')}}
@font-face{{font-family:'Space Grotesk';font-style:normal;font-weight:500;font-display:swap;src:url(fonts/space-grotesk-500.woff2) format('woff2')}}
@font-face{{font-family:'Space Grotesk';font-style:normal;font-weight:600;font-display:swap;src:url(fonts/space-grotesk-600.woff2) format('woff2')}}
@font-face{{font-family:'Space Grotesk';font-style:normal;font-weight:700;font-display:swap;src:url(fonts/space-grotesk-700.woff2) format('woff2')}}

*{{box-sizing:border-box}}
body{{margin:0;background:{PAPER};font-family:'Space Grotesk',system-ui,-apple-system,sans-serif;
  -webkit-font-smoothing:antialiased}}
a{{color:inherit;text-decoration:none}}
a:hover{{opacity:.75}}
.mono{{font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace}}
.inner{{max-width:1080px;margin:0 auto;padding:0 40px}}

@keyframes marq{{from{{transform:translateX(0)}}to{{transform:translateX(-50%)}}}}
@keyframes float{{0%,100%{{transform:translateY(0)}}50%{{transform:translateY(-10px)}}}}
@keyframes glow{{0%,100%{{opacity:.35}}50%{{opacity:.8}}}}

/* --- hero --- */
.hero{{position:relative;overflow:hidden;background:{INK};padding:26px 0 96px}}
.hero-glow{{position:absolute;inset:-30% -10% auto;height:560px;
  background:radial-gradient(50% 60% at 50% 0%,{accent}47,transparent 70%);opacity:.5}}
.hero-grid{{position:absolute;inset:0;
  background-image:linear-gradient(rgba(255,255,255,.045) 1px,transparent 1px),
    linear-gradient(90deg,rgba(255,255,255,.045) 1px,transparent 1px);
  background-size:46px 46px;
  mask-image:radial-gradient(80% 70% at 50% 20%,#000,transparent);
  -webkit-mask-image:radial-gradient(80% 70% at 50% 20%,#000,transparent)}}
.hero .inner{{position:relative}}
nav{{display:flex;align-items:center;justify-content:space-between;padding-bottom:78px}}
.wordmark{{font-size:17px;font-weight:700;letter-spacing:-.02em;color:{TEXT_BRIGHT}}}
nav .links{{display:flex;gap:26px;font-size:14px;color:{TEXT_MUTED}}}
.hero-body{{display:flex;flex-direction:column;align-items:center;text-align:center;gap:22px}}
.app-icon{{width:104px;height:104px;filter:drop-shadow(0 18px 50px {accent}66)}}
.eyebrow{{font-size:11px;letter-spacing:.18em;text-transform:uppercase;color:{accent}}}
h1{{margin:0;font-size:68px;line-height:1.02;letter-spacing:-.04em;color:{TEXT_BRIGHT};
  max-width:760px;text-wrap:balance}}
.lede{{margin:0;font-size:19px;line-height:1.55;color:{TEXT_MUTED};max-width:560px;
  text-wrap:pretty}}
.cta{{display:flex;gap:12px;padding-top:10px;flex-wrap:wrap;justify-content:center}}
.button{{background:linear-gradient({shade(accent, 1.12)},{shade(accent, .86)});color:{on_accent};
  padding:15px 28px;border-radius:8px;font-size:15px;font-weight:600;
  box-shadow:0 12px 30px -10px {accent}b3}}
.button.ghost{{background:none;border:1px solid rgba(255,255,255,.18);color:#dfe6ec;box-shadow:none}}
.meta{{font-size:11px;color:{TEXT_DIM};letter-spacing:.06em}}

/* --- marquee --- */
.strip{{overflow:hidden;background:{INK_DEEP};padding:13px 0}}
.strip .track{{display:flex;gap:36px;width:max-content;
  font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:#55606b}}

/* --- feature rows --- */
.row{{display:grid;grid-template-columns:1fr 1.1fr;gap:56px;align-items:center;padding:88px 0}}
.row.flip{{grid-template-columns:1.1fr 1fr}}
.row.flip .copy{{order:2}}
.row.flip .art{{order:1}}
.copy{{display:flex;flex-direction:column;gap:15px}}
.copy .step{{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:{accent}}}
.copy h2{{margin:0;font-size:36px;line-height:1.12;letter-spacing:-.03em;color:{LIGHT_HEAD}}}
.copy p{{margin:0;font-size:16px;line-height:1.65;color:{LIGHT_BODY};text-wrap:pretty}}
.art img,.art video{{width:100%;height:auto;display:block;border-radius:12px;
  border:1px solid {HAIRLINE};background:{INK}}}
.art.placeholder{{aspect-ratio:16/10;border-radius:12px;border:1px solid {HAIRLINE};
  background:repeating-linear-gradient(135deg,#eef0f2,#eef0f2 8px,#f6f7f8 8px,#f6f7f8 16px);
  display:flex;align-items:center;justify-content:center;font-size:12px;color:#99a1a9}}

/* --- capability grid --- */
.band{{background:#f7f8f9;border-top:1px solid {HAIRLINE};border-bottom:1px solid {HAIRLINE};
  padding:78px 0}}
.band .head{{text-align:center;margin-bottom:38px}}
.band .head h2{{margin:6px 0 0;font-size:34px;letter-spacing:-.03em;color:{LIGHT_HEAD}}}
.band .head .step{{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:{accent}}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fill,minmax(184px,1fr));gap:12px}}
.tile{{background:#fff;border:1px solid {HAIRLINE};border-radius:10px;padding:16px 18px}}
.tile .t{{font-size:14px;font-weight:600;color:{LIGHT_HEAD}}}
.tile .s{{font-size:12px;color:#8a939c;margin-top:3px}}

/* --- install --- */
.install{{padding:82px 0}}
.install .head{{text-align:center;margin-bottom:30px}}
.install .head h2{{margin:6px 0 0;font-size:34px;letter-spacing:-.03em;color:{LIGHT_HEAD}}}
.install .head .step{{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:{accent}}}
pre{{margin:0 auto;max-width:640px;background:{INK};color:#dfe6ec;border-radius:12px;
  padding:22px 24px;font-size:13.5px;line-height:1.8;overflow-x:auto}}
pre .p{{color:{accent}}}
.note{{max-width:640px;margin:18px auto 0;text-align:center;font-size:13px;color:#8a939c}}

/* --- footer --- */
footer{{background:{INK};padding:56px 0 40px}}
footer .label{{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:{TEXT_FAINT};
  margin-bottom:18px}}
.shelf{{display:flex;flex-direction:column;font-size:14px}}
.shelf a,.shelf .self{{display:grid;grid-template-columns:26px 130px 1fr 90px;gap:16px;
  align-items:center;padding:14px 0;border-top:1px solid rgba(255,255,255,.1)}}
.shelf .last{{border-bottom:1px solid rgba(255,255,255,.1)}}
.shelf img{{width:24px;height:24px;border-radius:6px;display:block}}
.shelf .n{{font-weight:600;color:#eef2f6}}
.shelf .d{{color:#8b959f}}
.shelf .v{{color:{TEXT_FAINT};text-align:right}}
.shelf .self{{opacity:.45}}
.colophon{{display:flex;justify-content:space-between;align-items:center;margin-top:26px;
  font-size:11px;color:{TEXT_FAINT};gap:16px;flex-wrap:wrap}}

@media (max-width:820px){{
  .inner{{padding:0 24px}}
  h1{{font-size:44px}}
  .row,.row.flip{{grid-template-columns:1fr;gap:28px;padding:56px 0}}
  .row.flip .copy,.row.flip .art{{order:initial}}
  nav{{padding-bottom:48px}}
  nav .links{{gap:16px;font-size:13px}}
  .shelf a,.shelf .self{{grid-template-columns:26px 1fr auto;gap:12px}}
  .shelf .d{{display:none}}
}}
/* Motion is decorative only — nothing here is what makes content visible.
   The template faded the hero copy in with `animation: rise ... both`, which means the words only
   exist once the animation has run. Anything that does not run it renders a hero with no words in
   it: a reduced-motion preference, a headless renderer, a browser that throttles background tabs.
   A staggered fade is not worth a page that can come up empty, so the copy is simply drawn. */
@media (prefers-reduced-motion:no-preference){{
  .app-icon{{animation:float 5s ease-in-out infinite}}
  .hero-glow{{animation:glow 6s ease-in-out infinite}}
  .strip .track{{animation:marq 26s linear infinite}}
}}
"""


def hero(app):
    links = "".join(
        f'<a href="{esc(link["href"])}">{esc(link["label"])}</a>' for link in app["nav"])
    buttons = "".join(
        f'<a class="button{"" if i == 0 else " ghost"}" href="{esc(b["href"])}">{esc(b["label"])}</a>'
        for i, b in enumerate(app["cta"]))
    headline = "<br>".join(esc(line) for line in app["headline"])
    return f"""<header class="hero">
  <div class="hero-glow"></div>
  <div class="hero-grid"></div>
  <div class="inner">
    <nav>
      <span class="wordmark">{esc(app['display'])}</span>
      <div class="links mono">{links}</div>
    </nav>
    <div class="hero-body">
      <img class="app-icon" src="icon.png" alt="{esc(app['display'])} icon" width="104" height="104">
      <div class="eyebrow mono">{esc(app['tagline'])}</div>
      <h1>{headline}</h1>
      <p class="lede">{esc(app['lede'])}</p>
      <div class="cta">{buttons}</div>
      <div class="meta mono">{esc(app['meta'])}</div>
    </div>
  </div>
</header>"""


def marquee(app):
    items = app.get("marquee") or []
    if not items:
        return ""
    # Doubled, because the keyframe translates by exactly half the track for a seamless loop.
    run = "".join(f"<span>{esc(i)}</span>" for i in items * 2)
    return f'<div class="strip"><div class="track mono">{run}</div></div>'


def features(app):
    rows = []
    for i, feature in enumerate(app["features"]):
        shot = feature.get("shot")
        if shot and os.path.exists(os.path.join(OUT, shot)):
            if shot.lower().endswith((".mp4", ".webm", ".mov")):
                # A poster matters: without one the row is a black rectangle until metadata loads,
                # and `preload="metadata"` is not a promise about the first frame. Any sibling
                # image with the same stem is used. No autoplay — motion on this page is
                # decorative and gated behind prefers-reduced-motion, and a video is not
                # decorative.
                stem = os.path.splitext(shot)[0]
                poster = next((f"{stem}{ext}" for ext in (".jpg", ".png")
                               if os.path.exists(os.path.join(OUT, f"{stem}{ext}"))), None)
                attrs = f' poster="{esc(poster)}"' if poster else ""
                art = (f'<div class="art"><video src="{esc(shot)}"{attrs} controls muted loop '
                       f'playsinline preload="metadata"></video></div>')
            else:
                art = f'<div class="art"><img src="{esc(shot)}" alt="" loading="lazy"></div>'
        else:
            art = '<div class="art placeholder mono">screenshot</div>'
        copy = (f'<div class="copy"><div class="step mono">{esc(feature["step"])}</div>'
                f'<h2>{esc(feature["title"])}</h2><p>{esc(feature["body"])}</p></div>')
        flip = " flip" if i % 2 else ""
        body = (art + copy) if i % 2 else (copy + art)
        rows.append(f'<div class="row{flip}">{body}</div>')
    return f'<section id="features"><div class="inner">{"".join(rows)}</div></section>'


def capabilities(app):
    block = app.get("capabilities")
    if not block or not block.get("items"):
        return ""
    tiles = "".join(
        f'<div class="tile"><div class="t">{esc(i["name"])}</div>'
        f'<div class="s mono">{esc(i.get("sub", ""))}</div></div>'
        for i in block["items"])
    return f"""<section class="band" id="capabilities"><div class="inner">
  <div class="head"><div class="step mono">{esc(block['step'])}</div><h2>{esc(block['title'])}</h2></div>
  <div class="tiles">{tiles}</div>
</div></section>"""


def install(app):
    block = app.get("install")
    if not block:
        return ""
    lines = "\n".join(
        f'<span class="p">$</span> {esc(line)}' if not line.startswith("#") else
        f'<span style="color:#6b7681">{esc(line)}</span>'
        for line in block["commands"])
    note = f'<p class="note">{esc(block["note"])}</p>' if block.get("note") else ""
    return f"""<section class="install" id="install"><div class="inner">
  <div class="head"><div class="step mono">{esc(block['step'])}</div><h2>{esc(block['title'])}</h2></div>
  <pre class="mono">{lines}</pre>{note}
</div></section>"""


def shelf(app, siblings):
    """The other apps. Present on every site, in the same order, so the set reads as a set."""
    rows = []
    for i, other in enumerate(siblings):
        last = " last" if i == len(siblings) - 1 else ""
        icon = f'<img src="apps/{esc(other["slug"])}.png" alt="">'
        cells = (f'{icon}<span class="n">{esc(other["name"])}</span>'
                 f'<span class="d">{esc(other["blurb"])}</span>'
                 f'<span class="v mono">{esc(other["version"])}</span>')
        if other["slug"] == app["slug"]:
            rows.append(f'<div class="self{last}">{cells}</div>')
        else:
            rows.append(f'<a class="{last.strip() or ""}" href="{esc(other["url"])}">{cells}</a>')
    return f"""<footer><div class="inner">
  <div class="label mono">The rest of the shelf</div>
  <div class="shelf mono">{"".join(rows)}</div>
  <div class="colophon mono">
    <span>{esc(app['colophon'])}</span>
    <a href="https://github.com/smrazar">github.com/smrazar &#8599;</a>
  </div>
</div></footer>"""


def build():
    with open(CONFIG) as handle:
        config = json.load(handle)
    app, siblings = config["app"], config["shelf"]

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(app['display'])} — {esc(app['summary'])}</title>
<meta name="description" content="{esc(app['lede'])}">
<meta property="og:title" content="{esc(app['display'])}">
<meta property="og:description" content="{esc(app['lede'])}">
<meta property="og:image" content="icon.png">
<meta name="theme-color" content="{esc(app['accent'])}">
<link rel="icon" href="icon.png">
<style>{stylesheet(app['accent'])}</style>
</head>
<body>
{hero(app)}
{marquee(app)}
{features(app)}
{capabilities(app)}
{install(app)}
{shelf(app, siblings)}
</body>
</html>
"""

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "index.html"), "w") as handle:
        handle.write(page)
    # GitHub Pages runs Jekyll by default, which skips anything beginning with an underscore.
    # Nothing here needs it, and this avoids a build step on their side entirely.
    open(os.path.join(OUT, ".nojekyll"), "w").close()
    print(f"wrote {OUT}/index.html — {len(app['features'])} features, {len(siblings)} apps")


if __name__ == "__main__":
    build()
