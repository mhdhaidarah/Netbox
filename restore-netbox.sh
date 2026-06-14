#!/usr/bin/env bash
#==============================================================================
# NetBox one-command RESTORE  (data only - safe on a NEW machine)
#
#   - Restores a backup made by backup-netbox.sh (database + media)
#   - DOES NOT touch this machine's:
#       * configuration.py  (keeps its SECRET_KEY and DB password)
#       * PostgreSQL role / password
#       * super admin login  (captured before restore, re-applied after, so
#         you keep logging in with THIS machine's admin + password)
#
#   Typical new-machine recovery:
#     1) run install-netbox.sh   (fresh, working NetBox + its own admin)
#     2) copy your backup .tar.gz onto the machine
#     3) run this script         (your data comes back, login unchanged)
#
# Usage as root:
#   sudo bash restore-netbox.sh                      # newest backup
#   sudo bash restore-netbox.sh /path/to/backup.tar.gz
#
# Destructive for the database content. You will be asked to confirm.
#==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0 [backup.tar.gz]" >&2
  exit 1
fi

NETBOX_DIR="/opt/netbox"
CONF="${NETBOX_DIR}/netbox/netbox/configuration.py"
BACKUP_DIR="/opt/netbox-backups"
MANAGE="${NETBOX_DIR}/netbox/manage.py"
SU_CACHE="/tmp/nb_superusers.json"

# DB name/user from the LIVE configuration.py (defaults: netbox / netbox)
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
echo "This replaces the '${DB_NAME}' DATA. This machine's admin login and DB"
echo "credentials will be preserved."
if [[ -e /dev/tty ]]; then
  read -rp "Type 'yes' to continue: " CONFIRM </dev/tty || CONFIRM=""
  [[ "${CONFIRM}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# shellcheck disable=SC1091
source "${NETBOX_DIR}/venv/bin/activate"

#------------------------------------------------------------------------------
# 1. Capture THIS machine's superuser logins (before we drop the database)
#------------------------------------------------------------------------------
echo "==> Capturing current super admin login(s)"
if ! python3 "${MANAGE}" shell <<PYEOF
import json
from django.contrib.auth import get_user_model
U = get_user_model()
rows = [{
    'username': u.username, 'password': u.password, 'email': u.email,
    'is_active': u.is_active,
} for u in U.objects.filter(is_superuser=True)]
open('${SU_CACHE}', 'w').write(json.dumps(rows))
print('Captured %d superuser login(s)' % len(rows))
PYEOF
then
  echo "ERROR: could not read current superusers. Aborting BEFORE any change." >&2
  echo "       (Nothing was dropped or restored.)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Unpacking archive"
tar -xzf "${ARCHIVE}" -C "${WORK}"
[[ -f "${WORK}/database.dump" ]] || { echo "database.dump not found in archive" >&2; exit 1; }

echo "==> Stopping NetBox services"
systemctl stop netbox netbox-rq 2>/dev/null || true

#------------------------------------------------------------------------------
# 2. Replace the database with the backup's data
#------------------------------------------------------------------------------
echo "==> Recreating database '${DB_NAME}'"
sudo -u postgres psql <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

echo "==> Restoring database (ownership notices on plpgsql are harmless)"
sudo -u postgres pg_restore -d "${DB_NAME}" "${WORK}/database.dump" || true

echo "==> Restoring media files"
if [[ -f "${WORK}/media.tar.gz" ]]; then
  rm -rf "${NETBOX_DIR}/netbox/media"
  tar -xzf "${WORK}/media.tar.gz" -C "${NETBOX_DIR}/netbox"
  chown -R netbox:netbox "${NETBOX_DIR}/netbox/media"
fi

echo "==> Applying any pending migrations"
python3 "${MANAGE}" migrate --no-input || true

#------------------------------------------------------------------------------
# 3. Re-apply THIS machine's superuser login so you can still log in
#------------------------------------------------------------------------------
echo "==> Re-applying this machine's super admin login"
python3 "${MANAGE}" shell <<PYEOF || echo "   (nothing to re-apply)"
import json, os
from django.contrib.auth import get_user_model
U = get_user_model()
path = '${SU_CACHE}'
rows = json.load(open(path)) if os.path.exists(path) else []
for r in rows:
    u, _ = U.objects.update_or_create(
        username=r['username'],
        defaults={'email': r['email'],
                  'is_active': r['is_active'], 'is_superuser': True},
    )
    u.password = r['password']   # exact hash -> same password keeps working
    u.save()
print('Re-applied %d superuser login(s)' % len(rows))
PYEOF
rm -f "${SU_CACHE}"

echo "==> Starting NetBox services"
systemctl start netbox netbox-rq

echo
echo "======================================================================"
echo "  Restore complete from: ${ARCHIVE}"
echo "  Data restored. Log in with THIS machine's existing admin + password."
echo "  Check status:  systemctl status netbox netbox-rq nginx"
echo "======================================================================"
