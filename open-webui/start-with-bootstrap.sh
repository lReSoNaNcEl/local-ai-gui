#!/usr/bin/env bash
set -euo pipefail

readonly READY_FILE="/tmp/local-ai-open-webui-ready"
rm -f "$READY_FILE"

cd /app/backend
bash start.sh "$@" &
webui_pid=$!

forward_signal() {
  kill -s "$1" "$webui_pid" 2>/dev/null || true
}

trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

until curl --silent --fail "http://localhost:${PORT:-8080}/health" >/dev/null; do
  if ! kill -0 "$webui_pid" 2>/dev/null; then
    wait "$webui_pid"
    exit $?
  fi
  sleep 1
done

if ! python /opt/local-ai/bootstrap.py; then
  echo "Open WebUI customization bootstrap failed; stopping the container." >&2
  kill -TERM "$webui_pid" 2>/dev/null || true
  wait "$webui_pid" 2>/dev/null || true
  exit 1
fi

touch "$READY_FILE"

set +e
wait "$webui_pid"
status=$?
set -e
rm -f "$READY_FILE"
exit "$status"
