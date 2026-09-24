#!/usr/bin/env bash
# Prepares a fresh Debian 13 / Ubuntu 24.04 Hetzner Cloud server for rewind:
#   Docker, Storage Box SMB mount, directories, compose file.
#
#   curl -fsSL https://raw.githubusercontent.com/DerSeb90/twitch-vod-archiver/main/deploy/setup-host.sh -o setup-host.sh
#   sudo SB_USER=u123456 SB_PASS='...' bash setup-host.sh
#
# SB_USER / SB_PASS: Storage Box (sub-)account with Samba enabled (Hetzner Console
# -> Storage Box -> Settings -> "SMB support"). Password is stored root-only in
# /etc/storagebox.cred, never in the repo.
set -euo pipefail

: "${SB_USER:?set SB_USER (e.g. u123456 or u123456-sub1)}"
: "${SB_PASS:?set SB_PASS}"
SB_HOST="${SB_HOST:-${SB_USER}.your-storagebox.de}"
# main account share is "backup", a sub-account's share is named like the sub-account
if [[ "$SB_USER" == *-sub* ]]; then SB_SHARE="${SB_SHARE:-$SB_USER}"; else SB_SHARE="${SB_SHARE:-backup}"; fi
MOUNT=/mnt/storagebox
APP_DIR=/opt/rewind
UID_APP=1000

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
. /etc/os-release

echo "==> packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl cifs-utils >/dev/null
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
fi

echo "==> storage box credentials"
umask 077
printf 'username=%s\npassword=%s\n' "$SB_USER" "$SB_PASS" > /etc/storagebox.cred
chmod 600 /etc/storagebox.cred
umask 022

echo "==> fstab (SMB 3, systemd automount, owned by uid ${UID_APP})"
mkdir -p "$MOUNT"
OPTS="vers=3.0,credentials=/etc/storagebox.cred,uid=${UID_APP},gid=${UID_APP},file_mode=0664,dir_mode=0775,iocharset=utf8,nofail,_netdev,x-systemd.automount,x-systemd.mount-timeout=30"
sed -i "\|[[:space:]]${MOUNT}[[:space:]]|d" /etc/fstab
echo "//${SB_HOST}/${SB_SHARE} ${MOUNT} cifs ${OPTS} 0 0" >> /etc/fstab
systemctl daemon-reload
systemctl restart remote-fs.target
ls "$MOUNT" >/dev/null   # trigger automount
mkdir -p "$MOUNT/rewind"

echo "==> directories"
mkdir -p "$APP_DIR/data" /srv/rewind/recordings
chown -R ${UID_APP}:${UID_APP} "$APP_DIR/data" /srv/rewind

echo "==> compose files"
BASE=https://raw.githubusercontent.com/DerSeb90/twitch-vod-archiver/main/deploy
curl -fsSL "$BASE/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
[[ -f "$APP_DIR/.env" ]] || curl -fsSL "$BASE/.env.example" -o "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

cat <<MSG

Done. Next:
  1. nano $APP_DIR/.env        (Twitch client id/secret, ADMIN_TOKEN, BIND_ADDR = VPN IP)
  2. cd $APP_DIR && docker compose up -d
  3. open http://<VPN-IP>:8080  -> /admin -> add channels
MSG
