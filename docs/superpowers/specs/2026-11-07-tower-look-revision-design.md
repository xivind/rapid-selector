# Tower part 1a: the look, revised

Approved by the owner on 2026-11-07, after seeing tower against the test fakes and two mockups (`.superpowers/brainstorm/`, not committed; version 3 is the approved one). A small change to tower part 1a before its test procedure on `sandbox`. It costs no money.

## Why

The owner found tower's first build good work but hard to read in places: small monospace labels, a kill switch strip that mixes text and buttons, status shown mostly in words, no sense of direction in the usage figures, and a Setup page that needs a lot of scrolling. The aim is a tower that can be read at a glance: what is the state, is anything wrong, and is use going up or down.

## Goals

1. Larger text everywhere.
2. One status panel at the top of every page, laid out in a fixed order.
3. Green, yellow and red lights and round badges for status.
4. A sense of change on Cost and Usage: against the previous period, like for like.
5. Setup in tabs.

## Non-goals and anti-goals

- No change to what tower does: the kill switch keeps its confirm steps, rules and routes, and the checks keep theirs.
- No new dependency and no client-side framework; htmx and the small `tower.js` stay as they are.
- Colour never carries a meaning alone: every light and badge has a word beside it.
- Red stays for danger. Up or down in use is neither good nor bad, so change arrows are never green or red.
- Look B stays: the same ground, serif, monospace and amber.

## Approaches

1. **Revise the stylesheet and templates, with the previous-period figures added server-side (chosen).** Fits the chosen stack (FastAPI, Jinja2, server-drawn, htmx).
2. JavaScript tabs and client-side comparisons: more code in the browser, which stack 1 avoids.
3. Starting the look over: not needed, as the owner wants look B kept.

## The design

### Text
Body text about 19 px (1.1875rem) on desktop and 17 px on a phone. No monospace label below about 13.5 px (.85rem). Headings and the big figures grow in proportion.

### Status panel (every page, replaces the kill switch strip)
Three columns on a raised panel, stacked on a phone:
- **Verdict** with a large light: `ALL CLEAR` green, `LEVEL 1` or `LEVEL 2` red (with `PARTIAL` as today), `UNKNOWN` yellow. The panel's border turns red when engaged.
- **Four lights**, each with a name and a word or figure:
  - *gateway keys*: green open; red blocked (by tower or outside it, with the count); yellow cannot be read.
  - *OpenRouter key*: green enabled; red disabled; yellow unknown.
  - *price check*: green all ok (with the time); red any failure; yellow stale (no run for over 26 hours); hollow when never run.
  - *reconciliation*: green not flagged (with the difference); red flagged; hollow when a source cannot be read.
- **KILL SWITCH**: the STOP and release buttons grouped, in the same cases as today. The confirm and release forms appear in the panel as today.
- The fixed notes ("What the levels do", and the note that level 1 does not block the master key or the admin UI's session) fold into a `details` under the panel. Everything about the current state stays visible, never folded: problems, errors, keys blocked outside tower, and the note while tower holds level 1.

### Lights and badges
A light is a small circle: green, yellow (kept distinct from the amber accent), red, or hollow for "no data". A badge is a rounded label with an optional light. Used on Setup (price check result per model, ZDR, "no fallback", key states) and in the status panel.

### Cost page
The hero stays. "resets … (gateway and key in step)" as plain text, as today. The four boxes are plain text:
- **Today**: the figure, and "yesterday $x" below.
- **This week**: the figure, and ▲ or ▼ with the percentage against the same days of last week.
- **Balance**: the figure, and a line green above the $2 threshold and red below it ("below the $2 threshold"). $2 is the same threshold as the "OpenRouter balance low" alert.
- **Forecast**: as today.

### Usage page
The same tables. In each cell:
- **Today**: the figure, and yesterday's figure in grey below ("yday …"). No arrow, since tower only gets whole days.
- **Week** and **month**: the figure, and below it an amber ▲ or a grey ▼ with the percentage, against the same stretch of the previous period: this week so far against the same weekdays of last week; this month so far against the same days of last month (cut at the end of a shorter month). `=` when the change is under half a percent, "new" when the earlier stretch had nothing.

### Setup page
Tabs: **Models**, **Teams and keys**, **OpenRouter** (the inference key and the management key together), **Gateway**, **Open WebUI**, **Secrets**. One tab shows at a time; each is its own address (`/setup?tab=models`, Models by default), plain links, no JavaScript. Four tabs carry a summary light:
- *Models*: green when every model's latest price check passed; red when any failed; hollow when never run.
- *Teams and keys*: green; yellow when a team has under 20% of its budget left; red under 10% (the alert thresholds) or a key blocked.
- *OpenRouter*: green when the inference key is enabled and the management key has over 30 days left; yellow when the expiry is unknown or under 30 days; red when the inference key is disabled or the management key has expired.
- *Secrets*: green when all are set; red when any is not.

Inside the tabs, the content is today's, with badges where a status is shown.

### Log page
Only the larger text.

## Left to the builder

- Exact sizes, spacing and colours within the above, checked on screen at desktop and phone width against the fakes, as the plan's Task 9 did.
- Where the previous-period figures are computed (the cost summary and the usage view), and how the gateway is asked for the extra days, staying within its 30-second cache.
- Tests for the comparison rules: the stretches (a Monday, the 31st against a 30-day month, the 1st), `=`, "new", and the lights' states.
- The existing tests that check page text are updated where the text moves, never weakened.
