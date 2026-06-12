########################## log.sh

#!/usr/bin/env bash

json_escape() {
  echo "${1:-}" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g'
}

log_json() {
  local level="$1"
  local message="$2"

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"script\":\"$(basename "$0")\",\"correlationId\":\"${CORRELATION_ID:-N/A}\",\"message\":\"$(json_escape "$message")\"}"
}

log() {
  log_json "INFO" "$1"
}

warn() {
  log_json "WARN" "$1" >&2
}

error() {
  log_json "ERROR" "$1" >&2
}

##########################  run.sh

#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

case "${ASPNETCORE_ENVIRONMENT^^}" in
    DEV|INT|UAT)
        KEYCLOAK_ENVIRONMENT="staging"
        ;;
    PROD)
        KEYCLOAK_ENVIRONMENT="production"
        ;;
    *)
        error "[run] Unsupported ASPNETCORE_ENVIRONMENT: ${ASPNETCORE_ENVIRONMENT}"
        exit 1
        ;;
esac

log "[run] Starting watchers. env=${KEYCLOAK_ENVIRONMENT}
LOGS_ROOT="${SCRIPT_DIR}/../log"
OUTPUT_ROOT="${SCRIPT_DIR}/../output"

log "[run] logsRoot=$LOGS_ROOT"
log "[run] outputRoot=$OUTPUT_ROOT"

./watcher_demand.sh "/share/demands" "$KEYCLOAK_ENVIRONMENT" &
pid_demand=$!

./watcher_files.sh "/share/logs" "$LOGS_ROOT" &
pid_logs=$!

./watcher_files.sh "/share/output" "$OUTPUT_ROOT" &
pid_output=$!

cleanup() {
  warn "[run] Stop requested. Stopping watchers."

  kill "$pid_demand" "$pid_logs" "$pid_output" 2>/dev/null || true
  wait 2>/dev/null || true

  warn "[run] Watchers stopped."
}

trap cleanup INT TERM

wait -n

error "[run] One watcher stopped. Exiting..."
cleanup
exit 1

########################## watcher_demand.sh

#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <path_xlsx> <env>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

INCOMING_PATH="$1"
ENV="$2"
CURRENT_DIR="$(pwd)"
INTERVAL="${INTERVAL:-5}"

log "[watch_incoming] Watching: $INCOMING_PATH"
log "[watch_incoming] Current directory: $CURRENT_DIR"
log "[watch_incoming] Interval: ${INTERVAL}s"

is_file_stable() {
  local file="$1"
  local size1
  local size2

  size1="$(stat -c%s "$file" 2>/dev/null || echo -1)"
  sleep 1
  size2="$(stat -c%s "$file" 2>/dev/null || echo -2)"

  [ "$size1" = "$size2" ] && [ "$size1" -gt 0 ]
}

while true; do
  for file in "$INCOMING_PATH"/*.xls "$INCOMING_PATH"/*.xlsx; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue

    filename="$(basename "$file")"
    export CORRELATION_ID="${filename%.*}"

    log "[watch_incoming] Nouveau fichier détecté: $filename"

    if ! is_file_stable "$file"; then
      warn "[watch_incoming] Fichier non stable, traitement reporté: $filename"
      unset CORRELATION_ID
      continue
    fi

    log "[watch_incoming] Fichier stable, lancement executor: $filename"

    if ./executor.sh "$file" "$ENV"; then
      if ./move.sh "$file" "/share/processed"; then
        log "[watch_incoming] Fichier déplacé vers /share/processed: $filename"
      else
        exit_code="$?"
        error "[watch_incoming] Erreur déplacement vers /share/processed: $filename exitCode=$exit_code"
      fi
    else
      exit_code="$?"
      error "[watch_incoming] Erreur traitement fichier: $filename exitCode=$exit_code"
    fi

    unset CORRELATION_ID
  done

  sleep "$INTERVAL"
done

########################## watcher_files.sh

#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <shared_root> <files_root>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

SHARED_ROOT="$1"
FILES_ROOT="$2"
INTERVAL="${INTERVAL:-5}"

log "[watch_files] Watching logs in: $FILES_ROOT"
log "[watch_files] Shared root: $SHARED_ROOT"
log "[watch_files] Interval: ${INTERVAL}s"

is_file_stable() {
  local file="$1"
  local size1
  local size2

  size1="$(stat -c%s "$file" 2>/dev/null || echo -1)"
  sleep 1
  size2="$(stat -c%s "$file" 2>/dev/null || echo -2)"

  [ "$size1" = "$size2" ] && [ "$size1" -gt 0 ]
}

while true; do
  for file in "${FILES_ROOT}"/*/*; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue

    service_dir="$(basename "$(dirname "$file")")"
    filename="$(basename "$file")"

    export CORRELATION_ID="${filename%.*}"

    log "[watch_files] Fichier détecté: service=$service_dir fichier=$filename"

    if ! is_file_stable "$file"; then
      warn "[watch_files] Fichier non stable, déplacement reporté: $filename"
      unset CORRELATION_ID
      continue
    fi

    if ./move.sh "$file" "$SHARED_ROOT"; then
      log "[watch_files] Déplacé vers: $SHARED_ROOT/$filename"
    else
      exit_code="$?"
      error "[watch_files] Erreur déplacement: $file exitCode=$exit_code"
    fi

    unset CORRELATION_ID
  done

  sleep "$INTERVAL"
done

########################## move.sh

#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <source> <destination>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

SOURCE="$1"
DEST="$2"

if [ ! -e "$SOURCE" ]; then
  error "[move] Source introuvable: $SOURCE"
  exit 2
fi

mkdir -p "$DEST"

filename="$(basename "$SOURCE")"
export CORRELATION_ID="${CORRELATION_ID:-${filename%.*}}"

log "[move] Déplacement: source=$SOURCE destination=$DEST"

mv "$SOURCE" "$DEST"

log "[move] Déplacement terminé: $DEST/$filename"

exit 0

########################## executor.sh

#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <excel_file> <env>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

EXCEL_FILE="$1"
ENV="$2"
BASENAME="$(basename "$EXCEL_FILE")"

export CORRELATION_ID="${CORRELATION_ID:-${BASENAME%.*}}"

if [ ! -f "$EXCEL_FILE" ]; then
  error "[executor] Fichier Excel introuvable: $EXCEL_FILE"
  exit 2
fi

log "[executor] Fichier détecté: $BASENAME"

SERVICE_NAME="${BASENAME%%_*}"
ACTION_PART="${BASENAME#*_}"
ACTION="${ACTION_PART%%.*}"

if [ -z "$SERVICE_NAME" ] || [ -z "$ACTION" ] || [ "$SERVICE_NAME" = "$BASENAME" ]; then
  error "[executor] Nom de fichier invalide: $BASENAME. Format attendu: <service>_<action>.xls(x)"
  exit 3
fi

log "[executor] Service: $SERVICE_NAME | Action: $ACTION"

case "$ACTION" in
  import)
    ACTION_SCRIPT="./import.sh"
    ;;
  update)
    ACTION_SCRIPT="./update.sh"
    ;;
  delete)
    ACTION_SCRIPT="./delete.sh"
    ;;
  query)
    ACTION_SCRIPT="./query_users.sh"
    ;;
  *)
    error "[executor] ACTION inconnue dans le nom du fichier: $ACTION"
    exit 4
    ;;
esac

log "[executor] Script choisi: $ACTION_SCRIPT $SERVICE_NAME $EXCEL_FILE $ENV"

start_time="$(date +%s)"

if "$ACTION_SCRIPT" "$SERVICE_NAME" "$EXCEL_FILE" "$ENV"; then
  duration="$(( $(date +%s) - start_time ))"
  log "[executor] Script métier terminé avec succès. duration=${duration}s"
else
  exit_code="$?"
  duration="$(( $(date +%s) - start_time ))"
  error "[executor] Script métier échoué. exitCode=$exit_code duration=${duration}s"
  exit "$exit_code"
fi

if [ "$ACTION" = "import" ]; then
  log "[executor] Action import terminée, lancement de send_emails pour $SERVICE_NAME ($ENV)"

  if ./send_emails.sh "$SERVICE_NAME" "$ENV"; then
    log "[executor] send_emails terminé avec succès"
  else
    exit_code="$?"
    error "[executor] send_emails échoué. exitCode=$exit_code"
    exit "$exit_code"
  fi
fi

log "[executor] Script métier terminé"
exit 0

########################## 
