"""Read-only MCP serve mode.

Covers the contract that lets multiple MCP servers (distinct ``--config`` files)
serve prebuilt indexes over one workspace without colliding on the shared
watchman runtime or taking a DuckDB write lock:

- ``database.read_only`` resolves from config object, env, and CLI.
- The DuckDB connection manager opens read-only, allows a concurrent second
  reader, and refuses writes.
"""

import argparse
from types import SimpleNamespace

import duckdb
import pytest

from chunkhound.api.cli.parsers.mcp_parser import add_mcp_subparser
from chunkhound.core.config.database_config import DatabaseConfig
from chunkhound.providers.database.duckdb.connection_manager import (
    DuckDBConnectionManager,
)


# --- config resolution -----------------------------------------------------


def test_read_only_defaults_false():
    assert DatabaseConfig().read_only is False


def test_read_only_from_config_object():
    assert DatabaseConfig(read_only=True).read_only is True


@pytest.mark.parametrize(
    "value,expected",
    [
        ("true", True),
        ("1", True),
        ("yes", True),
        ("on", True),
        ("false", False),
        ("0", False),
        ("", False),
    ],
)
def test_read_only_from_env(monkeypatch, value, expected):
    monkeypatch.setenv("CHUNKHOUND_DATABASE__READ_ONLY", value)
    assert DatabaseConfig.load_from_env().get("read_only", False) is expected


def test_read_only_cli_override():
    assert (
        DatabaseConfig.extract_cli_overrides(
            SimpleNamespace(read_only=True)
        ).get("read_only")
        is True
    )
    # Absence must not force read_only=False over a config-file/env value.
    assert "read_only" not in DatabaseConfig.extract_cli_overrides(
        SimpleNamespace(read_only=False)
    )


def test_mcp_parser_exposes_read_only_flag():
    parser = argparse.ArgumentParser()
    add_mcp_subparser(parser.add_subparsers(dest="command"))
    assert parser.parse_args(["mcp", "--read-only"]).read_only is True
    assert parser.parse_args(["mcp"]).read_only is False


def test_connection_manager_resolves_env(monkeypatch):
    monkeypatch.setenv("CHUNKHOUND_DATABASE__READ_ONLY", "true")
    assert DuckDBConnectionManager._resolve_read_only(None) is True
    monkeypatch.delenv("CHUNKHOUND_DATABASE__READ_ONLY", raising=False)
    assert DuckDBConnectionManager._resolve_read_only(None) is False


# --- read-only DuckDB connection behavior ----------------------------------


def _seed_db(path) -> None:
    """Create a small DB read-write and close it cleanly (checkpoints WAL)."""
    conn = duckdb.connect(str(path))
    conn.execute("CREATE TABLE t(id INTEGER)")
    conn.execute("INSERT INTO t VALUES (1), (2), (3)")
    conn.close()


def test_read_only_connect_and_query(tmp_path):
    db = tmp_path / "chunks.db"
    _seed_db(db)
    cm = DuckDBConnectionManager(db, DatabaseConfig(read_only=True))
    cm.connect()
    try:
        assert cm.read_only is True
        assert cm.connection.execute("SELECT count(*) FROM t").fetchone()[0] == 3
    finally:
        cm.connection.close()


def test_two_read_only_managers_coexist(tmp_path):
    db = tmp_path / "chunks.db"
    _seed_db(db)
    a = DuckDBConnectionManager(db, DatabaseConfig(read_only=True))
    b = DuckDBConnectionManager(db, DatabaseConfig(read_only=True))
    a.connect()
    b.connect()
    try:
        assert a.connection.execute("SELECT count(*) FROM t").fetchone()[0] == 3
        assert b.connection.execute("SELECT count(*) FROM t").fetchone()[0] == 3
    finally:
        a.connection.close()
        b.connection.close()


def test_read_only_refuses_writes(tmp_path):
    db = tmp_path / "chunks.db"
    _seed_db(db)
    cm = DuckDBConnectionManager(db, DatabaseConfig(read_only=True))
    cm.connect()
    try:
        with pytest.raises(duckdb.Error):
            cm.connection.execute("INSERT INTO t VALUES (99)")
    finally:
        cm.connection.close()


def test_read_only_provider_connect_skips_schema_creation(tmp_path):
    """Regression: read-only provider.connect() must NOT run schema/index DDL.

    The executor connect path creates schema + indexes; on a read-only DuckDB
    connection those CREATE statements raise and crash MCP startup. Read-only
    serves a prebuilt DB, so connect must skip executor-side initialization.
    """
    from chunkhound.providers.database.duckdb_provider import DuckDBProvider

    db = tmp_path / "chunks.db"
    rw = DuckDBProvider(
        db, tmp_path, config=DatabaseConfig(provider="duckdb", path=db)
    )
    rw.connect()  # builds schema read-write
    rw.close()

    ro = DuckDBProvider(
        db,
        tmp_path,
        config=DatabaseConfig(provider="duckdb", path=db, read_only=True),
    )
    ro.connect()  # would raise "CREATE ... in read-only mode" without the skip
    try:
        assert ro.is_connected
        assert ro._connection_manager.read_only is True
        # schema is present and queryable (created by the read-write open)
        ro.connection.execute("SELECT count(*) FROM files").fetchone()
    finally:
        ro.close()
