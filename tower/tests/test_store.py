import io
import sqlite3
from datetime import UTC, datetime, timedelta

import peewee
import pytest

from tower import backup, store


@pytest.fixture
def db(tmp_path):
    store.init_db(tmp_path / "tower.db")
    yield tmp_path
    store.db.close()


def test_log_and_latest(db):
    assert store.latest("balance") is None
    store.log("balance", "loop", True, "first", {"a": 1})
    second = store.log("balance", "loop", None, "second", {"b": 2})
    got = store.latest("balance")
    assert got.id == second.id
    assert got.summary == "second"
    assert got.ok is None
    assert got.at.tzinfo is not None
    assert store.latest("kill_switch") is None


def test_entries_newest_first(db):
    t0 = datetime(2026, 1, 1, tzinfo=UTC)
    for i in range(3):
        store.log("smoke_test", "owner", True, f"e{i}", {}, at=t0 + timedelta(minutes=i))
    assert [e.summary for e in store.entries()] == ["e2", "e1", "e0"]
    assert len(store.entries(limit=2)) == 2


def test_blocked_key_unique(db):
    store.BlockedKey.create(token_hash="h1", alias="a", blocked_at=datetime.now(UTC))
    with pytest.raises(peewee.IntegrityError):
        store.BlockedKey.create(token_hash="h1", alias="a", blocked_at=datetime.now(UTC))
    assert store.BlockedKey.select().count() == 1


def test_backup_is_a_valid_database(db):
    store.log("kill_switch", "owner", True, "marker row", {})
    buf = io.BytesIO()
    backup.main(out=buf, data_dir=db)
    copy = db / "copy.db"
    copy.write_bytes(buf.getvalue())
    con = sqlite3.connect(copy)
    assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert con.execute("SELECT summary FROM logentry").fetchone()[0] == "marker row"
    con.close()
