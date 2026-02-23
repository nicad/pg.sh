#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  echo "pg.sh - local PostgreSQL server manager"
  echo
  echo "Usage:"
  echo "  pg.sh [PATH]            start server and open psql shell"
  echo "  pg.sh PATH --create     create a new database"
  echo "  pg.sh [PATH] --stop     stop server"
  echo "  pg.sh [PATH] --status   show status"
  echo "  pg.sh -h|--help         show this help"
  echo
  echo "PATH can be 'mydb' or 'mydb.pgdb' (the .pgdb suffix is added automatically)."
  echo "When PATH is omitted, uses the single *.pgdb directory in the current folder."
  echo
  echo "Examples:"
  echo "  pg.sh mydb --create     # create mydb.pgdb"
  echo "  pg.sh mydb              # open psql shell"
  echo "  pg.sh                   # open psql shell (auto-detect *.pgdb)"
  echo "  pg.sh mydb --stop"
  echo "  pg.sh --status"
}

print_connection_info() {
  local url="$1"
  echo "Python (psycopg3):"
  echo "import psycopg"
  echo "conn = psycopg.connect(\"$url\")"
  echo
  echo "Shell:"
  echo "  psql \"$url\""
}

# Normalize PATH: strip trailing slash, append .pgdb if missing
normalize_dir() {
  local d="$1"
  d="${d%/}"
  if [[ "$d" != *.pgdb ]]; then
    d="$d.pgdb"
  fi
  echo "$d"
}

# Auto-detect a single *.pgdb directory in the current folder
auto_detect_dir() {
  shopt -s nullglob
  local dirs=(*.pgdb)
  shopt -u nullglob

  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "error: no .pgdb directory found in current folder" >&2
    echo "hint: use 'pg.sh NAME --create' to create one" >&2
    exit 1
  elif [[ ${#dirs[@]} -gt 1 ]]; then
    echo "error: multiple .pgdb directories found:" >&2
    printf "  %s\n" "${dirs[@]}" >&2
    echo "hint: specify which one, e.g. 'pg.sh ${dirs[0]%%.pgdb}'" >&2
    exit 1
  fi
  echo "${dirs[0]}"
}

# --- parse arguments
STATUS_MODE=false
STOP_MODE=false
CREATE_MODE=false
DIR=""

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    print_usage
    exit 0
  elif [[ "$arg" == "--status" ]]; then
    STATUS_MODE=true
  elif [[ "$arg" == "--stop" ]]; then
    STOP_MODE=true
  elif [[ "$arg" == "--create" ]]; then
    CREATE_MODE=true
  elif [[ -z "$DIR" ]]; then
    DIR="$arg"
  fi
done

# --- handle --status mode
if [[ "$STATUS_MODE" == true ]]; then
  if [[ -n "$DIR" ]]; then
    DIR="$(normalize_dir "$DIR")"
    DIRS=("$DIR")
  else
    shopt -s nullglob
    DIRS=(*.pgdb)
    shopt -u nullglob
  fi

  if [[ ${#DIRS[@]} -eq 0 ]]; then
    echo "No .pgdb directories found"
    exit 1
  fi

  for D in "${DIRS[@]}"; do
    D="${D%/}"
    PGDATA="$D/pgdata"

    if [[ ! -d "$D" ]]; then
      echo "$D: does not exist"
    elif [[ ! -d "$PGDATA" ]]; then
      echo "$D: not initialized"
    elif pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
      D_ABS="$(cd "$D" && pwd)"
      PID=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || echo "?")
      echo "$D: running (PID: $PID)"
      PORT_FILE="$D_ABS/PG_PORT"
      if [[ -f "$PORT_FILE" ]]; then
        PORT=$(cat "$PORT_FILE")
        PG_URL="postgresql://localhost/postgres?host=$D_ABS/socket&port=$PORT"
        echo
        print_connection_info "$PG_URL"
        echo
        echo "Stop:"
        echo "  $0 $D --stop"
      fi
    else
      echo "$D: stopped"
      echo
      echo "Start:"
      echo "  $0 ${D%%.pgdb}"
    fi
  done
  exit 0
fi

# --- handle --stop mode
if [[ "$STOP_MODE" == true ]]; then
  if [[ -n "$DIR" ]]; then
    DIR="$(normalize_dir "$DIR")"
  else
    DIR="$(auto_detect_dir)"
  fi
  PGDATA="$DIR/pgdata"

  if [[ ! -d "$PGDATA" ]]; then
    echo "$DIR: not initialized"
    exit 1
  fi

  if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
    echo "$ pg_ctl -D $PGDATA stop"
    pg_ctl -D "$PGDATA" stop
  else
    echo "$DIR: not running"
  fi
  exit 0
fi

# --- handle --create mode
if [[ "$CREATE_MODE" == true ]]; then
  if [[ -z "$DIR" ]]; then
    echo "error: PATH is required for --create" >&2
    echo "usage: pg.sh PATH --create" >&2
    exit 1
  fi
  DIR="$(normalize_dir "$DIR")"

  if [[ -d "$DIR" ]]; then
    echo "error: $DIR already exists" >&2
    exit 1
  fi

  mkdir -p "$DIR"
  DIR="$(cd "$DIR" && pwd)"

  PGDATA="$DIR/pgdata"
  SOCKDIR="$DIR/socket"
  ENVFILE="$DIR/.env"
  PORT_FILE="$DIR/PG_PORT"

  mkdir -p "$SOCKDIR"

  echo "$ initdb -D $PGDATA --no-locale --encoding=UTF8"
  initdb -D "$PGDATA" --no-locale --encoding=UTF8
  echo

  PORT=$(shuf -i 55000-59999 -n 1)
  echo "$PORT" > "$PORT_FILE"
  echo "Assigned port: $PORT"

  echo "$ pg_ctl -D $PGDATA -o \"-k $SOCKDIR -p $PORT -h ''\" start"
  pg_ctl -D "$PGDATA" \
    -o "-k $SOCKDIR -p $PORT -h ''" \
    start
  echo

  PG_URL="postgresql://localhost/postgres?host=$SOCKDIR&port=$PORT"

  cat > "$ENVFILE" <<EOF
PG_PORT=$PORT
PG_URL=$PG_URL
EOF

  PID=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || echo "?")
  echo "Created $DIR (PID: $PID)"
  echo
  print_connection_info "$PG_URL"
  exit 0
fi

# --- default: open psql shell
if [[ -n "$DIR" ]]; then
  DIR="$(normalize_dir "$DIR")"
else
  DIR="$(auto_detect_dir)"
fi

if [[ ! -d "$DIR" ]]; then
  echo "error: $DIR does not exist" >&2
  echo "hint: use 'pg.sh ${DIR%%.pgdb} --create' to create it" >&2
  exit 1
fi

DIR="$(cd "$DIR" && pwd)"

PGDATA="$DIR/pgdata"
SOCKDIR="$DIR/socket"
ENVFILE="$DIR/.env"
PORT_FILE="$DIR/PG_PORT"

if [[ ! -d "$PGDATA" ]]; then
  echo "error: $DIR is not initialized (missing pgdata)" >&2
  exit 1
fi

mkdir -p "$SOCKDIR"

# read port
if [[ ! -f "$PORT_FILE" ]]; then
  echo "error: $DIR is missing PG_PORT file" >&2
  exit 1
fi
PORT=$(cat "$PORT_FILE")

# start postgres if not running
if ! pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
  echo "$ pg_ctl -D $PGDATA -o \"-k $SOCKDIR -p $PORT -h ''\" start"
  pg_ctl -D "$PGDATA" \
    -o "-k $SOCKDIR -p $PORT -h ''" \
    start
  echo
fi

PG_URL="postgresql://localhost/postgres?host=$SOCKDIR&port=$PORT"

cat > "$ENVFILE" <<EOF
PG_PORT=$PORT
PG_URL=$PG_URL
EOF

TABLES=$(psql "$PG_URL" -At -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null)
if [[ -n "$TABLES" ]]; then
  echo "Tables:"
  echo "$TABLES" | sed 's/^/  /'
  echo
fi
echo "psql \"$PG_URL\""
echo
exec psql "$PG_URL"
