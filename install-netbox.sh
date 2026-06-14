#!/usr/bin/env bash
#==============================================================================
# NetBox unattended installer for Ubuntu (22.04 / 24.04)
# Based on: https://github.com/mhdhaidarah/Netbox
#
# What it does, end to end, with NO questions until the very end:
#   - Installs PostgreSQL, Redis, and all build dependencies
#   - Creates the netbox database + user (random password)
#   - Clones NetBox (latest stable release) into /opt/netbox
#   - Writes configuration.py with auto-generated SECRET_KEY + API pepper
#   - Runs upgrade.sh (creates venv, installs deps, migrates, collectstatic)
#   - Creates an admin superuser (random password) + an API token
#   - Sets up gunicorn + systemd services (netbox, netbox-rq)
#   - Generates a self-signed SSL cert for the server IP and configures nginx
#   - THEN asks you which device-type vendors to import into the library
#
# Run it as root:  sudo bash install-netbox.sh
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# 0. Pre-flight
#------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }

# Auto-detect primary IP (used for ALLOWED_HOSTS, the SSL cert and nginx)
SERVER_IP="$(hostname -I | awk '{print $1}')"

# Generated secrets
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-18)"
ADMIN_USER="admin"
ADMIN_EMAIL="admin@${SERVER_IP}"
API_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(20))')"

NETBOX_DIR="/opt/netbox"

#------------------------------------------------------------------------------
# 1. System packages
#------------------------------------------------------------------------------
log "Updating apt and installing PostgreSQL, Redis and build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y \
  postgresql postgresql-contrib redis-server \
  python3 python3-pip python3-venv python3-dev \
  build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev \
  libssl-dev zlib1g-dev git curl openssl

systemctl enable --now postgresql redis-server

#------------------------------------------------------------------------------
# 2. Database
#------------------------------------------------------------------------------
log "Creating PostgreSQL database and user"
sudo -u postgres psql <<SQL
DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'netbox') THEN
      CREATE ROLE netbox LOGIN PASSWORD '${DB_PASSWORD}';
   ELSE
      ALTER ROLE netbox PASSWORD '${DB_PASSWORD}';
   END IF;
END \$\$;
SELECT 'CREATE DATABASE netbox OWNER netbox'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'netbox')\gexec
ALTER DATABASE netbox OWNER TO netbox;
SQL

#------------------------------------------------------------------------------
# 3. Get NetBox source (latest stable release tag)
#------------------------------------------------------------------------------
log "Cloning NetBox into ${NETBOX_DIR}"
mkdir -p "${NETBOX_DIR}"
if [[ ! -d "${NETBOX_DIR}/.git" ]]; then
  git clone -q https://github.com/netbox-community/netbox.git "${NETBOX_DIR}"
fi
cd "${NETBOX_DIR}"
git fetch -q --tags
LATEST_TAG="$(git tag | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
git checkout -q "${LATEST_TAG}"
log "Using NetBox ${LATEST_TAG}"

# Service account + permissions
if ! id netbox &>/dev/null; then
  adduser --system --group netbox
fi
chown --recursive netbox "${NETBOX_DIR}/netbox/media/" \
                         "${NETBOX_DIR}/netbox/reports/" 2>/dev/null || true
chown --recursive netbox "${NETBOX_DIR}/netbox/scripts/" 2>/dev/null || true

#------------------------------------------------------------------------------
# 4. configuration.py
#------------------------------------------------------------------------------
log "Writing configuration.py"
SECRET_KEY="$(python3 "${NETBOX_DIR}/netbox/generate_secret_key.py")"
API_PEPPER="$(python3 "${NETBOX_DIR}/netbox/generate_secret_key.py")"
CONF="${NETBOX_DIR}/netbox/netbox/configuration.py"

cat > "${CONF}" <<PYCONF
ALLOWED_HOSTS = ['*']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'netbox',
        'USER': 'netbox',
        'PASSWORD': '${DB_PASSWORD}',
        'HOST': 'localhost',
        'PORT': '',
        'CONN_MAX_AGE': 300,
    }
}

REDIS = {
    'tasks': {
        'HOST': 'localhost',
        'PORT': 6379,
        'USERNAME': '',
        'PASSWORD': '',
        'DATABASE': 0,
        'SSL': False,
    },
    'caching': {
        'HOST': 'localhost',
        'PORT': 6379,
        'USERNAME': '',
        'PASSWORD': '',
        'DATABASE': 1,
        'SSL': False,
    }
}

SECRET_KEY = '${SECRET_KEY}'

API_TOKEN_PEPPERS = {
    1: '${API_PEPPER}',
}

PLUGINS = [
    'netbox_qrcode',
    'netbox_reorder_rack',
    'netbox_topology_views',
]
PYCONF

# Install the three plugins together with NetBox via local_requirements.txt
cat > "${NETBOX_DIR}/local_requirements.txt" <<REQ
netbox-qrcode
netbox-reorder-rack
netbox-topology-views
REQ

#------------------------------------------------------------------------------
# 5. Build / migrate
#------------------------------------------------------------------------------
log "Running upgrade.sh (venv, deps, migrations, collectstatic)"
bash "${NETBOX_DIR}/upgrade.sh"

#------------------------------------------------------------------------------
# 6. Superuser + API token
#------------------------------------------------------------------------------
log "Creating admin superuser and API token"
# shellcheck disable=SC1091
source "${NETBOX_DIR}/venv/bin/activate"
cd "${NETBOX_DIR}/netbox"

# Create-or-update the superuser directly via the ORM (idempotent and
# guaranteed to set the password). Does NOT rely on createsuperuser, which
# can fail silently and leave you unable to log in.
python3 manage.py shell <<PYSHELL
from django.contrib.auth import get_user_model, authenticate
from users.models import Token
U = get_user_model()
u, created = U.objects.get_or_create(
    username='${ADMIN_USER}',
    defaults={'email': '${ADMIN_EMAIL}'},
)
u.is_staff = True
u.is_superuser = True
u.is_active = True
u.set_password('${ADMIN_PASSWORD}')
u.save()
Token.objects.get_or_create(user=u, defaults={'key': '${API_TOKEN}'})
ok = authenticate(username='${ADMIN_USER}', password='${ADMIN_PASSWORD}')
print('Superuser ' + ('created' if created else 'updated') + ': ${ADMIN_USER}')
print('Auth self-test: ' + ('PASS' if ok else 'FAIL'))
PYSHELL

#------------------------------------------------------------------------------
# 7. gunicorn + systemd services
#------------------------------------------------------------------------------
log "Configuring gunicorn + systemd services"
cp "${NETBOX_DIR}/contrib/gunicorn.py" "${NETBOX_DIR}/gunicorn.py"
cp -v "${NETBOX_DIR}"/contrib/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now netbox netbox-rq

#------------------------------------------------------------------------------
# 8. SSL cert + nginx
#------------------------------------------------------------------------------
log "Generating self-signed certificate for ${SERVER_IP}"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/netbox.key \
  -out /etc/ssl/certs/netbox.crt \
  -subj "/CN=${SERVER_IP}" \
  -addext "subjectAltName = IP:${SERVER_IP}"

log "Installing and configuring nginx"
apt install -y nginx
cp "${NETBOX_DIR}/contrib/nginx.conf" /etc/nginx/sites-available/netbox
sed -i "s/server_name .*/server_name ${SERVER_IP};/" /etc/nginx/sites-available/netbox
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
systemctl restart nginx

#------------------------------------------------------------------------------
# 9. Device-Type Library import  (the interactive part)
#------------------------------------------------------------------------------
log "Setting up the NetBox Device-Type Library importer"
IMPORT_DIR="/opt/Device-Type-Library-Import"
if [[ ! -d "${IMPORT_DIR}/.git" ]]; then
  git clone -q https://github.com/netbox-community/Device-Type-Library-Import.git "${IMPORT_DIR}"
fi
cd "${IMPORT_DIR}"
python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install -q -r requirements.txt

cat > "${IMPORT_DIR}/.env" <<ENVF
NETBOX_URL=https://${SERVER_IP}
NETBOX_TOKEN=${API_TOKEN}
REPO_URL=https://github.com/netbox-community/devicetype-library.git
REPO_BRANCH=master
IGNORE_SSL_ERRORS=True
ENVF

git clone -q https://github.com/netbox-community/devicetype-library.git "${IMPORT_DIR}/repo" 2>/dev/null || true

echo
echo "======================================================================"
echo " NetBox is installed and running. Now choose device-type vendors to"
echo " import into the library."
echo
echo "   - Type vendor names separated by commas, e.g.:  mikrotik,ubiquiti,cisco"
echo "   - Type  all   to import every vendor (this is large and slow)"
echo "   - Press Enter to skip importing for now"
echo "======================================================================"
# Read from the terminal even when the script is piped via curl | bash
if [[ -e /dev/tty ]]; then
  read -rp "Vendors to import: " VENDORS </dev/tty || VENDORS=""
else
  VENDORS="${NETBOX_VENDORS:-}"
fi

if [[ -z "${VENDORS}" ]]; then
  echo "Skipping device-type import. You can run it later from ${IMPORT_DIR}:"
  echo "   source venv/bin/activate && ./nb-dt-import.py --vendors mikrotik,ubiquiti"
elif [[ "${VENDORS,,}" == "all" ]]; then
  log "Importing ALL vendors (this can take a while)"
  ./nb-dt-import.py || echo "Import finished with some warnings."
else
  log "Importing vendors: ${VENDORS}"
  ./nb-dt-import.py --vendors "${VENDORS}" || echo "Import finished with some warnings."
fi

#------------------------------------------------------------------------------
# 10. Summary
#------------------------------------------------------------------------------
cat <<SUMMARY

======================================================================
  NetBox installation complete
======================================================================
  URL:            https://${SERVER_IP}/
  Admin user:     ${ADMIN_USER}
  Admin password: ${ADMIN_PASSWORD}
  API token:      ${API_TOKEN}

  PostgreSQL DB:  netbox
  DB user:        netbox
  DB password:    ${DB_PASSWORD}

  NetBox version: ${LATEST_TAG}
  Services:       systemctl status netbox netbox-rq nginx
======================================================================
  SAVE THESE CREDENTIALS NOW - the passwords were randomly generated
  and are not stored anywhere else.
======================================================================
SUMMARY
