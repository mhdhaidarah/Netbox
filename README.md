# Install Docker

## Update
```bash
sudo apt update
sudo apt install -y PostgreSQL
```

## Create Database with user
```bash
sudo -u postgres psql
```
## Inside PSQL
```bash
CREATE DATABASE netbox;
CREATE USER netbox WITH PASSWORD 'J5brHrAXFLQSif0K';
ALTER DATABASE netbox OWNER TO netbox;
\q
```

## Test Postgres
```bash
psql --username netbox --password --host localhost netbox
```

## Install Redis
```bash
sudo apt install -y redis-server
```

## Install Needed Software
```bash
sudo apt install -y python3 python3-pip python3-venv python3-dev \
build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev \
libssl-dev zlib1g-dev
```

## Install Netbox
```bash
sudo mkdir -p /opt/netbox/
cd /opt/netbox/
sudo apt install -y git
sudo git clone https://github.com/netbox-community/netbox.git .

sudo adduser --system --group netbox
sudo chown --recursive netbox /opt/netbox/netbox/media/
sudo chown --recursive netbox /opt/netbox/netbox/reports/
sudo chown --recursive netbox /opt/netbox/netbox/scripts/
```

## Update Config File
```bash
cd /opt/netbox/netbox/netbox/
sudo cp configuration_example.py configuration.py
```

## Generate Key with
```bash
python3 ../generate_secret_key.py
```

## Add These to the file
```bash
sudo nano /opt/netbox/netbox/netbox/configuration.py
```
## Final file configuration.py
```bash
ALLOWED_HOSTS = ['*']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',  # Database engine
        'NAME': 'netbox',         # Database name
        'USER': 'netbox',               # PostgreSQL username
        'PASSWORD': 'J5brHrAXFLQSif0K',           # PostgreSQL password
        'HOST': 'localhost',      # Database server
        'PORT': '',               # Database port (leave blank for default)
        'CONN_MAX_AGE': 300,      # Max database connection age
    }
}
# DO NOT USE THIS EXAMPLE PEPPER IN PRODUCTION

SECRET_KEY = 'lbHcPYHGVI@6(l*9)aQTm1T-VdYvhVL@EMc0N#p902UrVJnpOZ'

API_TOKEN_PEPPERS = {
    # DO NOT USE THIS EXAMPLE PEPPER IN PRODUCTION
    1: 'lbHcPYHGVI@6(l*9)aQTm1T-VdYvhVL@EMc0N#p902UrVJnpOZ',
}

PLUGINS = [
    "netbox_qrcode",
    "netbox_reorder_rack",
    "netbox_topology_views",
]


#Save and Exit
```

## Final Step to Install Netbox
```bash
sudo /opt/netbox/upgrade.sh
```

## Create Super User
```bash
source /opt/netbox/venv/bin/activate
cd /opt/netbox/netbox
python3 manage.py createsuperuser
```


## First Test
## Access using http://<server_ip>:8000
```bash
python3 manage.py runserver 0.0.0.0:8000 --insecure
```

## Convert To Service Using Nginx
```bash
sudo cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
sudo cp -v /opt/netbox/contrib/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now netbox netbox-rq
systemctl status netbox.service

sudo su
source /opt/netbox/venv/bin/activate
pip3 install pyuwsgi
sudo sh -c "echo 'pyuwsgi' >> /opt/netbox/local_requirements.txt"
sudo cp /opt/netbox/contrib/uwsgi.ini /opt/netbox/uwsgi.ini

sudo cp -v /opt/netbox/contrib/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now netbox netbox-rq
```

## Change IP Address
```bash
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
-keyout /etc/ssl/private/netbox.key \
-out /etc/ssl/certs/netbox.crt \
-subj "/CN=<IP ADDRESS>" \
-addext "subjectAltName = IP:<IP ADDRESS>"
```
## Install Nginx
```bash
sudo apt install -y nginx
sudo cp /opt/netbox/contrib/nginx.conf /etc/nginx/sites-available/netbox
sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
sudo systemctl restart nginx
```

## Import Devices Library
```bash
sudo su
git clone https://github.com/netbox-community/Device-Type-Library-Import.git
cd Device-Type-Library-Import
python3 -m venv venv
source venv/bin/activate

pip install -r requirements.txt
cp .env.example .env
```

## Now Setup URL http://127.0.0.1 & Token the token can be generated from GUI users V1 Must Be
## EXAMPLE
```bash
NETBOX_URL=https://127.0.0.1
NETBOX_TOKEN=LE0GCreKBP0v3jbXauWLVqbmzKtH3BnhI1Z184TV
REPO_URL=https://github.com/netbox-community/devicetype-library.git
REPO_BRANCH=master
IGNORE_SSL_ERRORS=True
#REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt # you should enable this if you are running on a linux sys>
#SLUGS=c9300-48u isr4431 isr4331
```
## Update Here
```bash
sudo nano /opt/Device-Type-Library-Import/.env
```
## Install Device Library Importer
```bash
git clone https://github.com/netbox-community/devicetype-library.git ~/Device-Type-Library-Import/repo
```

## Select Vendors or download all
```bash
./nb-dt-import.py
```
## OR
```bash
./nb-dt-import.py --vendors mikrotik,ubiquiti
```

## Important Plugins
```bash
source /opt/netbox/venv/bin/activate
pip install netbox-napalm-plugin
pip3 install netbox-topology-views
pip install netbox-qrcode
pip install netbox-reorder-rack
```
## Update configuration.py 
```bash
sudo nano /opt/netbox/netbox/netbox/configuration.py
```
```bash
PLUGINS = [
    'netbox_napalm_plugin','netbox_topology_views','netbox_qrcode','netbox_reorder_rack'
     
]
PLUGINS_CONFIG = {
    'netbox_napalm_plugin': {
        'NAPALM_USERNAME': 'xxx',
        'NAPALM_PASSWORD': 'yyy',
    },
}
```
## Do Database migration
```bash
cd /opt/netbox/netbox/
python3 manage.py migrate
python3 manage.py migrate netbox_topology_views
python3 manage.py collectstatic --no-input

echo netbox-topology-views >> /opt/netbox/local_requirements.txt
echo netbox-reorder-rack >> local_requirements.txt

sudo systemctl restart netbox
```


