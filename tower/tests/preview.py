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

env = {**tp.ENV, "TOWER_PASSWORD": "look", "TOWER_DATA_DIR": str(tmp)}
app = create_app(tp.make_settings(config, env), gateway=tp.FakeGateway(),
                 openrouter=tp.FakeOpenRouter(), start_loop=False)
uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")
