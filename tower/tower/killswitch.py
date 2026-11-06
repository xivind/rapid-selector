"""Two-level kill switch.

Level 1 blocks every gateway key except tower's own; level 2 also disables the
OpenRouter inference key. Every engage sets the level1_by_tower flag: while it is set,
tower keeps every other key blocked, even one it could not reach when engaging, and
only a successful release of level 1 clears it. Tower releases only what it engaged:
the keys in BlockedKey and the OpenRouter key when the level2_by_tower flag is set.
The state shown is always read back from the sources, and unknown when they cannot be read.
"""

import threading
from dataclasses import dataclass
from datetime import UTC, datetime

from fastapi import Form, HTTPException, Request
from fastapi.responses import HTMLResponse

from tower import store
from tower.clients import Unavailable

LEVEL1_FLAG = "level1_by_tower"
LEVEL2_FLAG = "level2_by_tower"
_lock = threading.Lock()  # a loop tick and a click must not interleave their changes


@dataclass
class SwitchState:
    level: int | None
    outside_tower: bool
    level1_complete: bool
    blocked_by_tower: list[str]
    blocked_outside: list[str]
    openrouter_disabled: bool | None
    problems: list[str]


def _name(alias, token_hash):
    return alias or f"key {token_hash[:8]}"


def _try(source, call):
    """The call's result, or Unavailable naming the source; never raises."""
    try:
        return call()
    except Unavailable as e:
        return e
    except Exception as e:  # malformed answers must not break the kill switch
        return Unavailable(source, type(e).__name__)


def _fresh(client):
    # Decisions and read-backs must not reuse a read cached before a change.
    cache = getattr(client, "_cache", None)
    if cache is not None:
        cache.clear()


def read_state(keys, or_key, tower_blocked, level2_by_tower, own_hash, level1_by_tower=False) -> SwitchState:
    problems, by_tower, outside, complete = [], [], [], False
    if isinstance(keys, Unavailable):
        problems.append(str(keys))
    else:
        others = [k for k in keys if k.token_hash != own_hash]
        for k in others:
            if k.blocked:
                (by_tower if k.token_hash in tower_blocked else outside).append(_name(k.alias, k.token_hash))
        open_keys = [_name(k.alias, k.token_hash) for k in others if not k.blocked]
        complete = not open_keys
        if open_keys and (by_tower or outside or level1_by_tower):
            problems.append(f"level 1 incomplete, not blocked: {', '.join(open_keys)}")
    if isinstance(or_key, Unavailable):
        problems.append(str(or_key))
        disabled = None
    else:
        disabled = bool(or_key.get("disabled"))
        if level2_by_tower and not disabled:
            problems.append("tower disabled the OpenRouter key, but it reads back enabled")
    if disabled:
        level = 2
    elif disabled is None or isinstance(keys, Unavailable):
        level = None
    else:
        level = 1 if by_tower or outside or level1_by_tower else 0
    return SwitchState(
        level=level,
        outside_tower=bool(outside) or (disabled is True and not level2_by_tower),
        level1_complete=complete,
        blocked_by_tower=by_tower,
        blocked_outside=outside,
        openrouter_disabled=disabled,
        problems=problems,
    )


def _flag(name) -> bool:
    return store.Flag.get_or_none(store.Flag.name == name) is not None


def _level2_by_tower() -> bool:
    return _flag(LEVEL2_FLAG)


def current_state(gw, orc, fresh=False, end=None) -> SwitchState:
    """end: a deadline (time.monotonic()) for both reads together, as the pages use."""
    if fresh:
        _fresh(gw)
        _fresh(orc)
    if end is None:
        keys, or_key = _try("gateway", gw.keys), _try("openrouter", orc.inference_key)
    else:
        from tower import setup_view  # imported here: setup_view imports this module

        got = setup_view.gather({"keys": ("gateway", gw.keys), "or_key": ("openrouter", orc.inference_key)}, end)
        keys, or_key = got["keys"], got["or_key"]
    return read_state(
        keys,
        or_key,
        {b.token_hash for b in store.BlockedKey.select()},
        _level2_by_tower(),
        gw.own_hash(),
        _flag(LEVEL1_FLAG),
    )


def _block_open_keys(gw, keys, problems) -> list[str]:
    """Blocks each key that is not tower's and not blocked; records it once its block succeeded."""
    done = []
    for k in keys:
        if k.token_hash == gw.own_hash() or k.blocked:
            continue
        name = _name(k.alias, k.token_hash)
        error = _try("gateway", lambda: gw.block(k.token_hash))
        if isinstance(error, Unavailable):
            problems.append(f"could not block {name}: {error}")
            continue
        store.BlockedKey.insert(
            token_hash=k.token_hash, alias=k.alias, blocked_at=datetime.now(UTC)
        ).on_conflict_ignore().execute()
        done.append(name)
    return done


def _block_all(gw, problems) -> list[str] | Unavailable:
    """Reads the keys afresh and blocks each open one; Unavailable when the gateway cannot be read."""
    _fresh(gw)
    keys = _try("gateway", gw.keys)
    if isinstance(keys, Unavailable):
        return keys
    return _block_open_keys(gw, keys, problems)


def _disable_openrouter(orc, problems) -> tuple[bool, str | None]:
    """(whether tower disabled the key now, a note for the log summary)."""
    _fresh(orc)
    key = _try("openrouter", orc.inference_key)
    if isinstance(key, Unavailable):
        problems.append(f"level 2 not engaged: {key}")
        return False, None
    if key.get("disabled"):
        # Already disabled: by tower (flag set) or outside tower (not tower's to release).
        by = "by tower" if _level2_by_tower() else "outside tower, so not tower's to release"
        return False, f"OpenRouter key already disabled {by}"
    error = _try("openrouter", lambda: orc.set_disabled(key["hash"], True))
    if isinstance(error, Unavailable):
        problems.append(f"level 2 not engaged: {error}")
        return False, None
    store.Flag.replace(name=LEVEL2_FLAG, value="true").execute()
    return True, "OpenRouter key disabled"


def _finish(action, level, gw, orc, actor, problems, detail, summary) -> SwitchState:
    store.log("kill_switch", actor, not problems, f"{action} level {level}: {summary}",
              {"action": action, "level": level, **detail, "problems": problems})
    state = current_state(gw, orc, fresh=True)
    state.problems = problems + state.problems
    return state


def engage(level, gw, orc, actor) -> SwitchState:
    if level not in (1, 2):
        raise ValueError("level must be 1 or 2")
    problems, disabled, note = [], False, None
    with _lock:
        # Held from now on, even if no key can be blocked yet: the loop blocks them once it can.
        store.Flag.replace(name=LEVEL1_FLAG, value="true").execute()
        if level == 2:
            # First: blocking each key on a slow gateway must not hold back the stop that does not need it.
            disabled, note = _disable_openrouter(orc, problems)
        blocked = _block_all(gw, problems)
        if isinstance(blocked, Unavailable):
            problems.append(f"level 1 not yet engaged: {blocked}; tower blocks the keys once it can read them")
            blocked = []
        summary = f"blocked {len(blocked)} key(s)" + (f"; {note}" if note else "")
        if problems:
            summary += f"; {len(problems)} problem(s)"
        return _finish("engage", level, gw, orc, actor, problems,
                       {"blocked": blocked, "openrouter_disabled": disabled}, summary)


def _release_level2(orc, problems) -> bool:
    if not _level2_by_tower():
        problems.append("tower did not disable the OpenRouter key; "
                        "if it is disabled, release it in OpenRouter's dashboard")
        return False
    _fresh(orc)
    key = _try("openrouter", orc.inference_key)
    error = key if isinstance(key, Unavailable) else _try(
        "openrouter", lambda: orc.set_disabled(key["hash"], False))
    if isinstance(error, Unavailable):
        problems.append(f"level 2 not released: {error}")
        return False
    store.Flag.delete().where(store.Flag.name == LEVEL2_FLAG).execute()
    return True


def _release_level1(gw, orc, problems) -> list[str]:
    if _level2_by_tower():
        problems.append("level 1 not released: release level 2 first")
        return []
    _fresh(orc)
    key = _try("openrouter", orc.inference_key)
    if isinstance(key, Unavailable):
        # Tower did not disable the key, so releasing level 1 starts nothing tower stopped at
        # level 2; refusing would lock level 1 in place while the management key is unusable.
        problems.append(f"the OpenRouter key cannot be read ({key}); level 1 released anyway")
    elif key.get("disabled"):
        problems.append("level 1 not released while the OpenRouter key is disabled "
                        "outside tower; release that in OpenRouter's dashboard first")
        return []
    _fresh(gw)
    keys = _try("gateway", gw.keys)
    present = None if isinstance(keys, Unavailable) else {k.token_hash for k in keys}
    done, failed = [], False
    for row in store.BlockedKey.select():
        name = _name(row.alias, row.token_hash)
        if present is not None and row.token_hash not in present:
            row.delete_instance()  # deleted from the gateway; nothing left to unblock
            continue
        error = _try("gateway", lambda: gw.unblock(row.token_hash))
        if isinstance(error, Unavailable):
            problems.append(f"could not unblock {name}: {error}")
            failed = True
            continue
        row.delete_instance()
        done.append(name)
    if not failed:  # level 1 stays held (and enforced) until every key tower blocked is unblocked
        store.Flag.delete().where(store.Flag.name == LEVEL1_FLAG).execute()
    return done


def release(level, gw, orc, actor) -> SwitchState:
    if level not in (1, 2):
        raise ValueError("level must be 1 or 2")
    problems = []
    with _lock:
        if level == 2:
            if _level2_by_tower() and _flag(LEVEL1_FLAG):
                _block_all(gw, problems)  # level 1 stays engaged: block what the loop has not yet
            enabled = _release_level2(orc, problems)
            detail = {"openrouter_enabled": enabled}
            summary = "OpenRouter key enabled" if enabled else "OpenRouter key not changed"
        else:
            unblocked = _release_level1(gw, orc, problems)
            detail = {"unblocked": unblocked}
            summary = f"unblocked {len(unblocked)} key(s)"
        if problems:
            summary += f"; {len(problems)} problem(s)"
        return _finish("release", level, gw, orc, actor, problems, detail, summary)


def enforce(gw) -> list[str]:
    """While tower holds level 1, blocks every open key but its own: added, unblocked elsewhere
    since, or not reachable when level 1 was engaged."""
    with _lock:
        if not _flag(LEVEL1_FLAG):
            return []
        problems = []
        blocked = _block_all(gw, problems)
        if isinstance(blocked, Unavailable):
            return []  # the state panel shows the gateway as unavailable
        if blocked or problems:
            summary = f"blocked {len(blocked)} key(s)" + (f"; {len(problems)} problem(s)" if problems else "")
            store.log("kill_switch", "loop", not problems, f"enforce level 1: {summary}",
                      {"action": "enforce", "level": 1, "blocked": blocked, "problems": problems})
        return blocked


def register(router, app):
    from tower import setup_view  # imported here: setup_view imports this module

    # A refusal answers 200, like checks: htmx 2 does not swap 4xx answers, so it would not be seen.
    def render(request, state, confirm=None, error=None):
        context = {
            "state": state,
            "confirm": confirm,
            "error": error,
            "tower_level1": _flag(LEVEL1_FLAG),
            "tower_level2": _level2_by_tower(),
        }
        return app.state.templates.TemplateResponse(
            request, "partials/killswitch.html", context)

    def clients():
        return app.state.gateway, app.state.openrouter

    def state():
        # Bound by the page deadline, so a hanging source never leaves the switch unrendered.
        return current_state(*clients(), end=setup_view.deadline())

    def check(level):
        if level not in (1, 2):
            raise HTTPException(status_code=404)

    @router.get("/partials/killswitch", response_class=HTMLResponse)
    def partial(request: Request, confirm: int | None = None):
        return render(request, state(), confirm if confirm in (1, 2) else None)

    @router.post("/kill/engage/{level}", response_class=HTMLResponse)
    def engage_route(request: Request, level: int, confirm: str = Form("")):
        check(level)
        if confirm != "yes":
            return render(request, state(), error="Nothing changed: confirm first.")
        return render(request, engage(level, *clients(), "owner"))

    @router.post("/kill/release/{level}", response_class=HTMLResponse)
    def release_route(request: Request, level: int, word: str = Form("")):
        check(level)
        if word != "release":
            return render(request, state(),
                          error='Nothing changed: type the word "release".')
        return render(request, release(level, *clients(), "owner"))
