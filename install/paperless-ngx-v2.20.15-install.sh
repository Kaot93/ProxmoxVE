#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster) | MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://docs.paperless-ngx.com/ | Github: https://github.com/paperless-ngx/paperless-ngx

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies (Patience)"
$STD apt install -y \
  redis \
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
  unpaper \
  icc-profiles-free \
  qpdf \
  libleptonica6 \
  libxml2 \
  pngquant \
  zlib1g \
  tesseract-ocr \
  tesseract-ocr-eng \
  ghostscript
msg_ok "Installed Dependencies"

PG_VERSION="18" setup_postgresql
PG_DB_NAME="paperlessdb" PG_DB_USER="paperless" setup_postgresql_db
PYTHON_VERSION="3.13" setup_uv

# Pin Paperless-ngx to the requested release instead of resolving "latest".
PAPERLESS_VERSION="v2.20.15"
var_appversion="$PAPERLESS_VERSION"
fetch_and_deploy_gh_release "paperless" "paperless-ngx/paperless-ngx" "prebuild" "$PAPERLESS_VERSION" "/opt/paperless" "paperless*tar.xz"

msg_info "Setup Paperless-ngx"
cd /opt/paperless
rm -rf /opt/paperless/docker
$STD uv sync --all-extras
mkdir -p /opt/paperless_data/{consume,data,media,trash}
mkdir -p /opt/paperless/static
SECRET_KEY="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
cat <<EOF >~/paperless-ngx.creds

Paperless-ngx Secret Key: $SECRET_KEY
Paperless-ngx WebUI User: admin
Paperless-ngx WebUI Password: $PG_DB_PASS
EOF
sed -i \
  -e 's|#PAPERLESS_REDIS=redis://localhost:6379|PAPERLESS_REDIS=redis://localhost:6379|' \
  -e "s|#PAPERLESS_CONSUMPTION_DIR=../consume|PAPERLESS_CONSUMPTION_DIR=/opt/paperless_data/consume|" \
  -e "s|#PAPERLESS_DATA_DIR=../data|PAPERLESS_DATA_DIR=/opt/paperless_data/data|" \
  -e "s|#PAPERLESS_MEDIA_ROOT=../media|PAPERLESS_MEDIA_ROOT=/opt/paperless_data/media|" \
  -e "s|#PAPERLESS_EMPTY_TRASH_DIR=|PAPERLESS_EMPTY_TRASH_DIR=/opt/paperless_data/trash|" \
  -e "s|#PAPERLESS_STATICDIR=../static|PAPERLESS_STATICDIR=/opt/paperless/static|" \
  -e 's|#PAPERLESS_DBHOST=localhost|PAPERLESS_DBENGINE=postgresql\nPAPERLESS_DBHOST=localhost|' \
  -e 's|#PAPERLESS_DBPORT=5432|PAPERLESS_DBPORT=5432|' \
  -e "s|#PAPERLESS_DBNAME=paperless|PAPERLESS_DBNAME=$PG_DB_NAME|" \
  -e "s|#PAPERLESS_DBUSER=paperless|PAPERLESS_DBUSER=$PG_DB_USER|" \
  -e "s|#PAPERLESS_DBPASS=paperless|PAPERLESS_DBPASS=$PG_DB_PASS|" \
  -e "s|PAPERLESS_SECRET_KEY=change-me|PAPERLESS_SECRET_KEY=$SECRET_KEY|" \
  /opt/paperless/paperless.conf
cd /opt/paperless/src
set -a
. /opt/paperless/paperless.conf
set +a
$STD uv run -- python manage.py migrate
msg_ok "Setup Paperless-ngx"

msg_info "Setting up admin Paperless-ngx User & Password"
cat <<EOF | uv run -- python /opt/paperless/src/manage.py shell
from django.contrib.auth import get_user_model
UserModel = get_user_model()
user = UserModel.objects.create_user('admin', password='$PG_DB_PASS')
user.is_superuser = True
user.is_staff = True
user.save()
