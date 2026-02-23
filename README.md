# pg.sh

A single-file bash script for managing local PostgreSQL databases. Each database lives in a self-contained `.pgdb` directory with its own data, socket, and port — no system-wide PostgreSQL installation or configuration needed beyond having `pg_ctl` and `psql` on your PATH.

## Usage

```
pg.sh PATH --create     Create a new database
pg.sh [PATH]            Open psql shell (starts server if needed)
pg.sh [PATH] --stop     Stop the server
pg.sh [PATH] --status   Show server status and connection info
pg.sh --help            Show help
```

PATH can be `mydb` or `mydb.pgdb` (the `.pgdb` suffix is added automatically). When omitted, the single `*.pgdb` directory in the current folder is used.

## Examples

```bash
pg.sh mydb --create   # creates mydb.pgdb/, initializes and starts postgres
pg.sh mydb            # opens psql shell, lists tables
pg.sh                 # same, auto-detects mydb.pgdb/
pg.sh mydb --stop     # stops the server
pg.sh --status        # shows status of all *.pgdb dirs
```

## How it works

Each `.pgdb` directory contains:
- `pgdata/` — PostgreSQL data directory
- `socket/` — Unix domain socket (no TCP)
- `PG_PORT` — assigned port number
- `.env` — connection details (`PG_PORT`, `PG_URL`)

Databases listen only on a Unix socket with a random port, so multiple instances can coexist without conflict.
