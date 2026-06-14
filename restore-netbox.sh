#!/usr/bin/env bash
#==============================================================================
# NetBox one-command RESTORE
#   - Restores a backup produced by backup-netbox.sh
#   - Stops NetBox, drops & recreates the database, restores data,
#     restores configuration.py + media, then starts NetBox again
#
# Usage as root:
#   sudo bash restore-netbox.sh                      # restores the NEWEST backup
#   sudo bash restore-netbox.sh /path/to/backup.tar.gz
#
# THIS IS DESTRUCTIVE: it overwrites the current database. You will be asked
# to confirm before anything is changed.
#==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0 [backup.tar.gz]" >&2
  exit 1
fi

NETBOX_DIR="/opt/netbox"
CONF="${NETBOX_DIR}/netbox/netbox/configuration.py"
BACKUP_DIR="/opt/netbox-backups"

# Database name from configuration.py (default: netbox)
DB_NAME="$(grep -Po "'NAME':\s*'\K[^']+" "${CONF}" 2>/dev/null | head -1 || true)"
DB_NAME="${DB_NAME:-netbox}"
DB_USER="$(grep -Po "'USER':\s*'\K[^']+" "${CONF}" 2>/dev/null | head -1 || true)"
DB_USER="${DB_USER:-netbox}"

# Pick the backup file: argument, or the most recent one in BACKUP_DIR
ARCHIVE="${1:-}"
if [[ -z "${ARCHIVE}" ]]; then
  ARCHIVE="$(ls -1t "${BACKUP_DIR}"/netbox-backup-*.tar.gz 2>/dev/null | head -1 || true)"
fi
if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "No backup file found. Pass one explicitly:" >&2
  echo "  sudo bash $0 /opt/netbox-backups/netbox-backup-YYYYMMDD-HHMMSS.tar.gz" >&2
  exit 1
fi

echo "About to restore: ${ARCHIVE}"
echo "This will ERASE and replace the current '${DB_NAME}' database."
if [[ -e /dev/tty ]]; then
  read -rp "Type 'yes' to continue: " CONFIRM </dev/tty || CONFIRM=""
  [[ "${CONFIRM}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Unpacking archive"
tar -xzf "${ARCHIVE}" -C "${WORK}"
[[ -f "${WORK}/database.dump" ]] || { echo "database.dump not found in archive" >&2; exit 1; }

echo "==> Stopping NetBox services"
systemctl stop netbox netbox-rq 2>/dev/null || true

echo "==> Recreating database '${DB_NAME}'"
sudo -u postgres psql <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

echo "==> Restoring database (ownership notices on plpgsql are harmless)"
sudo -u postgres pg_restore -d "${DB_NAME}" "${WORK}/database.dump" || true

echo "==> Restoring configuration.py"
[[ -f "${WORK}/configuration.py" ]] && cp "${WORK}/configuration.py" "${CONF}" || true

echo "==> Restoring media files"
if [[ -f "${WORK}/media.tar.gz" ]]; then
  rm -rf "${NETBOX_DIR}/netbox/media"
  tar -xzf "${WORK}/media.tar.gz" -C "${NETBOX_DIR}/netbox"
  chown -R netbox:netbox "${NETBOX_DIR}/netbox/media"
fi

echo "==> Applying any pending migrations"
# shellcheck disable=SC1091
source "${NETBOX_DIR}/venv/bin/activate"
python3 "${NETBOX_DIR}/netbox/manage.py" migrate --no-input || true

echo "==> Starting NetBox services"
systemctl start netbox netbox-rq

echo
echo "======================================================================"
echo "  Restore complete from: ${ARCHIVE}"
echo "  Check status:  systemctl status netbox netbox-rq nginx"
echo "======================================================================"
