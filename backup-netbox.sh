#!/usr/bin/env bash
#==============================================================================
# NetBox one-command BACKUP
#   - Dumps the PostgreSQL "netbox" database (compressed custom format)
#   - Also saves configuration.py and the uploaded media files
#   - Everything goes into one timestamped .tar.gz in /opt/netbox-backups
#   - Keeps the most recent 14 backups, deletes older ones
#
# Run as root:   sudo bash backup-netbox.sh
#==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi

NETBOX_DIR="/opt/netbox"
CONF="${NETBOX_DIR}/netbox/netbox/configuration.py"
BACKUP_DIR="/opt/netbox-backups"
RETENTION=14                               # how many backups to keep
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Read the database name from configuration.py (default: netbox)
DB_NAME="$(grep -Po "'NAME':\s*'\K[^']+" "${CONF}" 2>/dev/null | head -1 || true)"
DB_NAME="${DB_NAME:-netbox}"

mkdir -p "${BACKUP_DIR}"

echo "==> Dumping database '${DB_NAME}'"
sudo -u postgres pg_dump -Fc "${DB_NAME}" > "${WORK}/database.dump"

echo "==> Saving configuration.py"
[[ -f "${CONF}" ]] && cp "${CONF}" "${WORK}/configuration.py" || true

echo "==> Saving media files"
if [[ -d "${NETBOX_DIR}/netbox/media" ]]; then
  tar -czf "${WORK}/media.tar.gz" -C "${NETBOX_DIR}/netbox" media
fi

ARCHIVE="${BACKUP_DIR}/netbox-backup-${TIMESTAMP}.tar.gz"
echo "==> Packing archive"
tar -czf "${ARCHIVE}" -C "${WORK}" .

echo "==> Pruning old backups (keeping last ${RETENTION})"
ls -1t "${BACKUP_DIR}"/netbox-backup-*.tar.gz 2>/dev/null \
  | tail -n +$((RETENTION + 1)) | xargs -r rm -f

SIZE="$(du -h "${ARCHIVE}" | cut -f1)"
echo
echo "======================================================================"
echo "  Backup complete:  ${ARCHIVE}  (${SIZE})"
echo "  Restore with:     sudo bash restore-netbox.sh ${ARCHIVE}"
echo "======================================================================"
