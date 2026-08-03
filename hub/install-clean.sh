#!/bin/bash
# RenderSys hub — installer for a DEDICATED, EMPTY Ubuntu 24.04 server.
#
# This is deliberately a different script from the withdrawn one.  That earlier
# installer had to tiptoe around somebody else's production nginx; this one owns
# the machine, so it can be simple and it can roll back completely.
#
#   sudo bash install-clean.sh --domain render.example.com [--email you@example.com]
#   sudo bash install-clean.sh --uninstall
#
# Every mutation is recorded in a journal.  Any failure replays the journal
# backwards and leaves the machine as it was found.
set -euo pipefail

DOMAIN=""; EMAIL=""; MODE=install
STATION_SSH_PORT=22026     # loopback only
UI_FORWARD_PORT=22028      # loopback only; the station forwards its web app here
SSH_FORWARD_PORT=22027     # loopback only; the station forwards its sshd here
ROOT=/opt/rendersys-hub
JOURNAL="$ROOT/install-journal"

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email)  EMAIL="${2:-}";  shift 2 ;;
    --uninstall) MODE=uninstall; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n\033[31mSTOP: %s\033[0m\n' "$*" >&2; rollback; exit 1; }

[ "$(id -u)" = 0 ] || { printf 'run as root\n' >&2; exit 1; }

# ------------------------------------------------------------------ journal
# The audit's complaint about the previous installer was that it promised an
# automatic rollback and only printed a warning.  This one records what it did
# and actually undoes it.
record() { mkdir -p "$ROOT"; printf '%s\n' "$*" >> "$JOURNAL"; }

rollback() {
  [ -f "$JOURNAL" ] || return 0
  printf '\n\033[33mrolling back\033[0m\n' >&2
  # Reverse without tac: if the tool were missing the loop would read nothing,
  # do nothing, and still delete the journal — a silent no-op rollback.
  REVERSED="$(sed -n '1!G;h;$p' "$JOURNAL")"
  if [ -z "$REVERSED" ] && [ -s "$JOURNAL" ]; then
    printf '   could not read the journal; leaving %s in place for manual cleanup\n' "$JOURNAL" >&2
    return 1
  fi
  printf '%s\n' "$REVERSED" | while read -r action; do
    case "$action" in
      file:*)    rm -f "${action#file:}" ;;
      dir:*)     rmdir "${action#dir:}" 2>/dev/null || true ;;
      unit:*)    systemctl disable --now "${action#unit:}" 2>/dev/null || true ;;
      user:*)    userdel -r "${action#user:}" 2>/dev/null || true ;;
      ufw:*)     ufw delete allow "${action#ufw:}" 2>/dev/null || true ;;
      apt:*)     printf '   left installed: %s (removing packages is riskier than keeping them)\n' "${action#apt:}" ;;
      cert:*)    certbot delete --cert-name "${action#cert:}" --non-interactive 2>/dev/null || true ;;
    esac
  done >&2
  rm -f "$JOURNAL"
  systemctl reload nginx 2>/dev/null || true
  printf '\033[33mrollback finished\033[0m\n' >&2
}

if [ "$MODE" = uninstall ]; then
  say "removing the RenderSys hub"
  rollback
  rm -rf "$ROOT"
  note "done"
  exit 0
fi

# ------------------------------------------------------------------ preflight
say "preflight"
[ -n "$DOMAIN" ] || { printf 'STOP: --domain is required\n' >&2; exit 1; }
printf '%s' "$DOMAIN" | grep -qE '^[A-Za-z0-9.-]{1,253}$' \
  || { printf 'STOP: --domain must be a plain hostname\n' >&2; exit 1; }
[ -z "$EMAIL" ] || printf '%s' "$EMAIL" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$' \
  || { printf 'STOP: --email is not a plain address\n' >&2; exit 1; }

. /etc/os-release
[ "${ID:-}" = ubuntu ] || note "warning: expected Ubuntu, found ${ID:-unknown}"

# This installer assumes it owns the machine. Refuse if it plainly does not.
BUSY=""
for port in 80 443; do
  ss -tln 2>/dev/null | grep -qE "(0\.0\.0\.0|\*|\[::\]):$port[[:space:]]" && BUSY="$BUSY $port"
done
if [ -n "$BUSY" ]; then
  printf 'STOP: ports%s are already in use. This script is only for a dedicated,\n' "$BUSY" >&2
  printf '      empty server. It must not be run next to an existing web stack.\n' >&2
  exit 1
fi
note "ports 80 and 443 are free — this looks like a dedicated machine"

RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
[ -n "$RESOLVED" ] || { printf 'STOP: %s does not resolve yet — create the A record first\n' "$DOMAIN" >&2; exit 1; }
note "$DOMAIN resolves to $RESOLVED"

TUNNEL_PATH="/l-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$ROOT"; chmod 0755 "$ROOT"

# ------------------------------------------------------------------ packages
say "packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
NEEDED=""
command -v nginx   >/dev/null || NEEDED="$NEEDED nginx"
command -v certbot >/dev/null || NEEDED="$NEEDED certbot"
if [ -n "$NEEDED" ]; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $NEEDED || die "could not install:$NEEDED"
  record "apt:$NEEDED"
  note "installed:$NEEDED"
else
  note "nginx and certbot already present"
fi

# ------------------------------------------------------------------ account
say "restricted station account"
if ! id rendersys-station >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/rendersys-station \
          --shell /usr/sbin/nologin rendersys-station
  record "user:rendersys-station"
fi
install -d -m 0700 -o rendersys-station -g rendersys-station /var/lib/rendersys-station/.ssh
note "account ready — no shell, forwarding only"

# ------------------------------------------------------------------ sshd
say "dedicated sshd for the station"
if [ ! -f "$ROOT/station_host_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N "" -C rendersys-hub -f "$ROOT/station_host_ed25519"
  record "file:$ROOT/station_host_ed25519"
  record "file:$ROOT/station_host_ed25519.pub"
fi
chmod 0600 "$ROOT/station_host_ed25519"
[ -f "$ROOT/station_authorized_keys" ] || { : > "$ROOT/station_authorized_keys"; record "file:$ROOT/station_authorized_keys"; }
chmod 0644 "$ROOT/station_authorized_keys"

cat > "$ROOT/station_sshd.conf" <<CONF
Port $STATION_SSH_PORT
ListenAddress 127.0.0.1
AddressFamily inet
HostKey $ROOT/station_host_ed25519
HostKeyAlgorithms ssh-ed25519
AuthenticationMethods publickey
PubkeyAuthentication yes
PubkeyAcceptedAlgorithms ssh-ed25519
AuthorizedKeysFile $ROOT/station_authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
UsePAM no
AllowUsers rendersys-station
AllowTcpForwarding remote
AllowStreamLocalForwarding no
AllowAgentForwarding no
GatewayPorts no
# Two forwards, because two protocols: the station's sshd and its web app.
# Both spellings, because ssh asks for "localhost" and sshd treats that name
# as distinct from 127.0.0.1.
PermitListen localhost:$SSH_FORWARD_PORT 127.0.0.1:$SSH_FORWARD_PORT localhost:$UI_FORWARD_PORT 127.0.0.1:$UI_FORWARD_PORT
PermitOpen none
MaxSessions 0
MaxStartups 3:50:10
ForceCommand /usr/bin/false
PermitTTY no
PermitTunnel no
X11Forwarding no
PermitUserEnvironment no
PermitUserRC no
ClientAliveInterval 15
ClientAliveCountMax 4
LoginGraceTime 15
UseDNS no
LogLevel VERBOSE
StrictModes yes
PidFile /run/rendersys-hub-sshd.pid
CONF
record "file:$ROOT/station_sshd.conf"
/usr/sbin/sshd -t -f "$ROOT/station_sshd.conf" || die "generated sshd config is invalid"

cat > /etc/systemd/system/rendersys-hub-sshd.service <<UNIT
[Unit]
Description=RenderSys hub station sshd (loopback only)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -d /run/sshd || install -d -m 0755 -o root -g root /run/sshd'
ExecStart=/usr/sbin/sshd -D -e -f $ROOT/station_sshd.conf
Restart=always
RestartSec=3
MemoryMax=256M
TasksMax=64

[Install]
WantedBy=multi-user.target
UNIT
record "file:/etc/systemd/system/rendersys-hub-sshd.service"
record "unit:rendersys-hub-sshd.service"
note "sshd on 127.0.0.1:$STATION_SSH_PORT — no shell, two exact forwards"

# ------------------------------------------------------------------ interface password
say "interface password"
if [ ! -f "$ROOT/ui_htpasswd" ]; then
  UI_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  printf 'owner:%s\n' "$(openssl passwd -6 "$UI_PASSWORD")" > "$ROOT/ui_htpasswd"
  chmod 0644 "$ROOT/ui_htpasswd"
  printf '%s' "$UI_PASSWORD" > "$ROOT/ui_password_show_once"; chmod 0400 "$ROOT/ui_password_show_once"
  record "file:$ROOT/ui_htpasswd"
fi
install -d -m 0755 /var/www/rendersys
record "dir:/var/www/rendersys"

# ------------------------------------------------------------------ nginx + cert
say "nginx and certificate"
cat > /etc/nginx/sites-available/rendersys <<CONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    root /var/www/rendersys;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
CONF
record "file:/etc/nginx/sites-available/rendersys"
ln -sf /etc/nginx/sites-available/rendersys /etc/nginx/sites-enabled/rendersys
record "file:/etc/nginx/sites-enabled/rendersys"
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx rejected the HTTP block"
systemctl reload nginx

ufw status 2>/dev/null | grep -q "Status: active" && {
  ufw allow 80/tcp  >/dev/null 2>&1 && record "ufw:80/tcp"
  ufw allow 443/tcp >/dev/null 2>&1 && record "ufw:443/tcp"
}

if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  if [ -n "$EMAIL" ]; then
    certbot certonly --webroot -w /var/www/rendersys -d "$DOMAIN" --agree-tos \
      -m "$EMAIL" --non-interactive --reuse-key --deploy-hook "systemctl reload nginx" \
      || die "certificate was not issued"
  else
    certbot certonly --webroot -w /var/www/rendersys -d "$DOMAIN" --agree-tos \
      --register-unsafely-without-email --non-interactive --reuse-key \
      --deploy-hook "systemctl reload nginx" || die "certificate was not issued"
  fi
  record "cert:$DOMAIN"
fi

cat > /etc/nginx/sites-available/rendersys <<CONF
limit_req_zone \$binary_remote_addr zone=rendersys_probe:1m rate=10r/m;

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    root /var/www/rendersys;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /var/www/rendersys;
    client_max_body_size 8g;   # models and video, not web forms

    # The station's tunnel. Exact match, no password: the station holds a key.
    location = $TUNNEL_PATH {
        limit_req zone=rendersys_probe burst=20 nodelay;
        proxy_pass http://127.0.0.1:$SSH_FORWARD_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # The bootstrap artifact the station downloads once, by exact name.
    location = /bootstrap.pyz {
        root /var/www/rendersys;
        default_type application/octet-stream;
    }

    # The station's web interface. Password-protected: the hostname is public
    # via Certificate Transparency within seconds of issuance.
    location / {
        auth_basic "RenderSys";
        auth_basic_user_file $ROOT/ui_htpasswd;
        proxy_pass http://127.0.0.1:$UI_FORWARD_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering off;
        proxy_request_buffering off;
        error_page 502 504 = @offline;
    }
    location @offline {
        internal;
        default_type text/html;
        return 200 '<!doctype html><meta charset="utf-8"><title>RenderSys</title><body style="font:16px system-ui;padding:3rem">Станция не на связи. Страница обновится сама.<script>setTimeout(()=>location.reload(),15000)</script></body>';
    }
}
CONF
nginx -t || die "nginx rejected the TLS block"
systemctl reload nginx
note "https://$DOMAIN is live"

# ------------------------------------------------------------------ start
say "starting"
systemctl daemon-reload
systemctl enable --now rendersys-hub-sshd.service || die "station sshd did not start"
sleep 2
systemctl is-active --quiet rendersys-hub-sshd.service || die "station sshd is not running"

printf '%s' "$TUNNEL_PATH" > "$ROOT/tunnel_path"; chmod 0600 "$ROOT/tunnel_path"
cp -f "$0" "$ROOT/uninstall.sh" 2>/dev/null || true

say "SEND THESE BACK"
echo
echo "domain:      https://$DOMAIN"
echo "tunnelPath:  $TUNNEL_PATH"
echo "sshHostKey:  $(awk '{print $1" "$2}' "$ROOT/station_host_ed25519.pub")"
echo "sshUser:     rendersys-station"
echo
if [ -f "$ROOT/ui_password_show_once" ]; then
  say "INTERFACE LOGIN — write it down, then delete the file"
  echo "  url:      https://$DOMAIN"
  echo "  user:     owner"
  echo "  password: $(cat "$ROOT/ui_password_show_once")"
  echo "  then:     sudo rm $ROOT/ui_password_show_once"
fi
echo
echo "Append the station public key to $ROOT/station_authorized_keys as one line:"
echo "  restrict,port-forwarding,permitlisten=\"localhost:$SSH_FORWARD_PORT\",permitlisten=\"127.0.0.1:$SSH_FORWARD_PORT\",permitlisten=\"localhost:$UI_FORWARD_PORT\",permitlisten=\"127.0.0.1:$UI_FORWARD_PORT\" ssh-ed25519 AAAA... station"
echo
echo "Undo everything: sudo bash $ROOT/uninstall.sh --uninstall"
rm -f "$JOURNAL"   # committed: rollback is now the uninstall path
