#!/usr/bin/env bash

set -Eeuo pipefail

PAPERLESS_VERSION="v2.20.15"
PAPERLESS_SHA256="e9bfb6ec0425e5e72a85f64811829167b6c22753f83e325b95d5068393073bf6"
PAPERLESS_URL="https://github.com/paperless-ngx/paperless-ngx/releases/download/${PAPERLESS_VERSION}/paperless-ngx-${PAPERLESS_VERSION}.tar.xz"
INSTALL_DIR="/opt/paperless"
DATA_DIR="/opt/paperless_data"
DB_NAME="paperlessdb"
DB_USER="paperless"
ADMIN_USER="admin"

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

fail() {
  printf '\n\033[1;31mFehler: %s\033[0m\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf '\n\033[1;31mInstallation in Zeile %s fehlgeschlagen (Exit-Code %s).\033[0m\n' "${BASH_LINENO[0]:-unbekannt}" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || fail "Das Skript muss innerhalb des LXC als root ausgeführt werden."
[[ -r /etc/os-release ]] || fail "/etc/os-release wurde nicht gefunden."

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || fail "Unterstützt wird Debian 13. Gefunden: ${PRETTY_NAME:-unbekannt}."
[[ "${VERSION_ID:-}" == "13" ]] || fail "Unterstützt wird Debian 13. Gefunden: ${PRETTY_NAME:-unbekannt}."
[[ -d /run/systemd/system ]] || fail "Im LXC läuft kein systemd."
[[ ! -e "$INSTALL_DIR" ]] || fail "$INSTALL_DIR existiert bereits. Für eine bestehende Installation ist dieses Neuinstallationsskript nicht geeignet."

export DEBIAN_FRONTEND=noninteractive

log "Paketquellen aktualisieren"
apt-get update

log "Systemabhängigkeiten installieren"
apt-get install -y \
  ca-certificates \
  curl \
  openssl \
  xz-utils \
  redis-server \
  postgresql \
  postgresql-contrib \
  build-essential \
  imagemagick \
  fonts-liberation \
  gnupg \
  optipng \
  libpq-dev \
  libmagic-dev \
  poppler-utils \
  default-libmysqlclient-dev \
  automake \
  libtool \
  pkg-config \
  libtiff-dev \
  libpng-dev \
  libleptonica-dev \
  libleptonica6 \
  unpaper \
  icc-profiles-free \
  qpdf \
  libxml2 \
  pngquant \
  zlib1g \
  tesseract-ocr \
  tesseract-ocr-deu \
  tesseract-ocr-eng \
  ghostscript

systemctl enable --now redis-server postgresql

WORK_DIR="$(mktemp -d /tmp/paperless-install.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

log "uv und Python 3.13 installieren"
UV_INSTALLER="$WORK_DIR/uv-install.sh"
curl -fsSL https://astral.sh/uv/install.sh -o "$UV_INSTALLER"
[[ -s "$UV_INSTALLER" ]] || fail "Der uv-Installer konnte nicht heruntergeladen werden."
env UV_INSTALL_DIR=/usr/local/bin sh "$UV_INSTALLER"
command -v uv >/dev/null 2>&1 || fail "uv wurde nicht korrekt installiert."
uv python install 3.13

log "Paperless-ngx ${PAPERLESS_VERSION} herunterladen und Prüfsumme kontrollieren"
ARCHIVE="$WORK_DIR/paperless.tar.xz"
curl -fL --retry 3 --retry-delay 2 "$PAPERLESS_URL" -o "$ARCHIVE"
echo "${PAPERLESS_SHA256}  ${ARCHIVE}" | sha256sum --check --status || fail "Die SHA-256-Prüfsumme des Paperless-Archivs stimmt nicht."

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"

shopt -s nullglob dotglob
EXTRACTED_ITEMS=("$EXTRACT_DIR"/*)
shopt -u nullglob dotglob
if [[ ${#EXTRACTED_ITEMS[@]} -eq 1 && -d "${EXTRACTED_ITEMS[0]}" ]]; then
  SOURCE_DIR="${EXTRACTED_ITEMS[0]}"
else
  SOURCE_DIR="$EXTRACT_DIR"
fi

mkdir -p "$INSTALL_DIR"
cp -a "$SOURCE_DIR"/. "$INSTALL_DIR"/
rm -rf "$INSTALL_DIR/docker"

log "PostgreSQL-Datenbank einrichten"
DB_PASSWORD="$(openssl rand -hex 24)"
SECRET_KEY="$(openssl rand -hex 32)"
ADMIN_PASSWORD="$(openssl rand -hex 16)"

runuser -u postgres -- psql --set=ON_ERROR_STOP=1 <<SQL
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

mkdir -p "$DATA_DIR"/{consume,data,media,trash}
mkdir -p "$INSTALL_DIR/static"

TIME_ZONE="$(cat /etc/timezone 2>/dev/null || true)"
TIME_ZONE="${TIME_ZONE:-Europe/Berlin}"

cat >"$INSTALL_DIR/paperless.conf" <<EOF
PAPERLESS_REDIS=redis://localhost:6379
PAPERLESS_CONSUMPTION_DIR=${DATA_DIR}/consume
PAPERLESS_DATA_DIR=${DATA_DIR}/data
PAPERLESS_MEDIA_ROOT=${DATA_DIR}/media
PAPERLESS_EMPTY_TRASH_DIR=${DATA_DIR}/trash
PAPERLESS_STATICDIR=${INSTALL_DIR}/static
PAPERLESS_DBENGINE=postgresql
PAPERLESS_DBHOST=localhost
PAPERLESS_DBPORT=5432
PAPERLESS_DBNAME=${DB_NAME}
PAPERLESS_DBUSER=${DB_USER}
PAPERLESS_DBPASS=${DB_PASSWORD}
PAPERLESS_SECRET_KEY=${SECRET_KEY}
PAPERLESS_TIME_ZONE=${TIME_ZONE}
PAPERLESS_OCR_LANGUAGE=deu+eng
EOF
chmod 600 "$INSTALL_DIR/paperless.conf"

cat >/root/paperless-ngx.creds <<EOF
Paperless-ngx Version: ${PAPERLESS_VERSION}
Paperless-ngx Secret Key: ${SECRET_KEY}
Paperless-ngx WebUI User: ${ADMIN_USER}
Paperless-ngx WebUI Password: ${ADMIN_PASSWORD}
PostgreSQL Database: ${DB_NAME}
PostgreSQL User: ${DB_USER}
PostgreSQL Password: ${DB_PASSWORD}
EOF
chmod 600 /root/paperless-ngx.creds

log "Python-Umgebung und Paperless-ngx einrichten"
cd "$INSTALL_DIR"
uv sync --python 3.13 --all-extras

cd "$INSTALL_DIR/src"
set -a
# shellcheck disable=SC1091
. "$INSTALL_DIR/paperless.conf"
set +a
uv run -- python manage.py migrate

PAPERLESS_ADMIN_USER="$ADMIN_USER" PAPERLESS_ADMIN_PASSWORD="$ADMIN_PASSWORD" uv run -- python manage.py shell <<'PYTHON'
import os
from django.contrib.auth import get_user_model

User = get_user_model()
username = os.environ["PAPERLESS_ADMIN_USER"]
password = os.environ["PAPERLESS_ADMIN_PASSWORD"]
user, _ = User.objects.get_or_create(username=username)
user.is_superuser = True
user.is_staff = True
user.set_password(password)
user.save()
PYTHON

mkdir -p /usr/share/nltk_data
uv run -- python - <<'PYTHON'
import nltk

for package in ("snowball_data", "stopwords", "punkt_tab"):
    if not nltk.download(package, download_dir="/usr/share/nltk_data", quiet=True):
        raise RuntimeError(f"NLTK-Paket konnte nicht geladen werden: {package}")
PYTHON

for policy_file in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml; do
  if [[ -f "$policy_file" ]]; then
    sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' "$policy_file"
  fi
done

log "systemd-Dienste erstellen"
cat >/etc/systemd/system/paperless-scheduler.service <<EOF
[Unit]
Description=Paperless Celery beat
Requires=redis-server.service
After=redis-server.service postgresql.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/src
ExecStart=/usr/local/bin/uv run -- celery --app paperless beat --loglevel INFO
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/paperless-task-queue.service <<EOF
[Unit]
Description=Paperless Celery workers
Requires=redis-server.service
After=redis-server.service postgresql.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/src
ExecStart=/usr/local/bin/uv run -- celery --app paperless worker --loglevel INFO
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/paperless-consumer.service <<EOF
[Unit]
Description=Paperless consumer
Requires=redis-server.service
After=redis-server.service postgresql.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/src
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/uv run -- python manage.py document_consumer
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/paperless-webserver.service <<EOF
[Unit]
Description=Paperless webserver
Wants=network-online.target
After=network-online.target redis-server.service postgresql.service
Requires=redis-server.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/src
ExecStart=/usr/local/bin/uv run -- granian --interface asginl --ws --loop uvloop "paperless.asgi:application"
Environment=GRANIAN_HOST=::
Environment=GRANIAN_PORT=8000
Environment=GRANIAN_WORKERS=1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now \
  paperless-webserver.service \
  paperless-scheduler.service \
  paperless-task-queue.service \
  paperless-consumer.service

sleep 3

if systemctl is-active --quiet paperless-webserver.service; then
  LXC_IP="$(hostname -I | awk '{print $1}')"
  printf '\n\033[1;32mPaperless-ngx %s wurde erfolgreich installiert.\033[0m\n' "$PAPERLESS_VERSION"
  printf 'Weboberfläche: http://%s:8000\n' "${LXC_IP:-LXC-IP}"
  printf 'Zugangsdaten: /root/paperless-ngx.creds\n'
else
  systemctl --no-pager --full status paperless-webserver.service || true
  fail "Der Paperless-Webserver konnte nicht gestartet werden."
fi
