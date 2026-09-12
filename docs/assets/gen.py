#!/usr/bin/env python3
"""Generate the README visual system for t1-revive. Run from this directory."""
from pathlib import Path

OUT = Path(__file__).resolve().parent

SANS = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'JetBrains Mono', Menlo, Consolas, monospace"

DEFS = r"""
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#07091a"/>
    <stop offset="0.55" stop-color="#101338"/>
    <stop offset="1" stop-color="#1a1248"/>
  </linearGradient>
  <linearGradient id="spectrum" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#ff5d73"/>
    <stop offset="0.22" stop-color="#ffc46b"/>
    <stop offset="0.48" stop-color="#3ee8a8"/>
    <stop offset="0.74" stop-color="#3ecbff"/>
    <stop offset="1" stop-color="#8b7cff"/>
  </linearGradient>
  <linearGradient id="title" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#ffffff"/>
    <stop offset="1" stop-color="#c5cdff"/>
  </linearGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.10"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0.03"/>
  </linearGradient>
  <radialGradient id="orbV" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#8b7cff" stop-opacity="0.55"/>
    <stop offset="1" stop-color="#8b7cff" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="orbC" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#3ecbff" stop-opacity="0.40"/>
    <stop offset="1" stop-color="#3ecbff" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="orbM" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#3ee8a8" stop-opacity="0.45"/>
    <stop offset="1" stop-color="#3ee8a8" stop-opacity="0"/>
  </radialGradient>
  <filter id="glow" x="-20%" y="-200%" width="140%" height="500%">
    <feGaussianBlur stdDeviation="14"/>
  </filter>
  <filter id="soft" x="-50%" y="-50%" width="200%" height="200%">
    <feGaussianBlur stdDeviation="40"/>
  </filter>
  <filter id="tinyglow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur stdDeviation="6"/>
  </filter>
"""


def fingerprint(cx, cy, r=11, color="#3ee8a8", sw=1.5):
    def n(x):
        return f"{float(x):.2f}"
    return f'''<g transform="translate({cx} {cy})" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round">
      <path d="M 0 -{n(r*0.15)} v {n(r*0.55)}"/>
      <path d="M -{n(r*0.55)} {n(r*0.15)} A {n(r*0.55)} {n(r*0.55)} 0 0 1 {n(r*0.55)} {n(r*0.15)}"/>
      <path d="M -{n(r*0.85)} {n(r*0.05)} A {n(r*0.85)} {n(r*0.85)} 0 0 1 {n(r*0.85)} {n(r*0.05)}"/>
      <path d="M -{n(r*0.32)} {n(r*0.28)} A {n(r*0.32)} {n(r*0.32)} 0 0 1 {n(r*0.32)} {n(r*0.28)}"/>
      <path d="M -{n(r*0.70)} -{n(r*0.22)} A {n(r*0.72)} {n(r*0.72)} 0 0 1 {n(r*0.18)} -{n(r*0.78)}"/>
    </g>'''


def pill(x, y, w, h, text, fill="#ffffff", fill_op="0.07", stroke_op="0.14", text_fill="#dfe5ff", size=14):
    return f'''<g transform="translate({x} {y})">
      <rect width="{w}" height="{h}" rx="{h/2}" fill="{fill}" fill-opacity="{fill_op}" stroke="#ffffff" stroke-opacity="{stroke_op}"/>
      <text x="{w/2}" y="{h*0.68}" text-anchor="middle" font-family="{SANS}" font-size="{size}" font-weight="600" fill="{text_fill}">{text}</text>
    </g>'''


def write(name, svg):
    path = OUT / name
    path.write_text(svg.strip() + "\n", encoding="utf-8")
    print(f"wrote {path.name} ({path.stat().st_size} bytes)")


# --------------------------------------------------------------------------- hero
hero = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="340" viewBox="0 0 1280 340" role="img" aria-label="t1-revive: Touch Bar, camera and Touch ID back on a 2016 or 2017 MacBook Pro, from Linux alone">
  <defs>
    {DEFS}
    <pattern id="dots" width="28" height="28" patternUnits="userSpaceOnUse">
      <circle cx="1.2" cy="1.2" r="1.2" fill="#ffffff" opacity="0.045"/>
    </pattern>
  </defs>

  <rect width="1280" height="340" rx="32" fill="url(#bg)"/>
  <rect width="1280" height="340" rx="32" fill="url(#dots)"/>
  <circle cx="1120" cy="40" r="220" fill="url(#orbV)" filter="url(#soft)"/>
  <circle cx="180" cy="400" r="200" fill="url(#orbC)" filter="url(#soft)"/>
  <circle cx="720" cy="20" r="140" fill="url(#orbM)" opacity="0.7" filter="url(#soft)"/>

  <!-- mark -->
  <g transform="translate(72 56)">
    <rect width="54" height="54" rx="16" fill="#0c1024" stroke="#ffffff" stroke-opacity="0.12"/>
    <rect x="7" y="22" width="26" height="10" rx="5" fill="url(#spectrum)"/>
    <circle cx="41" cy="27" r="7" fill="#071018" stroke="#3ee8a8" stroke-width="1.4"/>
    {fingerprint(41, 27, 5, "#3ee8a8", 1.15)}
  </g>

  <text x="144" y="94" font-family="{SANS}" font-size="22" font-weight="700" letter-spacing="6" fill="#8b93c2">LINUX · APPLE T1</text>

  <text x="72" y="178" font-family="{SANS}" font-size="86" font-weight="800" letter-spacing="-3.5" fill="url(#title)">t1-revive</text>
  <text x="74" y="228" font-family="{SANS}" font-size="22" fill="#b7c0e6">Touch Bar, camera and Touch ID. Back from Linux. This chip’s own data.</text>

  {pill(72, 258, 268, 36, "MacBookPro 13,2 · 13,3 · 14,2 · 14,3", size=13)}
  {pill(352, 258, 168, 36, "no macOS install", size=13)}
  {pill(532, 258, 156, 36, "no other Mac", size=13)}
  {pill(700, 258, 150, 36, "~5 minutes", "#3ee8a8", "0.12", "0.35", "#3ee8a8", 13)}

  <!-- stats -->
  <g transform="translate(980 130)" font-family="{SANS}">
    <text x="0" y="0" font-size="36" font-weight="800" fill="#f3f5ff">4 min 8 s</text>
    <text x="0" y="26" font-size="14" fill="#8b93c2">wiped ESP → booted T1</text>
    <text x="0" y="84" font-size="36" font-weight="800" fill="#3ee8a8">0 reboots</text>
    <text x="0" y="110" font-size="14" fill="#8b93c2">one sitting · on mains power</text>
  </g>

  <rect x="0" y="332" width="1280" height="8" fill="url(#spectrum)"/>
</svg>'''
write("hero.svg", hero)


# --------------------------------------------------------------------------- features
def card(x, accent, icon, title, sub):
    return f'''<g transform="translate({x} 0)">
    {icon}
    <text x="32" y="168" font-family="{SANS}" font-size="26" font-weight="800" fill="#f3f5ff">{title}</text>
    <text x="32" y="202" font-family="{SANS}" font-size="15" fill="#9aa3c7">{sub}</text>
  </g>'''


icon_bar = '''<g transform="translate(32 70)">
    <rect width="150" height="48" rx="12" fill="#05060d" stroke="#ffffff" stroke-opacity="0.12"/>
    <rect x="16" y="18" width="118" height="12" rx="6" fill="#3ee8a8" fill-opacity="0.35"/>
  </g>'''

icon_cam = '''<g transform="translate(32 62)">
    <circle cx="36" cy="36" r="32" fill="#071018" stroke="#3ecbff" stroke-width="3"/>
    <circle cx="36" cy="36" r="18" fill="#102036" stroke="#7dd8ff" stroke-width="2"/>
    <circle cx="36" cy="36" r="8" fill="#3ecbff" opacity="0.85"/>
    <circle cx="28" cy="26" r="4" fill="#ffffff" opacity="0.35"/>
  </g>'''

icon_id = f'''<g transform="translate(68 98)">
    <circle r="34" fill="#3ee8a8" opacity="0.12"/>
    <circle r="26" fill="#071018" stroke="#3ee8a8" stroke-width="2"/>
    {fingerprint(0, 0, 14, "#3ee8a8", 1.7)}
  </g>'''

features = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="248" viewBox="0 0 1280 248" role="img" aria-label="What comes back: the Touch Bar, the camera, and Touch ID">
  <defs>{DEFS}</defs>
  <rect width="1280" height="248" rx="28" fill="#0c1024" stroke="#ffffff" stroke-opacity="0.10"/>
  {card(8, "#ff5d73", icon_bar, "Touch Bar", "The strip lights. t1bridge drives it.")}
  <line x1="427" y1="28" x2="427" y2="220" stroke="#ffffff" stroke-opacity="0.08"/>
  {card(436, "#3ecbff", icon_cam, "Camera", "The T1’s FaceTime HD is a camera again.")}
  <line x1="855" y1="28" x2="855" y2="220" stroke="#ffffff" stroke-opacity="0.08"/>
  {card(864, "#3ee8a8", icon_id, "Touch ID", "The Secure Enclave does the matching.")}
</svg>'''
write("features.svg", features)


# --------------------------------------------------------------------------- flow
def step(x, n, label, fill, w=148):
    return f'''<g transform="translate({x} 0)">
      <rect width="{w}" height="64" rx="16" fill="{fill}"/>
      <text x="18" y="28" font-family="{MONO}" font-size="11" fill="#081018" fill-opacity="0.55">{n}</text>
      <text x="18" y="48" font-family="{SANS}" font-size="16" font-weight="800" fill="#081018">{label}</text>
    </g>'''


def arrow(x):
    return f'''<path d="M {x} 32 h 16" stroke="#c5cdff" stroke-opacity="0.45" stroke-width="2" stroke-linecap="round"/>'''


flow = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="120" viewBox="0 0 1280 120" role="img" aria-label="provision, reset, personalize, reset, boot, stage, handover">
  <defs>{DEFS}</defs>
  <rect width="1280" height="120" rx="24" fill="#0c1024" stroke="#ffffff" stroke-opacity="0.10"/>
  <g transform="translate(20 28)">
    {step(0, "1", "provision", "#fb923c")}
    {arrow(154)}
    {step(176, "2", "reset", "#38bdf8", 110)}
    {arrow(292)}
    {step(314, "3", "personalize", "#fb923c", 168)}
    {arrow(488)}
    {step(510, "4", "reset", "#38bdf8", 110)}
    {arrow(626)}
    {step(648, "5", "boot", "#38bdf8", 110)}
    {arrow(764)}
    {step(786, "6", "stage", "#4ade80", 118)}
    {arrow(910)}
    {step(932, "7", "handover", "#c084fc", 148)}
  </g>
  <text x="640" y="110" text-anchor="middle" font-family="{SANS}" font-size="12" fill="#7b84a8">orange talks to Apple  ·  blue touches the T1  ·  green writes the ESP  ·  violet hands off to t1bridge</text>
</svg>'''
write("flow.svg", flow)


# --------------------------------------------------------------------------- terminal
# 24px line height, start y=86
rows = [
    ("cmd",  "$ sudo t1-revive regenerate"),
    ("blank", ""),
    ("head", "====  preflight"),
    ("note", "   model: MacBookPro14,3 (tested)"),
    ("note", "   firmware bundle OK · patched tools OK"),
    ("note", "   no EFI/APPLE/EMBEDDEDOS on the ESP"),
    ("note", "   T1 now: 1281   start: provision"),
    ("blank", ""),
    ("ask",  "   ?  start the regeneration at 'provision'"),
    ("dim",  "     Press Enter to continue, or Ctrl-C to stop."),
    ("blank", ""),
    ("head", "====  Step 1 of 4: the T1 asks Apple for its own data"),
    ("ok",   "   FDRData ready"),
    ("head", "====  Step 2 of 4: personalising the T1's boot image"),
    ("ok",   "   image + ticket captured"),
    ("head", "====  Step 3 of 4: booting the T1"),
    ("ok",   "   T1 at 8600 · watch the Touch Bar"),
    ("head", "====  Step 4 of 4: making it permanent"),
    ("ok",   "   staged EFI/APPLE/EMBEDDEDOS · handover to t1bridge"),
    ("blank", ""),
    ("done", "====  regenerate complete. T1: 8600"),
    ("mint", "   4 min 8 s · no reboot"),
]

colors = {
    "cmd":  "#e8ecff",
    "head": "#3ee8a8",
    "note": "#b7c0e6",
    "ask":  "#ffc46b",
    "dim":  "#6b7394",
    "ok":   "#9aa3c7",
    "done": "#3ee8a8",
    "mint": "#3ee8a8",
    "blank": "#0b0f20",
}
weights = {
    "cmd": "700",
    "head": "700",
    "done": "800",
    "ask": "700",
    "mint": "700",
}

texts = []
y = 92
for kind, line in rows:
    if kind == "blank":
        y += 10
        continue
    w = weights.get(kind, "500")
    c = colors[kind]
    # escape
    line = (line.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    texts.append(
        f'<text x="36" y="{y}" font-family="{MONO}" font-size="15" font-weight="{w}" fill="{c}" font-variant-ligatures="none">{line}</text>'
    )
    y += 22

terminal = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="560" viewBox="0 0 1280 560" role="img" aria-label="t1-revive regenerate: from a wiped ESP to a booted T1 in about five minutes">
  <defs>{DEFS}</defs>
  <rect width="1280" height="560" rx="28" fill="#07091a" stroke="#ffffff" stroke-opacity="0.12"/>
  <path d="M0 0 h1280 v48 h-1280 z" fill="#0e1230"/>
  <path d="M0 0 h1280 a28 28 0 0 0 -28 -28 h-1224 a28 28 0 0 0 -28 28" fill="#0e1230"/>
  <rect width="1280" height="48" rx="28" fill="#0e1230"/>
  <rect y="24" width="1280" height="24" fill="#0e1230"/>
  <circle cx="32" cy="24" r="7" fill="#ff5d73"/>
  <circle cx="56" cy="24" r="7" fill="#ffc46b"/>
  <circle cx="80" cy="24" r="7" fill="#3ee8a8"/>
  <text x="640" y="30" text-anchor="middle" font-family="{MONO}" font-size="13" fill="#8b93c2">t1-revive  ·  regenerate</text>
  {"".join(texts)}
  <rect x="0" y="552" width="1280" height="8" fill="url(#spectrum)"/>
</svg>'''
write("terminal.svg", terminal)

print("done")
