#!/usr/bin/env bash
set -euo pipefail

# --- parse arguments
STATUS_MODE=false
STOP_MODE=false
DIR=""
MODE=""
SQL=""

for arg in "$@"; do
  if [[ "$arg" == "--status" ]]; then
    STATUS_MODE=true
  elif [[ "$arg" == "--stop" ]]; then
    STOP_MODE=true
  elif [[ -z "$DIR" ]]; then
    DIR="$arg"
  elif [[ -z "$MODE" ]]; then
    MODE="$arg"
  elif [[ -z "$SQL" ]]; then
    SQL="$arg"
  fi
done

# --- handle --status mode
if [[ "$STATUS_MODE" == true ]]; then
  if [[ -n "$DIR" ]]; then
    DIR="${DIR%/}"
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
      echo "$D: running"
    else
      echo "$D: stopped"
    fi
  done
  exit 0
fi

# --- handle --stop mode
if [[ "$STOP_MODE" == true ]]; then
  if [[ -z "$DIR" ]]; then
    echo "usage: pg.sh PATH --stop"
    exit 1
  fi
  DIR="${DIR%/}"
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

if [[ -z "$DIR" ]]; then
  echo "usage:"
  echo "  pg.sh PATH        start server and print connection info"
  echo "  pg.sh PATH/       start server and open shell"
  echo "  pg.sh PATH --stop stop server"
  echo "  pg.sh --status    show status of *.pgdb directories"
  exit 1
fi

# trailing slash means enter shell
SHELL_MODE=false
if [[ "$DIR" == */ ]]; then
  SHELL_MODE=true
  DIR="${DIR%/}"
fi

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

PGDATA="$DIR/pgdata"
SOCKDIR="$DIR/socket"
ENVFILE="$DIR/.env"
PORT_FILE="$DIR/PG_PORT"

mkdir -p "$SOCKDIR"

# --- initdb (first run only)
if [[ ! -d "$PGDATA" ]]; then
  echo "$ initdb -D $PGDATA --no-locale --encoding=UTF8"
  initdb -D "$PGDATA" --no-locale --encoding=UTF8
  echo
fi

# --- choose / persist port
if [[ ! -f "$PORT_FILE" ]]; then
  PORT=$(shuf -i 55000-59999 -n 1)
  echo "$PORT" > "$PORT_FILE"
  echo "Assigned port: $PORT"
else
  PORT=$(cat "$PORT_FILE")
fi

# --- start postgres if not running
if ! pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
  echo "$ pg_ctl -D $PGDATA -o \"-k $SOCKDIR -p $PORT -h ''\" start"
  pg_ctl -D "$PGDATA" \
    -o "-k $SOCKDIR -p $PORT -h ''" \
    start
  echo
else
  echo "Server already running"
fi

PG_URL="postgresql://localhost/postgres?host=$SOCKDIR&port=$PORT"

# --- write .env
cat > "$ENVFILE" <<EOF
PG_PORT=$PORT
PG_URL=$PG_URL
EOF

# --- shell mode (trailing slash or --shell flag)
if [[ "$SHELL_MODE" == true || "$MODE" == "--shell" ]]; then
  TABLES=$(psql "$PG_URL" -At -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';" 2>/dev/null)
  if [[ -n "$TABLES" ]]; then
    echo "Tables:"
    echo "$TABLES" | sed 's/^/  /'
    echo
  fi
  if [[ -n "$SQL" ]]; then
    psql "$PG_URL" -c "$SQL"
  fi
  echo "psql \"$PG_URL\""
  echo
  exec psql "$PG_URL"
fi

# --- normal output
echo "Postgres ready:"
echo "  PG_PORT=$PORT"
echo "  PG_URL=$PG_URL"
echo
echo "Python (psycopg3):"
cat <<EOF
import psycopg
conn = psycopg.connect("$PG_URL")
EOF
echo
echo "Shell:"
echo "  psql \"$PG_URL\""
