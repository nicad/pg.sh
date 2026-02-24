#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  echo "pg.sh - local PostgreSQL server manager"
  echo
  echo "Usage:"
  echo "  pg.sh [PATH] [ARGS]   start server and open psql (extra args passed to psql)"
  echo "  pg.sh create PATH     create a new database"
  echo "  pg.sh start [PATH]    start server (no shell)"
  echo "  pg.sh stop [PATH]     stop server"
  echo "  pg.sh status [PATH]   show status and connection info"
  echo "  pg.sh help            show this help"
  echo
  echo "PATH can be 'mydb' or 'mydb.pgdb' (the .pgdb suffix is added automatically)."
  echo "When PATH is omitted, uses the single *.pgdb directory in the current folder."
  echo
  echo "Examples:"
  echo "  pg.sh create mydb     # create mydb.pgdb"
  echo "  pg.sh mydb            # open psql shell"
  echo "  pg.sh                 # open psql shell (auto-detect *.pgdb)"
  echo "  pg.sh stop mydb"
  echo "  pg.sh status"
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

normalize_dir() {
  local d="$1"
  d="${d%/}"
  if [[ "$d" != *.pgdb ]]; then
    d="$d.pgdb"
  fi
  echo "$d"
}

auto_detect_dir() {
  shopt -s nullglob
  local dirs=(*.pgdb)
  shopt -u nullglob

  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "error: no .pgdb directory found in current folder" >&2
    echo "hint: use 'pg.sh create NAME' to create one" >&2
    exit 1
  elif [[ ${#dirs[@]} -gt 1 ]]; then
    echo "error: multiple .pgdb directories found:" >&2
    printf "  %s\n" "${dirs[@]}" >&2
    echo "hint: specify which one, e.g. 'pg.sh ${dirs[0]%%.pgdb}'" >&2
    exit 1
  fi
  echo "${dirs[0]}"
}

resolve_dir() {
  if [[ -n "${1:-}" ]]; then
    normalize_dir "$1"
  else
    auto_detect_dir
  fi
}

ensure_running() {
  local dir="$1"
  local pgdata="$dir/pgdata"
  local sockdir="$dir/socket"
  local port_file="$dir/PG_PORT"

  if [[ ! -d "$pgdata" ]]; then
    echo "error: $dir is not initialized (missing pgdata)" >&2
    exit 1
  fi

  mkdir -p "$sockdir"

  if [[ ! -f "$port_file" ]]; then
    echo "error: $dir is missing PG_PORT file" >&2
    exit 1
  fi
  local port
  port=$(cat "$port_file")

  if ! pg_ctl -D "$pgdata" status > /dev/null 2>&1; then
    echo "$ pg_ctl -D $pgdata -o \"-k $sockdir -p $port -h ''\" start"
    pg_ctl -D "$pgdata" \
      -o "-k $sockdir -p $port -h ''" \
      start
    echo
  fi
}

pg_url() {
  local dir="$1"
  local port
  port=$(cat "$dir/PG_PORT")
  echo "postgresql://localhost/postgres?host=$dir/socket&port=$port"
}

write_env() {
  local dir="$1"
  local port
  port=$(cat "$dir/PG_PORT")
  local url
  url=$(pg_url "$dir")
  cat > "$dir/.env" <<EOF
PG_PORT=$port
PG_URL=$url
EOF
}

# --- parse action
ACTION=""
case "${1:-}" in
  create)  ACTION=create;  shift ;;
  start)   ACTION=start;   shift ;;
  stop)    ACTION=stop;     shift ;;
  status)  ACTION=status;   shift ;;
  help|-h|--help) print_usage; exit 0 ;;
esac

DIR=""
if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  DIR="$1"
  shift
fi
PSQL_ARGS=("$@")

# --- create
if [[ "$ACTION" == "create" ]]; then
  if [[ -z "$DIR" ]]; then
    echo "error: PATH is required for create" >&2
    echo "usage: pg.sh create PATH" >&2
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

  write_env "$DIR"

  PID=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || echo "?")
  echo "Created $DIR (PID: $PID)"
  echo
  print_connection_info "$(pg_url "$DIR")"
  exit 0
fi

# --- status
if [[ "$ACTION" == "status" ]]; then
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
        echo "  pg.sh stop ${D%%.pgdb}"
      fi
    else
      echo "$D: stopped"
      echo
      echo "Start:"
      echo "  pg.sh ${D%%.pgdb}"
    fi
  done
  exit 0
fi

# --- stop
if [[ "$ACTION" == "stop" ]]; then
  DIR="$(resolve_dir "$DIR")"
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

# --- start (no shell)
if [[ "$ACTION" == "start" ]]; then
  DIR="$(resolve_dir "$DIR")"

  if [[ ! -d "$DIR" ]]; then
    echo "error: $DIR does not exist" >&2
    echo "hint: use 'pg.sh create ${DIR%%.pgdb}' to create it" >&2
    exit 1
  fi

  DIR="$(cd "$DIR" && pwd)"
  ensure_running "$DIR"
  write_env "$DIR"

  URL="$(pg_url "$DIR")"
  echo "Postgres ready:"
  echo "  PG_URL=$URL"
  echo
  print_connection_info "$URL"
  exit 0
fi

# --- default: open psql shell
DIR="$(resolve_dir "$DIR")"

if [[ ! -d "$DIR" ]]; then
  echo "error: $DIR does not exist" >&2
  echo "hint: use 'pg.sh create ${DIR%%.pgdb}' to create it" >&2
  exit 1
fi

DIR="$(cd "$DIR" && pwd)"
ensure_running "$DIR"
write_env "$DIR"

URL="$(pg_url "$DIR")"

if [[ ${#PSQL_ARGS[@]} -eq 0 && -t 0 ]]; then
  TABLES=$(psql "$URL" -At -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null)
  if [[ -n "$TABLES" ]]; then
    echo "Tables:"
    echo "$TABLES" | sed 's/^/  /'
    echo
  fi
  echo "psql \"$URL\""
  echo
fi
exec psql "$URL" "${PSQL_ARGS[@]}"
