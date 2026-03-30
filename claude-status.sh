#!/usr/bin/env bash
# Claude Status Monitor — live-updating terminal dashboard
# Mirrors https://status.claude.com/ with 90-day uptime history bars

set -euo pipefail

REFRESH=30  # seconds between refreshes

# ── Trap cleanup ────────────────────────────────────────
cleanup() {
  tput cnorm 2>/dev/null
  echo ""
  exit 0
}
trap cleanup INT TERM

# ── Main render ─────────────────────────────────────────
render() {
  python3 << 'PYEOF'
import json, urllib.request, re, sys, os

RST  = '\033[0m'
BOLD = '\033[1m'
DIM  = '\033[2m'
GREEN  = '\033[32m'
YELLOW = '\033[33m'
RED    = '\033[31m'
CYAN   = '\033[36m'
WHITE  = '\033[97m'
BG_GREEN  = '\033[42m'
BG_YELLOW = '\033[43m'
BG_RED    = '\033[41m'
BG_BLUE   = '\033[44m'

STATUS_ICON  = {'operational':'●','degraded_performance':'◐','partial_outage':'◑','major_outage':'✖','under_maintenance':'◫'}
STATUS_COLOR = {'operational':GREEN,'degraded_performance':YELLOW,'partial_outage':YELLOW,'major_outage':RED,'under_maintenance':CYAN}
STATUS_LABEL = {'operational':'Operational','degraded_performance':'Degraded','partial_outage':'Partial Outage','major_outage':'MAJOR OUTAGE','under_maintenance':'Maintenance'}

SHORTEN = {
    'platform.claude.com (formerly console.anthropic.com)': 'platform.claude.com',
    'Claude API (api.anthropic.com)': 'Claude API',
}

# ── Fetch API data ──────────────────────────────────────
try:
    req = urllib.request.Request(
        'https://status.claude.com/api/v2/summary.json',
        headers={'User-Agent': 'claude-status-terminal/1.0'}
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        api = json.loads(r.read())
except Exception as e:
    print(f'\n  {RED}Failed to fetch status data: {e}{RST}\n')
    sys.exit(0)

# ── Fetch HTML for 90-day uptime history ────────────────
# Maps component ID → { name, days: [{date, outages: {p, m}}] }
history = {}
try:
    req2 = urllib.request.Request(
        'https://status.claude.com/',
        headers={'User-Agent': 'claude-status-terminal/1.0'}
    )
    with urllib.request.urlopen(req2, timeout=10) as r:
        page_html = r.read().decode('utf-8', errors='replace')

    idx = page_html.find('uptimeData')
    if idx >= 0:
        start = page_html.find('{', idx)
        depth = 0
        end = start
        for i in range(start, min(start + 200000, len(page_html))):
            if page_html[i] == '{': depth += 1
            elif page_html[i] == '}': depth -= 1
            if depth == 0:
                end = i + 1
                break
        parsed = json.loads(page_html[start:end])
        for comp_id, comp in parsed.items():
            name = comp.get('component', {}).get('name', comp_id)
            days = comp.get('days', [])
            history[comp_id] = {'name': name, 'days': days}
except Exception:
    pass  # history is optional

# ── Terminal dimensions ─────────────────────────────────
try:
    cols = os.get_terminal_size().columns
except Exception:
    cols = 80
width = min(cols - 4, 76)
bar_width = min(width - 4, 60)
line = '─' * width

# ── Uptime bar renderer ────────────────────────────────
def render_bar(days, bar_len):
    """Render colored bar from daily outage data. Green/yellow/red per day."""
    if not days:
        return f'{DIM}{"·" * bar_len}{RST}', None

    # Take last bar_len days, pad left with green if fewer
    if len(days) >= bar_len:
        recent = days[-bar_len:]
    else:
        recent = [{'outages': {}}] * (bar_len - len(days)) + days

    bar = ''
    total_seconds = len(days) * 86400  # seconds per day
    total_outage = 0
    for day in days:
        outages = day.get('outages', {})
        # p and m overlap — use max to avoid double-counting
        total_outage += max(outages.get('p', 0), outages.get('m', 0))

    for day in recent:
        outages = day.get('outages', {})
        p = outages.get('p', 0)   # partial outage seconds
        m = outages.get('m', 0)   # major outage seconds
        worst = max(p, m)
        if worst == 0:
            bar += f'{GREEN}▌{RST}'
        elif m > 3600 or worst > 14400:  # >1h major or >4h total
            bar += f'{RED}▌{RST}'
        elif worst > 0:
            bar += f'{YELLOW}▌{RST}'
        else:
            bar += f'{GREEN}▌{RST}'

    # Calculate uptime percentage (values are in seconds)
    if total_seconds > 0:
        pct = ((total_seconds - total_outage) / total_seconds) * 100
    else:
        pct = None

    return bar, pct

# ── Header ──────────────────────────────────────────────
title = 'CLAUDE STATUS MONITOR'
pad_l = (width - 2 - len(title)) // 2
pad_r = width - 2 - len(title) - pad_l
print(f'  {BOLD}{WHITE}╔{"═"*(width-2)}╗{RST}')
print(f'  {BOLD}{WHITE}║{" "*pad_l}{title}{" "*pad_r}║{RST}')
print(f'  {BOLD}{WHITE}╚{"═"*(width-2)}╝{RST}')

# ── Overall banner ──────────────────────────────────────
ind = api['status']['indicator']
desc = api['status']['description']
banners = {
    'none':        f'{BG_GREEN}{WHITE}{BOLD}  ✓ {desc}  {RST}',
    'minor':       f'{BG_YELLOW}{WHITE}{BOLD}  ⚠ {desc}  {RST}',
    'major':       f'{BG_RED}{WHITE}{BOLD}  ✖ {desc}  {RST}',
    'critical':    f'{BG_RED}{WHITE}{BOLD}  ✖ {desc}  {RST}',
    'maintenance': f'{BG_BLUE}{WHITE}{BOLD}  ◫ {desc}  {RST}',
}
print(f'  {banners.get(ind, desc)}')
print()

# ── Services + history ──────────────────────────────────
print(f'  {BOLD}{WHITE}SERVICES{RST}  {DIM}Uptime over the past 90 days{RST}')
print(f'  {DIM}{line}{RST}')

for comp in api['components']:
    comp_id = comp['id']
    name = comp['name']
    short = SHORTEN.get(name, name)
    s = comp['status']
    icon  = STATUS_ICON.get(s, '?')
    color = STATUS_COLOR.get(s, DIM)
    label = STATUS_LABEL.get(s, s)

    # Get history by component ID (exact match)
    hist = history.get(comp_id)
    days = hist['days'] if hist else None

    # Service name + status
    pad = 26 - len(short)
    if pad < 2: pad = 2
    dots = '·' * pad
    print(f'  {color}{icon}{RST}  {short} {DIM}{dots}{RST} {color}{label}{RST}')

    # History bar
    bar, pct = render_bar(days, bar_width)
    print(f'     {bar}')

    # Labels row: "90 days ago ─── XX.XX % uptime ─── Today"
    pct_str = f'{pct:.2f} % uptime' if pct is not None else ''
    gap = bar_width - 11 - 5  # "90 days ago" = 11, "Today" = 5
    if pct_str and gap > len(pct_str) + 4:
        gap1 = (gap - len(pct_str)) // 2
        gap2 = gap - len(pct_str) - gap1
        spacer1 = '─' * max(gap1 - 1, 1) + ' '
        spacer2 = ' ' + '─' * max(gap2 - 1, 1)
        print(f'     {DIM}90 days ago{spacer1}{RST}{pct_str}{DIM}{spacer2}Today{RST}')
    else:
        print(f'     {DIM}90 days ago{" " * gap}Today{RST}')
    print()

# ── Active incidents ────────────────────────────────────
print(f'  {BOLD}{WHITE}ACTIVE INCIDENTS{RST}')
print(f'  {DIM}{line}{RST}')
incidents = api.get('incidents', [])
if not incidents:
    print(f'  {DIM}No active incidents{RST}')
else:
    for inc in incidents[:5]:
        impact = inc.get('impact', 'none')
        ic = {'none':GREEN,'minor':YELLOW,'major':RED,'critical':RED}.get(impact, DIM)
        status = inc.get('status', '?')
        iname = inc.get('name', '?')
        updated = inc.get('updated_at', '')[:16].replace('T', ' ')
        print(f'  {ic}▸ [{status}] {iname}{RST}')
        print(f'    {DIM}Updated: {updated} UTC{RST}')
        updates = inc.get('incident_updates', [])
        if updates:
            body = updates[0].get('body', '')
            if len(body) > 100: body = body[:100] + '…'
            print(f'    {DIM}{body}{RST}')
print()

# ── Scheduled maintenance ──────────────────────────────
print(f'  {BOLD}{WHITE}SCHEDULED MAINTENANCE{RST}')
print(f'  {DIM}{line}{RST}')
maint = api.get('scheduled_maintenances', [])
if not maint:
    print(f'  {DIM}None scheduled{RST}')
else:
    for m_item in maint[:3]:
        mname = m_item.get('name', '?')
        start = m_item.get('scheduled_for', '')[:16].replace('T', ' ')
        end = m_item.get('scheduled_until', '')[:16].replace('T', ' ')
        print(f'  {CYAN}▸ {mname}{RST}')
        print(f'    {DIM}{start} → {end} UTC{RST}')
print()

# ── Footer ──────────────────────────────────────────────
updated = api['page']['updated_at'][:19].replace('T', ' ')
print(f'  {DIM}Last updated: {updated} UTC │ r = refresh │ q = quit{RST}')
print(f'  {DIM}Source: status.claude.com{RST}')
print()
PYEOF
}

# ── Main loop ───────────────────────────────────────────
tput civis 2>/dev/null  # hide cursor

# Re-render immediately on terminal resize
trap 'clear; render' WINCH

LAST_COLS=$(tput cols 2>/dev/null || echo 80)

while true; do
  clear
  render
  # Sleep in 1-second chunks; press r/F5 to refresh, q to quit
  for i in $(seq 1 "$REFRESH"); do
    if read -t 1 -n 1 key 2>/dev/null; then
      [[ "$key" == "r" || "$key" == "R" ]] && break
      [[ "$key" == "q" || "$key" == "Q" ]] && cleanup
      # F5 sends escape sequence: ESC [ 1 5 ~
      if [[ "$key" == $'\x1b' ]]; then
        read -t 0.1 -n 4 seq 2>/dev/null
        [[ "$seq" == "[15~" ]] && break
      fi
    fi
  done
done
