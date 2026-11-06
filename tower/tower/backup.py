"""Write a consistent copy of tower.db to stdout: python -m tower.backup > tower.db"""

import os
import sqlite3
import sys
import tempfile
from pathlib import Path


def main(out=None, data_dir=None) -> None:
    out = out if out is not None else sys.stdout.buffer
    data_dir = Path(data_dir or os.environ.get("TOWER_DATA_DIR", "/data"))
    source = sqlite3.connect(f"file:{data_dir / 'tower.db'}?mode=ro", uri=True)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            copy_path = Path(tmp) / "copy.db"
            target = sqlite3.connect(copy_path)
            try:
                source.backup(target)
            finally:
                target.close()
            out.write(copy_path.read_bytes())
    finally:
        source.close()
    out.flush()


if __name__ == "__main__":
    main()
