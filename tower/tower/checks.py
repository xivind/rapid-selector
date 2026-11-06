"""Price check (free) and smoke test (spends a little real money, only on the owner's confirmation).

Ports tests/check-prices.sh and scripts/smoke-test.sh. The price check reads the prices the
running gateway reports in /model/info, so it checks what the gateway runs, not a file.
"""

import hashlib
from dataclasses import dataclass
from typing import Literal

import httpx
from fastapi import Form, Query, Request
from fastapi.responses import HTMLResponse

from tower import store
from tower.clients import Unavailable
from tower.killswitch import SwitchState, current_state

PRICE_TOLERANCE = 1e-15
SMOKE_INPUT_TOKENS = 50  # the smoke prompt, rounded up
SMOKE_MAX_TOKENS = 256
SMOKE_TIMEOUT = 120.0
PROMPT = "Reply with the word ok."
PROBE_MODEL = "openai/gpt-4o"
PROBE_PASSTHROUGH = "/openrouter/v1/chat/completions"


@dataclass
class PriceResult:
    name: str
    slug: str
    ok: bool
    reason: str


@dataclass
class SmokePlan:
    names: list[tuple[str, bool]]  # (name, reasoning)
    worst_case_usd: float


@dataclass
class SmokeResult:
    rows: list[tuple[str, int, float]]  # (name, HTTP status, recorded cost)
    refusals: list[tuple[str, int]]  # (probe, HTTP status)
    total_usd: float
    ok: bool
    refused_reason: str | None


def _prices(entry):
    info, params = entry.get("model_info") or {}, entry.get("litellm_params") or {}
    out = []
    for field in ("input_cost_per_token", "output_cost_per_token"):
        value = info.get(field)
        out.append(params.get(field) if value is None else value)
    return out


def _check(entry, endpoints) -> PriceResult:
    params = entry["litellm_params"]
    model = params["model"].removeprefix("openrouter/")
    slug = params["extra_body"]["provider"]["order"][0]
    name = entry["model_name"]
    match = next((e for e in endpoints if e.get("model_id") == model and e.get("tag") == slug), None)
    if match is None:
        return PriceResult(name, slug, False, f"no zero data retention endpoint {slug} for {model}")
    if match.get("service_tier") == "flex":
        return PriceResult(name, slug, False, "flex tier")
    if match.get("safety_retention") is True:
        return PriceResult(name, slug, False, "uses Safety Retention, not zero data retention")
    cfg_in, cfg_out = _prices(entry)
    try:
        now_in, now_out = float(match["pricing"]["prompt"]), float(match["pricing"]["completion"])
        cfg_in, cfg_out = float(cfg_in), float(cfg_out)
    except (TypeError, ValueError, KeyError):
        return PriceResult(name, slug, False, "missing price in the config")
    if abs(now_in - cfg_in) >= PRICE_TOLERANCE or abs(now_out - cfg_out) >= PRICE_TOLERANCE:
        return PriceResult(name, slug, False,
                           f"price is now {match['pricing']['prompt']} / {match['pricing']['completion']} "
                           f"per token, configured {cfg_in:g} / {cfg_out:g}")
    return PriceResult(name, slug, True, "")


def check_prices(models: list[dict], endpoints: list[dict]) -> list[PriceResult]:
    results = []
    for entry in models:
        try:
            results.append(_check(entry, endpoints))
        except (KeyError, IndexError, TypeError):
            results.append(PriceResult(entry.get("model_name", "?"), "?", False, "entry has no pinned host"))
    return results


def run_price_check(gw, orc, actor) -> list[PriceResult]:
    results = check_prices(gw.model_info(), orc.zdr_endpoints())
    ok = all(r.ok for r in results)
    bad = [r for r in results if not r.ok]
    store.log("price_check", actor, ok,
              "all prices match" if ok else f"{len(bad)} of {len(results)} entries fail",
              {"results": {r.name: ("ok" if r.ok else r.reason) for r in results}})
    return results


def plan_smoke(models: list[dict], scope: Literal["roles", "all"]) -> SmokePlan:
    seen, names, worst = set(), [], 0.0
    for m in models:
        info = m.get("model_info") or {}
        name = m["model_name"]
        if name in seen or (scope == "roles" and info.get("rapidselector_kind") != "role"):
            continue
        seen.add(name)
        names.append((name, info.get("reasoning") is True))
        price_in, price_out = _prices(m)
        worst += SMOKE_INPUT_TOKENS * float(price_in or 0) + SMOKE_MAX_TOKENS * float(price_out or 0)
    return SmokePlan(names, worst)


def probe_ok(name: str, status: int) -> bool:
    return status in (401, 403) if name == PROBE_PASSTHROUGH else 400 <= status < 500


def run_smoke(plan: SmokePlan, switch: SwitchState, budget_left_usd: float | None,
              gateway_url, smoke_key, http: httpx.Client) -> SmokeResult:
    reason = None
    if switch.level != 0:
        reason = ("the kill switch state is unknown" if switch.level is None
                  else f"the kill switch is engaged (level {switch.level})")
    elif budget_left_usd is not None and budget_left_usd < plan.worst_case_usd:
        reason = (f"the smoke-test key's budget left (${budget_left_usd:.6f}) "
                  f"is below the worst case (${plan.worst_case_usd:.6f})")
    if reason:
        return SmokeResult([], [], 0.0, False, f"Refused, nothing spent: {reason}")

    base = gateway_url.rstrip("/")
    headers = {"Authorization": f"Bearer {smoke_key}"}

    def post(path, body):
        try:
            return http.post(base + path, json=body, headers=headers, timeout=SMOKE_TIMEOUT)
        except httpx.HTTPError:
            return None

    rows = []
    for name, reasoning in plan.names:
        body = {"model": name, "max_tokens": SMOKE_MAX_TOKENS,
                "messages": [{"role": "user", "content": PROMPT}]}
        if reasoning:
            body["reasoning_effort"] = "low"
        resp = post("/v1/chat/completions", body)
        if resp is None:
            rows.append((name, 0, 0.0))
            continue
        try:
            cost = float(resp.headers.get("x-litellm-response-cost") or 0)
        except ValueError:
            cost = 0.0
        rows.append((name, resp.status_code, cost))

    probe = {"model": PROBE_MODEL, "messages": [{"role": "user", "content": "hi"}]}
    refusals = []
    for name, path, model in ((PROBE_MODEL, "/v1/chat/completions", PROBE_MODEL),
                              (PROBE_PASSTHROUGH, PROBE_PASSTHROUGH, "classify")):
        resp = post(path, {**probe, "model": model})
        refusals.append((name, 0 if resp is None else resp.status_code))

    ok = (all(status == 200 and cost > 0 for _, status, cost in rows)
          and all(probe_ok(n, s) for n, s in refusals))
    return SmokeResult(rows, refusals, sum(c for _, _, c in rows), ok, None)


def _smoke_summary(r: SmokeResult) -> str:
    if r.refused_reason:
        return r.refused_reason
    return f"{'ok' if r.ok else 'FAILED'}: {len(r.rows)} call(s), ${r.total_usd:.6f}"


def register(router, app):
    def render(request, **context):
        context = {"price": None, "plan": None, "scope": None, "smoke": None, "error": None,
                   "probe_ok": probe_ok, **context}
        return app.state.templates.TemplateResponse(request, "partials/checks.html", context)

    def price_context(actor):
        try:
            return {"price": run_price_check(app.state.gateway, app.state.openrouter, actor)}
        except Unavailable as e:
            store.log("price_check", actor, False, str(e), {"results": {}, "error": str(e)})
            return {"error": str(e)}

    @router.get("/partials/checks", response_class=HTMLResponse)
    def partial(request: Request):
        return render(request)

    @router.post("/checks/price", response_class=HTMLResponse)
    def price_route(request: Request):
        return render(request, **price_context("owner"))

    @router.get("/checks/smoke", response_class=HTMLResponse)
    def smoke_confirm(request: Request, scope: Literal["roles", "all"] = Query("roles")):
        try:
            plan = plan_smoke(app.state.gateway.model_info(), scope)
        except Unavailable as e:
            return render(request, error=str(e))
        return render(request, plan=plan, scope=scope)

    @router.post("/checks/smoke", response_class=HTMLResponse)
    def smoke_route(request: Request, scope: Literal["roles", "all"] = Form("roles"),
                    confirm: str = Form("")):
        gw, orc = app.state.gateway, app.state.openrouter
        try:
            plan = plan_smoke(gw.model_info(), scope)
        except Unavailable as e:
            return render(request, error=str(e))
        if confirm != "yes":
            return render(request, plan=plan, scope=scope, error="Nothing was called: confirm first.")
        switch = current_state(gw, orc, fresh=True)
        try:
            # The key is read by the hash of the key, so the key itself is never in a URL.
            info = gw.key(hashlib.sha256(app.state.settings.smoke_key.encode()).hexdigest()).get("info", {})
            max_budget = info.get("max_budget")
            left = None if max_budget is None else float(max_budget) - float(info.get("spend") or 0)
            result = None
        except Unavailable as e:
            left, result = None, SmokeResult([], [], 0.0, False,
                                             f"Refused, nothing spent: the smoke-test key cannot be read ({e})")
        if result is None:
            with httpx.Client() as http:
                result = run_smoke(plan, switch, left, app.state.settings.gateway_url,
                                   app.state.settings.smoke_key, http)
        store.log("smoke_test", "owner", result.ok, _smoke_summary(result),
                  {"rows": result.rows, "refusals": result.refusals, "total_usd": result.total_usd,
                   "refused_reason": result.refused_reason, "scope": scope})
        return render(request, plan=plan, scope=scope, smoke=result)
