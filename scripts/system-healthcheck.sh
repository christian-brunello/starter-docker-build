#!/usr/bin/env bash
# Probe STARTER stack health and UPSERT results into STARTER.health_checks.
# Intended to run on the host via starter-healthcheck.timer.
set -euo pipefail

STARTER_NAME="${STARTER_CONTAINER_NAME:-starter}"
MYSQL_NAME="${MYSQL_CONTAINER_NAME:-mysql-server}"
PULSE_UID="${STARTER_PULSE_UID:-1000}"
PULSE_DIR="${STARTER_PULSE_RUNTIME_DIR:-/run/user/${PULSE_UID}/pulse}"

# Accumulated SQL value tuples: ('check_id','category','display',ok,'msg',sort)
ROWS=()

sql_escape() {
    # Escape single quotes for MySQL string literals.
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\'/\'\'}
    printf '%s' "$s"
}

add_row() {
    local check_id=$1 category=$2 display=$3 ok=$4 message=$5 sort_order=$6
    ROWS+=("('$(sql_escape "$check_id")','$(sql_escape "$category")','$(sql_escape "$display")',${ok},'$(sql_escape "$message")',${sort_order})")
}

unit_active() {
    local unit=$1
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        return 0
    fi
    return 1
}

container_running() {
    local name=$1
    local state
    state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo missing)
    [[ "$state" == "true" ]]
}

check_unit() {
    local check_id=$1 display=$2 unit=$3 sort_order=$4
    if unit_active "$unit"; then
        add_row "$check_id" system "$display" 1 "active" "$sort_order"
    else
        local st
        st=$(systemctl is-active "$unit" 2>/dev/null || echo missing)
        add_row "$check_id" system "$display" 0 "${st}" "$sort_order"
    fi
}

check_container() {
    local check_id=$1 display=$2 name=$3 sort_order=$4
    if container_running "$name"; then
        add_row "$check_id" system "$display" 1 "running" "$sort_order"
    else
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
        add_row "$check_id" system "$display" 0 "${state}" "$sort_order"
    fi
}

check_http() {
    local check_id=$1 category=$2 display=$3 url=$4 sort_order=$5
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
        add_row "$check_id" "$category" "$display" 1 "ok" "$sort_order"
    else
        add_row "$check_id" "$category" "$display" 0 "unreachable" "$sort_order"
    fi
}

check_port_listen() {
    local check_id=$1 category=$2 display=$3 port=$4 sort_order=$5
    if ss -ltn 2>/dev/null | grep -qE ":${port}\\b"; then
        add_row "$check_id" "$category" "$display" 1 "listening :${port}" "$sort_order"
    else
        add_row "$check_id" "$category" "$display" 0 "not listening :${port}" "$sort_order"
    fi
}

# --- probes ---

check_unit unit-starter-docker "unit starter-docker" starter-docker.service 10
check_unit unit-mysql-server "unit mysql-server" mysql-server.service 11
check_unit unit-explain-stack "unit explain-stack" explain-stack.service 12

check_container ctr-starter "container starter" "$STARTER_NAME" 20
check_container ctr-mysql "container mysql-server" "$MYSQL_NAME" 21
check_container ctr-ollama "container ollama" ollama 22
check_container ctr-piper "container piper_tts" piper_tts 23
check_container ctr-explain "container explain_service" explain_service 24
check_container ctr-grafana "container grafana" grafana 25

# MySQL ping
if container_running "$MYSQL_NAME"; then
    if docker exec "$MYSQL_NAME" mysqladmin ping -h127.0.0.1 --silent >/dev/null 2>&1 \
        || docker exec "$MYSQL_NAME" mysqladmin ping --silent >/dev/null 2>&1; then
        add_row mysql core "MySQL ping" 1 "pong" 40
    else
        add_row mysql core "MySQL ping" 0 "ping failed" 40
    fi
else
    add_row mysql core "MySQL ping" 0 "container missing" 40
fi

# Supervisord programs inside starter (runtime conf under /run/starter).
# Conf appears only after container-main settles — retry briefly across restarts.
SUPERVISOR_CONF=/run/starter/supervisord.conf
if container_running "$STARTER_NAME"; then
    sort_base=50
    sup_out=""
    for _try in 1 2 3 4 5 6; do
        if docker exec "$STARTER_NAME" test -f "$SUPERVISOR_CONF" 2>/dev/null; then
            sup_out=$(docker exec "$STARTER_NAME" supervisorctl -c "$SUPERVISOR_CONF" status 2>&1 || true)
            break
        fi
        sleep 2
    done
    if [[ -z "$sup_out" ]]; then
        sup_out=$(docker exec "$STARTER_NAME" supervisorctl -c "$SUPERVISOR_CONF" status 2>&1 || true)
    fi
    if ! grep -qE '^[A-Za-z0-9_.-]+[[:space:]]+(RUNNING|STOPPED|STARTING|FATAL|EXITED|BACKOFF|UNKNOWN)' <<<"$sup_out"; then
        add_row sup-ctl core "supervisord" 0 "$(tr '\n' ' ' <<<"$sup_out" | head -c 120)" 49
    else
        # Clear transient "missing conf" row from earlier probes in the same table.
        add_row sup-ctl core "supervisord" 1 "ok" 49
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # supervisorctl status: NAME STATE ...
            name=$(awk '{print $1}' <<<"$line")
            state=$(awk '{print $2}' <<<"$line")
            [[ -z "$name" || -z "$state" ]] && continue
            case "$state" in
                RUNNING|STOPPED|STARTING|FATAL|EXITED|BACKOFF|UNKNOWN) ;;
                *) continue ;;
            esac
            category=services
            case "$name" in
                starter-core|st-core|core) category=core ;;
                *adapter*) category=adapters ;;
                st-explain|explain*) category=services ;;
            esac
            ok=0
            [[ "$state" == "RUNNING" ]] && ok=1
            add_row "sup-${name}" "$category" "supervisord ${name}" "$ok" "${state}" "$sort_base"
            sort_base=$((sort_base + 1))
        done <<<"$sup_out"
    fi
else
    add_row sup-missing core "supervisord" 0 "starter container missing" 49
fi

check_http ollama llm "Ollama API" "http://127.0.0.1:11434/api/tags" 100
check_http rag rag "Explain / RAG API" "http://127.0.0.1:5001/openapi.json" 110
check_port_listen piper audio "Piper TTS :5005" 5005 120

# Pulse runtime dir mode
if [[ -d "$PULSE_DIR" ]]; then
    mode=$(stat -c '%a' "$PULSE_DIR" 2>/dev/null || echo unknown)
    if [[ "$mode" == "755" ]]; then
        add_row pulse audio "Pulse runtime dir" 1 "mode ${mode}" 130
    else
        add_row pulse audio "Pulse runtime dir" 0 "mode ${mode} (want 755)" 130
    fi
else
    add_row pulse audio "Pulse runtime dir" 0 "missing ${PULSE_DIR}" 130
fi

check_http grafana ui "Grafana /api/health" "http://127.0.0.1:3000/api/health" 140

if [[ ${#ROWS[@]} -eq 0 ]]; then
    echo "error: no health rows collected" >&2
    exit 1
fi

# --- write to MySQL ---

if ! container_running "$STARTER_NAME"; then
    echo "error: starter container not running; cannot read db-credentials" >&2
    exit 1
fi
if ! container_running "$MYSQL_NAME"; then
    echo "error: mysql-server container not running" >&2
    exit 1
fi

CRED=$(docker exec "$STARTER_NAME" cat /usr/local/etc/starter/db-credentials)
WRITER_USER=$(sed -n 's/^DB_WRITER_USER=//p' <<<"$CRED")
WRITER_PASS=$(sed -n 's/^DB_WRITER_PASS=//p' <<<"$CRED")
WRITER_USER=${WRITER_USER:-STWriter}

if [[ -z "$WRITER_PASS" ]]; then
    echo "error: DB_WRITER_PASS missing in db-credentials" >&2
    exit 1
fi

values=$(IFS=,; echo "${ROWS[*]}")

# Snapshot semantics: drop check_ids not present in this run (e.g. stale
# sup-ctl from a mid-restart probe, or removed supervisord programs).
keep_ids=()
for tuple in "${ROWS[@]}"; do
    # tuple starts with ('check_id',...
    id=${tuple#\(}
    id=${id#\'}
    id=${id%%\'*}
    keep_ids+=("'$(sql_escape "$id")'")
done
keep_list=$(IFS=,; echo "${keep_ids[*]}")

sql=$(cat <<EOF
INSERT INTO health_checks (check_id, category, display_name, ok, message, sort_order)
VALUES ${values}
ON DUPLICATE KEY UPDATE
  category = VALUES(category),
  display_name = VALUES(display_name),
  ok = VALUES(ok),
  message = VALUES(message),
  sort_order = VALUES(sort_order),
  checked_at = CURRENT_TIMESTAMP;
DELETE FROM health_checks WHERE check_id NOT IN (${keep_list});
EOF
)

docker exec -e "MYSQL_PWD=${WRITER_PASS}" "$MYSQL_NAME" \
    mysql -u"${WRITER_USER}" STARTER -e "$sql"

echo "health_checks updated (${#ROWS[@]} rows)"
