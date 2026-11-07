"""Serve tower against the page tests' fakes, to look at it: `uv run python tests/preview.py`.

Then open http://127.0.0.1:8765 and log in with the password `look`. No loop, a temporary data
dir, made-up figures, nothing real is reached. Not imported by any test.
"""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent), str(HERE)]

import uvicorn  # noqa: E402

import test_pages as tp  # noqa: E402
from tower import store  # noqa: E402
from tower.app import create_app  # noqa: E402

tmp = Path(tempfile.mkdtemp(prefix="tower-preview-"))
config = tmp / "config"
config.mkdir()
(config / "config.yaml").symlink_to(tp.REPO / "gateway" / "config.yaml")
(config / "docker-compose.yml").symlink_to(tp.REPO / "docker-compose.yml")
store.init_db(tmp / "tower.db")

def rows():
    """Made-up usage over the last six weeks: four roles, two experiment names, three keys."""
    from datetime import timedelta

    today = tp.today()
    out = []
    #          name, key, calls, tokens in, tokens out, spend per day
    daily = [("classify", "node-red", 41, 4120, 824, 0.12), ("chat", "chat", 3, 300, 600, 0.05),
             ("summarise", "node-red", 4, 9800, 700, 0.02), ("code", "chat", 2, 200, 5200, 0.01),
             ("gpt-oss-120b@deepinfra", "bench", 6, 2000, 4000, 0.03),
             ("llama-3.1-8b-instruct@deepinfra", "bench", 9, 900, 300, 0.004)]
    for back in range(42):
        day = today - timedelta(days=back)
        scale = 1.0 + 0.4 * ((back * 7) % 5 - 2) / 2  # varies from day to day
        for name, key, calls, tin, tout, spend in daily:
            out.append(tp.UsageRow(day, name, key, max(1, round(calls * scale)), round(tin * scale),
                                   round(tout * scale), spend * scale))
    return out


env = {**tp.ENV, "TOWER_PASSWORD": "look", "TOWER_DATA_DIR": str(tmp)}
app = create_app(tp.make_settings(config, env), gateway=tp.FakeGateway(rows()),
                 openrouter=tp.FakeOpenRouter(), start_loop=False)
uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")
