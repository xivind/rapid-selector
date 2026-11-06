import json
from datetime import UTC, datetime
from pathlib import Path

from peewee import BooleanField, CharField, DatabaseProxy, Model, SqliteDatabase, TextField
from peewee import Field

db = DatabaseProxy()


class UTCDateTimeField(Field):
    """Stored as ISO 8601 text in UTC; always read back timezone-aware."""

    field_type = "TEXT"

    def db_value(self, value):
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("naive datetime; store UTC-aware values")
        return value.astimezone(UTC).isoformat()

    def python_value(self, value):
        if value is None:
            return None
        return datetime.fromisoformat(value).astimezone(UTC)


class _Base(Model):
    class Meta:
        database = db


class LogEntry(_Base):
    at = UTCDateTimeField(index=True)
    kind = CharField(index=True)  # kill_switch, price_check, smoke_test, balance
    actor = CharField()
    ok = BooleanField(null=True)
    summary = TextField()
    detail = TextField(default="{}")  # JSON


class BlockedKey(_Base):
    token_hash = CharField(primary_key=True)
    alias = CharField(null=True)
    blocked_at = UTCDateTimeField()


class Flag(_Base):
    name = CharField(primary_key=True)
    value = CharField()


def init_db(path: Path) -> None:
    database = SqliteDatabase(
        str(path), pragmas={"journal_mode": "wal", "busy_timeout": 5000}
    )
    db.initialize(database)
    database.connect(reuse_if_open=True)
    database.create_tables([LogEntry, BlockedKey, Flag])


def log(kind, actor, ok, summary, detail, at=None) -> LogEntry:
    return LogEntry.create(
        at=at or datetime.now(UTC),
        kind=kind,
        actor=actor,
        ok=ok,
        summary=summary,
        detail=json.dumps(detail),
    )


def latest(kind) -> LogEntry | None:
    return (
        LogEntry.select()
        .where(LogEntry.kind == kind)
        .order_by(LogEntry.at.desc(), LogEntry.id.desc())
        .first()
    )


def entries(limit=200) -> list[LogEntry]:
    return list(
        LogEntry.select().order_by(LogEntry.at.desc(), LogEntry.id.desc()).limit(limit)
    )
