# Tower's look, revised: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tower part 1a with the owner's revised look: larger text, one status panel with lights, badges, change against the previous period on Cost and Usage, and Setup in tabs.

**Architecture:** The same package and stack. The comparisons are pure logic in `summary.py`; the status panel's lights come from a new pure module `status.py`, rendered by the existing kill switch partial; Setup's tabs are plain links (`/setup?tab=…`) rendered on the server. The stylesheet gains a few classes (lights, badges, panel, tabs) and larger sizes.

**Tech Stack:** As tower part 1a: FastAPI, Jinja2, htmx 2 (vendored), `pytest`. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-07-tower-look-revision-design.md`. Also read `CLAUDE.md`, the plan `docs/superpowers/plans/2026-11-06-tower-part-1a.md` (its Global Constraints still hold), and the mockup the owner approved, if it is on this machine: `.superpowers/brainstorm/4355-1794004845/content/tower-look-v3.html` in the main checkout (not in git).

## Global Constraints

- Branch `tower-part-1a`. Commit after each task; messages end with the attribution lines from the session's system reminder. Push after each task.
- No change to what tower does: kill switch routes, confirm steps, release word, checks and metrics stay as they are. The kill switch partial keeps `id="killswitch"` and its htmx swap.
- The verdict words stay as today, because `tests/tower.bats` and the unit tests read them: `ALL CLEAR`, `LEVEL 1`, `LEVEL 2`, `· PARTIAL`, `STATE UNKNOWN` (the spec's "UNKNOWN" is shown as `STATE UNKNOWN`).
- Colours: keep the existing tokens; add `--go: #74c47a`, `--caution: #f0dc6a` (distinct from `--amber: #e0a33a`), and use `--danger` for red. A light or badge always has a word beside it. Change arrows: ▲ in `--amber`, ▼ in `--dim`, never green or red.
- Text: body `1.1875rem` (≈19 px) on desktop, `1.0625rem` under 760 px; no `font` or `font-size` in `rem` below `.85rem` in `tower.css`.
- Comparison rules (all UTC): today against all of yesterday, shown as a figure, no arrow; week so far (Monday to today) against last Monday to last week's same weekday; month so far (1st to today) against the 1st to the same day of last month, cut at that month's last day. Change kinds: `up`, `down`, `same` (|change| < 0.5%), `new` (previous 0, current > 0); none when both are 0.
- Balance threshold `$2.00` (the "OpenRouter balance low" alert): green at or above, red below.
- Light thresholds: price check stale after 26 hours; team budget yellow under 20% left, red under 10%; management key yellow under 30 days or unknown, red when expired.
- No secret value in any page, unchanged from part 1a (`test_no_secret_in_any_page` keeps passing).
- Tests: `cd tower && uv run pytest`. Level 1 (`tests/run.sh`) needs Docker: run it in a cloud session at the end (Task 6). Nothing spends money.

## Review Focus

1. **One source down:** the status panel shows the lights that depend on it as yellow or hollow, never green, and the STOP buttons stay. Test in Task 4 (`test_lights_gateway_down`, `test_lights_openrouter_down`).
2. **Edges of the calendar:** on a Monday the week compares with last Monday alone; on the 1st the month compares with the 1st of last month; on 31 March with 1–28 (or 29) February. Test in Task 2 (`test_previous_stretch_*`).
3. **Nothing before, or nothing at all:** previous 0 and current > 0 shows "new"; both 0 shows no change mark, not "▲ 0%" or a division error. Test in Task 2 (`test_change_*`).
4. **The gateway down on the Cost page:** today's figure (OpenRouter's) still shows, with no "yesterday" line and no week arrow, never "yesterday $0.00" by mistake. Test in Task 3 (`test_cost_page_without_gateway_comparison`).
5. **The kill switch while engaged:** the confirm form, the release form and the note while tower holds level 1 still render inside the new panel, and problems and keys blocked outside tower are never folded away. Test in Task 4 (`test_panel_engaged_shows_release_and_problems`).

---

## File structure

```
tower/tower/static/tower.css             sizes, panel, lights, badges, tabs, change marks
tower/tower/summary.py                   Change, change(), previous stretches, new fields
tower/tower/status.py                    NEW: Light, panel_lights(), tab_lights()
tower/tower/killswitch.py                render() passes the lights
tower/tower/templates/partials/killswitch.html   the status panel
tower/tower/templates/macros/marks.html  NEW: light(), badge(), change() macros
tower/tower/templates/cost.html, usage.html, setup.html   comparisons, badges, tabs
tower/tower/app.py                       cost/usage/setup routes pass the new data
tower/tests/preview.py                   NEW: serves tower against the page tests' fakes, for a look
tower/tests/test_summary.py, test_status.py (NEW), test_pages.py, test_killswitch.py
```

### Task 1: Text sizes, marks and the preview helper

**Files:**
- Modify: `tower/tower/static/tower.css`
- Create: `tower/tower/templates/macros/marks.html`, `tower/tests/preview.py`
- Test: `tower/tests/test_pages.py`

**Interfaces:**
- Produces: CSS classes `.dot` with `.go`, `.caution`, `.stop`, `.off` (hollow) and `.big`; `.badge` with the same colour modifiers and `.plain`; `.up`, `.down`, `.same` change marks. Jinja macros in `macros/marks.html`: `light(colour, word)` → a `.dot` span plus the word; `badge(text, colour=None, dot=False)`; `change_mark(c)` taking a `Change` or `None` (Task 2) → `<span class="up">12%</span>`, `<span class="down">7%</span>`, `<span class="same">=</span>`, `new`, or nothing.
- `tests/preview.py`: `uv run python tests/preview.py` serves tower on `127.0.0.1:8765` with `FakeGateway` and `FakeOpenRouter` from `test_pages.py`, password `look`, a temporary data dir, no loop. Not imported by any test.

- [ ] **Step 1: Write `test_css_has_no_label_below_085rem`**: read `tower.css`; every `rem` size inside a `font:` or `font-size:` declaration is ≥ 0.85, except `clamp()` lower bounds above that; `body` sets `1.1875rem`.
- [ ] **Step 2: Run** `cd tower && uv run pytest tests/test_pages.py -k css -v` — expected FAIL (`.72rem` and others today).
- [ ] **Step 3: Implement** the sizes and the classes, matching the mockup: lights are circles about `.8em` with a soft glow, `.big` about `1.1rem`; badges are rounded (`border-radius: 1em`) in `.85rem`. Write the macros and `preview.py`.
- [ ] **Step 4: Run** the whole suite — expected PASS. Start `preview.py` and look at all four pages at desktop and phone width.
- [ ] **Step 5: Commit** `tower: larger text, lights, badges and change marks`.

### Task 2: Comparisons with the previous period

**Files:**
- Modify: `tower/tower/summary.py`
- Test: `tower/tests/test_summary.py`

**Interfaces:**
- Produces:
  - `@dataclass Change(kind: Literal["up", "down", "same", "new"], pct: float | None)`; `change(current: float, previous: float) -> Change | None`: `None` when both are 0; `new` (pct `None`) when previous is 0; `same` when |pct| < 0.5; else `up`/`down` with `pct = abs(current − previous) / previous × 100`.
  - `previous_stretches(now) -> dict[str, tuple[datetime, datetime]]`: `[start, end)` for `"day"` (yesterday), `"week"` (last Monday 00:00 to the day after last week's same weekday), `"month"` (the 1st of last month to the day after the same day, cut at the day after that month's last day).
  - `Totals` gains nothing; `UsageLine` gains `yesterday: Totals`, `week_before: Totals`, `month_before: Totals`, filled by `_lines` from `previous_stretches`. A line that has figures only in the previous stretches is not listed (the current filter stays).
  - `CostSummary` gains `spend_yesterday_usd: float | None` and `week_change: Change | None`, both from the gateway's usage rows, which `cost_summary` already gets (`None` when the gateway is missing): yesterday's spend, and `change(this week so far, previous_stretches["week"])`, both sides from the gateway. Not from OpenRouter's activity: it holds only completed days and may not have yesterday just after midnight, which would show a false $0.00; the boxes' main figures stay OpenRouter's. The cost route's 30 days cover both stretches.

- [ ] **Step 1: Write tests:** `test_change_up_down_same_new_none` (`change(12, 10)` → up 20.0; `change(9, 10)` → down 10.0; `change(10.04, 10)` → same; `change(1, 0)` → new; `change(0, 0)` → None; `change(0, 5)` → down 100.0); `test_previous_stretch_on_a_monday` (Mon 2026-11-09 00:10 → week `[2026-11-02, 2026-11-03)`); `test_previous_stretch_on_a_sunday` (Sun 2026-11-15 23:59 → week `[2026-11-02, 2026-11-09)`); `test_previous_stretch_on_the_first` (2026-12-01 → month `[2026-11-01, 2026-11-02)`, day `[2026-11-30, 2026-12-01)`); `test_previous_stretch_cut_at_month_end` (2027-03-31 → month `[2027-02-01, 2027-03-01)`); `test_usage_lines_carry_previous_stretches` (rows on today, yesterday, last week's same weekday and last month's same day land in the right fields); `test_cost_summary_yesterday_and_week_change` (gateway rows yesterday $0.25, this week $2.10, last week's stretch $2.40 → `spend_yesterday_usd` 0.25, `week_change` down 12.5); `test_cost_summary_gateway_unavailable_has_no_comparison` (both `None`).
- [ ] **Step 2: Run** `uv run pytest tests/test_summary.py -v` — expected FAIL.
- [ ] **Step 3: Implement** in `summary.py`. In `app.py`, the Usage route asks the gateway for 62 days instead of `USAGE_DAYS` (a new constant `USAGE_DAYS_COMPARED = 62`; `USAGE_DAYS` stays 30 for the cost page and the loop).
- [ ] **Step 4: Run** the whole suite — expected PASS.
- [ ] **Step 5: Commit** `tower: compare with the previous period`.

### Task 3: Cost and Usage pages

**Files:**
- Modify: `tower/tower/templates/cost.html`, `tower/tower/templates/usage.html`, `tower/tower/app.py` (register `change` as a template global)
- Test: `tower/tests/test_pages.py`

**Interfaces:**
- Consumes: Task 1's macros, Task 2's `change`, `UsageLine` and `CostSummary` fields.
- Produces: Cost: four boxes in a row (`.cards`): TODAY with "yesterday $x" when known; THIS WEEK with `change_mark(s.week_change)`; BALANCE with a line `above the $2 threshold` in `--go` or `below the $2 threshold` in `--danger`; FORECAST as today. "resets … (gateway and key in step)" stays plain text. Usage: under each today figure, `yday <figure>` in `--dim`; under each week and month figure, `change_mark(change(…))` against `week_before` and `month_before`; the lede says what is compared with what.

- [ ] **Step 1: Write tests:** `test_cost_page_shows_yesterday_and_week_change` (gateway rows as in Task 2's test → `yesterday $0.25` and a `class="down"` with `12%`); `test_cost_page_balance_line_colour` (balance 12.60 → `above the $2 threshold`; credits giving 1.40 → `below the $2 threshold` inside an element with class `danger`); `test_cost_page_without_gateway_comparison` (gateway `Down` → no `yesterday` text and no change mark in the week box, the page still 200); `test_usage_page_shows_yday_and_changes`; update `test_cost_page_shows_figures` where the text moved, without weakening it.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement** the templates.
- [ ] **Step 4: Run** the whole suite — expected PASS. Look at both pages with `preview.py`.
- [ ] **Step 5: Commit** `tower: cost and usage show the change`.

### Task 4: The status panel

**Files:**
- Create: `tower/tower/status.py`, `tower/tests/test_status.py`
- Modify: `tower/tower/killswitch.py` (`register.render`), `tower/tower/templates/partials/killswitch.html`, `tower/tower/templates/base.html` (the placeholder before htmx loads)
- Test: `tower/tests/test_status.py`, `tower/tests/test_killswitch.py`, `tower/tests/test_pages.py`

**Interfaces:**
- Produces:
  - `@dataclass Light(colour: Literal["go", "caution", "stop", "off"], word: str)`.
  - `panel_lights(state: SwitchState, price_check, reconciliation: Reconciliation | None | Unavailable, now: datetime) -> dict[str, Light]` with keys `gateway_keys`, `openrouter_key`, `price_check`, `reconciliation`, pure:
    - gateway_keys: `caution` "cannot read the gateway" when `not state.gateway_read`; `stop` "`n` blocked by tower" / "`n` blocked outside tower" when any; else `go` "open".
    - openrouter_key: `stop` "disabled"; `caution` "unknown" when `openrouter_disabled is None`; `go` "enabled".
    - price_check (the latest `LogEntry` or `None`): `off` "not run yet"; `caution` "stale, last <stamp>" after 26 h; `stop` "failed, <stamp>" when not ok; `go` "ok, <HH:MM>".
    - reconciliation: `off` "no figures" when `None` or `Unavailable`; `stop` "$x apart" when flagged; `go` "in step" when |diff| < $0.01, else "$x apart".
  - `reconciliation_now(gw, orc, now, end) -> Reconciliation | Unavailable`: month spend from the gateway's usage rows and the key's `usage_monthly`, through `setup_view.gather` within `end` (the clients' 30-second cache makes this cheap after the Cost page).
  - `SwitchState` gains `gateway_read: bool = True` (last field, so existing constructors still work); `read_state` sets it `False` when the keys are an `Unavailable`. Nothing else in the kill switch changes.
- Consumes: `killswitch.register.render` adds `lights` and `verdict_colour` (`go` at level 0 without problems, `caution` at level 0 with problems or level `None`, `stop` at 1 or 2) to its context.

The panel, from the spec: verdict with a `.big` light on the left; the four lights in a two-column grid in the middle; "KILL SWITCH" with the STOP and release buttons on the right (the same conditions as today); the confirm and release forms inside the panel as today; a `details` "What the levels do" holding only the fixed notes; error, problems, keys blocked outside tower and the level 1 note visible below the grid. The panel gets class `engaged` (red border) at level 1 or 2.

- [ ] **Step 1: Write tests:** in `test_status.py`, one test per light state above (`test_read_state_marks_gateway_unread`, `test_lights_all_clear`, `test_lights_level1_by_tower`, `test_lights_blocked_outside`, `test_lights_gateway_down`, `test_lights_openrouter_down`, `test_price_light_not_run_stale_failed_ok`, `test_reconciliation_light_none_flagged_in_step_apart`); in `test_pages.py` / `test_killswitch.py`: `test_panel_all_clear` (`ALL CLEAR`, four light words, two STOP buttons, `details` with "What the levels do"); `test_panel_engaged_shows_release_and_problems` (level 1 by tower, a problem and a key blocked outside → `LEVEL 1`, class `engaged`, the release form, the problem text and the outside key outside any `details`); keep the existing kill switch tests passing with their wording.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement** `status.py`, the partial and `render`.
- [ ] **Step 4: Run** the whole suite — expected PASS. Look at the panel with `preview.py`, also at phone width (stacked).
- [ ] **Step 5: Commit** `tower: the status panel`.

### Task 5: Setup in tabs

**Files:**
- Modify: `tower/tower/status.py`, `tower/tower/app.py` (the `/setup` route), `tower/tower/templates/setup.html`
- Test: `tower/tests/test_status.py`, `tower/tests/test_pages.py`

**Interfaces:**
- Produces: `tab_lights(view: dict, now: datetime) -> dict[str, Light | None]` for `models`, `teams_and_keys`, `openrouter`, `secrets` (`gateway` and `open_webui` have none), pure, on `setup_view.build`'s view:
  - models: `off` when no model has a `price_check`; `stop` when any is not `"ok"`; else `go`.
  - teams_and_keys: `stop` when a team or key is blocked or a team has under 10% of its budget left; `caution` under 20%; `go` otherwise; `off` when the section is `None`.
  - openrouter: `stop` when the inference key is disabled or `days_left < 0`; `caution` when `days_left` is `None` or under 30; `go` otherwise; `off` when `openrouter_key` is `None`.
  - secrets: `stop` when any is `not set`; else `go`.
- `GET /setup?tab=models|teams|openrouter|gateway|webui|secrets`, default `models`; an unknown tab answers 422 (FastAPI `Literal`). The tabs are links with `aria-current="page"` on the open one; only that tab's section is rendered. The OpenRouter tab holds the inference key and the management key. Badges in the Models table: the price check result (`go` "price ok" / `stop` with the reason), "ZDR" (`go`) or "no ZDR" (`stop`), "no fallback" (`plain`) or "fallbacks on" (`caution`).

- [ ] **Step 1: Write tests:** `test_tab_lights_*` for each rule above; `test_setup_tabs_default_models` (Models table present, "Teams and keys" content absent, six tab links); `test_setup_tab_openrouter_has_both_keys`; `test_setup_unknown_tab_422`; update the page tests that read Setup, without weakening them: `test_setup_page_renders` (each text from the tab that holds it), `test_setup_page_with_both_down` (every tab), `test_setup_warns_about_a_malformed_expiry` (`?tab=openrouter`), the deadline test's page list, and `test_no_secret_in_any_page` (every tab). The tests in `test_setup_view.py` call `build()` and need no change.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the whole suite — expected PASS. Look at every tab with `preview.py`.
- [ ] **Step 5: Commit** `tower: setup in tabs`.

### Task 6: The owner's look, the Docker run, the records

**Files:**
- Modify: `docs/test-procedures/tower-1a.md` (only where a step names text that moved, e.g. a Setup section now behind a tab), on this branch; `docs/decisions.md` and `docs/test-procedures/phase-0-status.md` on `phase-0-walkthrough` (the controller does this, not a subagent)

- [ ] **Step 1:** Update `tower-1a.md` where its steps point to moved text. `grep -n "Setup\|ALL CLEAR\|kill switch" docs/test-procedures/tower-1a.md` lists the candidates.
- [ ] **Step 2:** The controller starts `preview.py` on the owner's machine and the owner looks at all four pages. Changes they ask for go back through the task that owns them.
- [ ] **Step 3:** A cloud session runs `tests/run.sh` and `cd tower && uv run pytest` on `tower-part-1a` (the prompt from `phase-0-status.md`, item "third Docker run", with the commit range of this plan). Expected: all pass.
- [ ] **Step 4:** Commit and push; record the owner's sign-off and the run in `docs/decisions.md` on `phase-0-walkthrough`.
