########################## log.sh

#!/usr/bin/env bash

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local message="${1:-}"
  echo "$(timestamp) INFO  $message"
}

warn() {
  local message="${1:-}"
  echo "$(timestamp) WARN  $message" >&2
}

error() {
  local message="${1:-}"
  echo "$(timestamp) ERROR $message" >&2
}

##########################  run.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

LOGS_ROOT="${SCRIPT_DIR}/../log"
OUTPUT_ROOT="${SCRIPT_DIR}/../output"

DEMANDS_DIR="/share/demands"
PROCESSED_DIR="/share/processed"
SHARED_OUTPUT_DIR="/share/output"

ENVIRONMENT="staging"

pids=()

cleanup() {
  warn "[run] Arrêt demandé. Arrêt des watchers..."

  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done

  wait 2>/dev/null || true
  log "[run] Tous les watchers sont arrêtés."
}

trap cleanup SIGINT SIGTERM

log "[run] Starting watchers..."
log "[run] DEMANDS_DIR=${DEMANDS_DIR}"
log "[run] PROCESSED_DIR=${PROCESSED_DIR}"
log "[run] LOGS_ROOT=${LOGS_ROOT}"
log "[run] OUTPUT_ROOT=${OUTPUT_ROOT}"
log "[run] SHARED_OUTPUT_DIR=${SHARED_OUTPUT_DIR}"
log "[run] ENVIRONMENT=${ENVIRONMENT}"

"${SCRIPT_DIR}/watcher_demand.sh" "$DEMANDS_DIR" "$ENVIRONMENT" "$PROCESSED_DIR" &
pids+=("$!")

"${SCRIPT_DIR}/watcher_files.sh" "$LOGS_ROOT" "$SHARED_OUTPUT_DIR" &
pids+=("$!")

for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    error "[run] Un watcher s'est arrêté en erreur. pid=${pid}"
    cleanup
    exit 1
  fi
done

########################## watcher_demand.sh

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <path_xlsx> <env> <processed_dir>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

INCOMING_PATH="$1"
ENV="$2"
PROCESSED_DIR="$3"
INTERVAL="${INTERVAL:-5}"

mkdir -p "$PROCESSED_DIR"

is_file_stable() {
  local file="$1"
  local size1
  local size2

  size1="$(stat -c%s "$file" 2>/dev/null || echo -1)"
  sleep 1
  size2="$(stat -c%s "$file" 2>/dev/null || echo -2)"

  [[ "$size1" -eq "$size2" && "$size1" -gt 0 ]]
}

log "[watch_incoming] Watching: ${INCOMING_PATH}"
log "[watch_incoming] Current directory: $(pwd)"
log "[watch_incoming] Processed directory: ${PROCESSED_DIR}"
log "[watch_incoming] Environment: ${ENV}"

while true; do
  shopt -s nullglob

  for file in "$INCOMING_PATH"/*.xls "$INCOMING_PATH"/*.xlsx; do
    [[ -f "$file" ]] || continue

    filename="$(basename "$file")"
    correlation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${filename}"

    log "[watch_incoming] Nouveau fichier détecté: ${filename} | correlationId=${correlation_id}"

    if ! is_file_stable "$file"; then
      warn "[watch_incoming] Fichier non stable, traitement reporté: ${filename} | correlationId=${correlation_id}"
      continue
    fi

    if "${SCRIPT_DIR}/executor.sh" "$file" "$ENV" "$correlation_id"; then
      "${SCRIPT_DIR}/move.sh" "$file" "$PROCESSED_DIR"
      log "[watch_incoming] Fichier traité et déplacé: ${filename} -> ${PROCESSED_DIR} | correlationId=${correlation_id}"
    else
      exit_code="$?"
      error "[watch_incoming] Erreur traitement fichier: ${filename} | exitCode=${exit_code} | correlationId=${correlation_id}"
    fi
  done

  sleep "$INTERVAL"
done

########################## watcher_files.sh

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <shared_root> <output_root>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

SHARED_ROOT="$1"
FILES_ROOT="$2"
INTERVAL="${INTERVAL:-5}"

mkdir -p "$FILES_ROOT"

is_file_stable() {
  local file="$1"
  local size1
  local size2

  size1="$(stat -c%s "$file" 2>/dev/null || echo -1)"
  sleep 1
  size2="$(stat -c%s "$file" 2>/dev/null || echo -2)"

  [[ "$size1" -eq "$size2" && "$size1" -gt 0 ]]
}

log "[watch_files] Watching logs in: ${FILES_ROOT}"
log "[watch_files] Shared root: ${SHARED_ROOT}"

while true; do
  shopt -s nullglob

  for file in "${FILES_ROOT}"/*/*; do
    [[ -f "$file" ]] || continue

    service_dir="$(basename "$(dirname "$file")")"
    filename="$(basename "$file")"

    log "[watch_files] Fichier log détecté: service=${service_dir}, fichier=${filename}"

    if ! is_file_stable "$file"; then
      warn "[watch_files] Fichier log non stable, traitement reporté: ${file}"
      continue
    fi

    if "${SCRIPT_DIR}/move.sh" "$file" "$SHARED_ROOT"; then
      log "[watch_files] Fichier déplacé vers ${SHARED_ROOT}/${filename}"
    else
      exit_code="$?"
      error "[watch_files] Erreur déplacement fichier: ${file} | exitCode=${exit_code}"
    fi
  done

  sleep "$INTERVAL"
done

########################## move.sh

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <source> <destination>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

SOURCE="$1"
DEST="$2"

if [[ ! -e "$SOURCE" ]]; then
  error "[move] Source introuvable: ${SOURCE}"
  exit 2
fi

mkdir -p "$DEST"

filename="$(basename "$SOURCE")"
target="${DEST}/${filename}"

if [[ -e "$target" ]]; then
  error "[move] Destination existe déjà: ${target}"
  exit 3
fi

mv "$SOURCE" "$target"

log "[move] Déplacement terminé: ${SOURCE} -> ${target}"

########################## executor.sh

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "Usage: $0 <excel_file> <env> [correlation_id]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

EXCEL_FILE="$1"
ENV="$2"
CORRELATION_ID="${3:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

BASENAME="$(basename "$EXCEL_FILE")"

if [[ ! -f "$EXCEL_FILE" ]]; then
  error "[executor] Fichier Excel introuvable: ${EXCEL_FILE} | correlationId=${CORRELATION_ID}"
  exit 2
fi

SERVICE_NAME="${BASENAME%%_*}"
ACTION_PART="${BASENAME#*_}"
ACTION="${ACTION_PART%%.*}"

if [[ -z "$SERVICE_NAME" || -z "$ACTION" || "$SERVICE_NAME" == "$BASENAME" ]]; then
  error "[executor] Nom de fichier invalide: ${BASENAME} | format attendu: <service>_<action>.xls(x) | correlationId=${CORRELATION_ID}"
  exit 3
fi

case "$ACTION" in
  import)
    ACTION_SCRIPT="${SCRIPT_DIR}/import.sh"
    ;;
  update)
    ACTION_SCRIPT="${SCRIPT_DIR}/update.sh"
    ;;
  delete)
    ACTION_SCRIPT="${SCRIPT_DIR}/delete.sh"
    ;;
  query)
    ACTION_SCRIPT="${SCRIPT_DIR}/query_users.sh"
    ;;
  *)
    error "[executor] Action inconnue dans le nom du fichier: ${ACTION} | fichier=${BASENAME} | correlationId=${CORRELATION_ID}"
    exit 4
    ;;
esac

log "[executor] Début traitement | service=${SERVICE_NAME} | action=${ACTION} | file=${BASENAME} | env=${ENV} | correlationId=${CORRELATION_ID}"

start_time="$(date +%s)"

if "$ACTION_SCRIPT" "$SERVICE_NAME" "$EXCEL_FILE" "$ENV" "$CORRELATION_ID"; then
  duration="$(( $(date +%s) - start_time ))"
  log "[executor] Script métier terminé | service=${SERVICE_NAME} | action=${ACTION} | duration=${duration}s | correlationId=${CORRELATION_ID}"
else
  exit_code="$?"
  duration="$(( $(date +%s) - start_time ))"
  error "[executor] Script métier échoué | service=${SERVICE_NAME} | action=${ACTION} | exitCode=${exit_code} | duration=${duration}s | correlationId=${CORRELATION_ID}"
  exit "$exit_code"
fi

if [[ "$ACTION" == "import" ]]; then
  log "[executor] Action import terminée, lancement de send_emails | service=${SERVICE_NAME} | env=${ENV} | correlationId=${CORRELATION_ID}"

  if "${SCRIPT_DIR}/send_emails.sh" "$SERVICE_NAME" "$ENV" "$CORRELATION_ID"; then
    log "[executor] send_emails terminé | service=${SERVICE_NAME} | correlationId=${CORRELATION_ID}"
  else
    exit_code="$?"
    error "[executor] send_emails échoué | service=${SERVICE_NAME} | exitCode=${exit_code} | correlationId=${CORRELATION_ID}"
    exit "$exit_code"
  fi
fi

exit 0

########################## import.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

usage() {
  error "Usage: $0 config_id [csv_file | xls_file] vault_environment [correlation_id]"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  usage
fi

config_id="$1"
file="$2"
vault_environment="$3"
correlation_id="${4:-N/A}"

if [[ -z "$config_id" || -z "$file" || -z "$vault_environment" ]]; then
  usage
fi

if [[ ! -f "$file" ]]; then
  error "[import] Fichier introuvable: ${file} | correlationId=${correlation_id}"
  exit 2
fi

log "[import] Bulk upload of users from csv/xls file | configId=${config_id} | file=$(basename "$file") | env=${vault_environment} | correlationId=${correlation_id}"

java -cp config:lib/websso_bulk_upload.jar \
  com.bpc.tsp.websso.cli.Main \
  -o CREATE \
  -i "$config_id" \
  -f "$file" \
  -e "$vault_environment"

exit_code="$?"

if [[ "$exit_code" -ne 0 ]]; then
  error "[import] Import users failed | configId=${config_id} | exitCode=${exit_code} | correlationId=${correlation_id}"
  exit "$exit_code"
fi

log "[import] Import users success | configId=${config_id} | correlationId=${correlation_id}"
exit 0

########################## update.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

usage() {
  error "Usage: $0 config_id [csv_file | xls_file] vault_environment [correlation_id]"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  usage
fi

config_id="$1"
file="$2"
vault_environment="$3"
correlation_id="${4:-N/A}"

if [[ -z "$config_id" || -z "$file" || -z "$vault_environment" ]]; then
  usage
fi

if [[ ! -f "$file" ]]; then
  error "[update] Fichier introuvable: ${file} | correlationId=${correlation_id}"
  exit 2
fi

log "[update] Bulk update of users from csv/xls file | configId=${config_id} | file=$(basename "$file") | env=${vault_environment} | correlationId=${correlation_id}"

java -cp config:lib/websso_bulk_upload.jar \
  com.bpc.tsp.websso.cli.Main \
  -o UPDATE \
  -i "$config_id" \
  -f "$file" \
  -e "$vault_environment"

exit_code="$?"

if [[ "$exit_code" -ne 0 ]]; then
  error "[update] Update users failed | configId=${config_id} | exitCode=${exit_code} | correlationId=${correlation_id}"
  exit "$exit_code"
fi

log "[update] Update users success | configId=${config_id} | correlationId=${correlation_id}"
exit 0

########################## delete.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

usage() {
  error "Usage: $0 config_id [csv_file | xls_file] vault_environment [correlation_id]"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  usage
fi

config_id="$1"
file="$2"
vault_environment="$3"
correlation_id="${4:-N/A}"

if [[ -z "$config_id" || -z "$file" || -z "$vault_environment" ]]; then
  usage
fi

if [[ ! -f "$file" ]]; then
  error "[delete] Fichier introuvable: ${file} | correlationId=${correlation_id}"
  exit 2
fi

log "[delete] Bulk delete of users from csv/xls file | configId=${config_id} | file=$(basename "$file") | env=${vault_environment} | correlationId=${correlation_id}"

java -cp config:lib/websso_bulk_upload.jar \
  com.bpc.tsp.websso.cli.Main \
  -o DELETE \
  -i "$config_id" \
  -f "$file" \
  -e "$vault_environment"

exit_code="$?"

if [[ "$exit_code" -ne 0 ]]; then
  error "[delete] Delete users failed | configId=${config_id} | exitCode=${exit_code} | correlationId=${correlation_id}"
  exit "$exit_code"
fi

log "[delete] Delete users success | configId=${config_id} | correlationId=${correlation_id}"
exit 0

########################## query_users.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

usage() {
  error "Usage: $0 config_id file vault_environment [correlation_id]"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  usage
fi

config_id="$1"
file="$2"
vault_environment="$3"
correlation_id="${4:-N/A}"

if [[ -z "$config_id" || -z "$file" || -z "$vault_environment" ]]; then
  usage
fi

log "[query_users] Query users to csv file | configId=${config_id} | file=$(basename "$file") | env=${vault_environment} | correlationId=${correlation_id}"

java -cp config:lib/websso_bulk_upload.jar \
  com.bpc.tsp.websso.cli.Main \
  -o READ \
  -i "$config_id" \
  -f "$file" \
  -e "$vault_environment"

exit_code="$?"

if [[ "$exit_code" -ne 0 ]]; then
  error "[query_users] Read users failed | configId=${config_id} | exitCode=${exit_code} | correlationId=${correlation_id}"
  exit "$exit_code"
fi

log "[query_users] Read users success | configId=${config_id} | correlationId=${correlation_id}"
exit 0

########################## send_emails.sh

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

usage() {
  error "Usage: $0 config_id vault_environment [correlation_id]"
  exit 1
}

if [[ "$#" -lt 2 ]]; then
  usage
fi

config_id="$1"
vault_environment="$2"
correlation_id="${3:-N/A}"

if [[ -z "$config_id" || -z "$vault_environment" ]]; then
  usage
fi

log "[send_emails] Bulk send email to users | configId=${config_id} | env=${vault_environment} | correlationId=${correlation_id}"

java -cp config:lib/websso_bulk_upload.jar \
  com.bpc.tsp.websso.cli.Main \
  -o SEND_MAIL \
  -i "$config_id" \
  -e "$vault_environment"

exit_code="$?"

if [[ "$exit_code" -ne 0 ]]; then
  error "[send_emails] Send email to users failed | configId=${config_id} | exitCode=${exit_code} | correlationId=${correlation_id}"
  exit "$exit_code"
fi

log "[send_emails] Send email to users success | configId=${config_id} | correlationId=${correlation_id}"
exit 0
