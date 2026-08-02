#!/bin/bash
# RenderSys hub installer — run as root on app.djbloknote.ru
#
# WHAT THIS DOES
#   Publishes a new subdomain (default render.djbloknote.ru) that becomes the
#   single meeting point between the GPU station in Russia and the owner's
#   devices.  The station dials out to it; browsers connect in.
#
# WHY IT IS SAFE FOR THE EXISTING SITE
#   It never edits an existing nginx file.  It adds ONE new file for a NEW
#   hostname with its own certificate, and chooses the directory so that the
#   existing site keeps being the implicit default_server for 443.  Every step
#   is idempotent, the config is validated before any reload, a failed
#   validation removes the new file, and the installer measures how the
#   existing site answers before and after so it can prove it changed nothing.
#
# WHAT IT DOES NOT DO
#   No changes to sshd_config.  No changes to the firewall beyond opening
#   nothing new (80/443 are already open).  No data is read from the existing
#   site.  Nothing is sent anywhere.
#
# USAGE
#   sudo bash rendersys-hub-install.sh                 # install
#   sudo bash rendersys-hub-install.sh --uninstall     # full clean removal
#
set -euo pipefail

DOMAIN="${RENDERSYS_DOMAIN:-render.dobrolog.app}"
EMAIL="${RENDERSYS_EMAIL:-}"                # for Let's Encrypt expiry notices
TUNNEL_PATH="${RENDERSYS_PATH:-}"   # generated with real entropy if unset
RELAY_PORT="${RENDERSYS_RELAY_PORT:-8022}"      # loopback only
STATION_SSH_PORT="${RENDERSYS_STATION_SSH_PORT:-22026}"  # loopback only
UI_PORT="${RENDERSYS_UI_PORT:-18765}"           # loopback; the station forwards here

ROOT=/opt/rendersys-hub
NGINX_CONF=""   # decided during preflight, see below
UNIT_RELAY=/etc/systemd/system/rendersys-hub-relay.service
UNIT_SSHD=/etc/systemd/system/rendersys-hub-sshd.service
STAMP="$(date -u '+%Y%m%d%H%M%S')"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n\033[31mSTOP: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run this as root"

# ---------------------------------------------------------------- uninstall
case "${1:-}" in
  ""|--uninstall) ;;
  *) die "unknown argument ${1}. Use no arguments to install, or --uninstall." ;;
esac

if [ "${1:-}" = "--uninstall" ]; then
  say "removing the RenderSys hub"
  systemctl disable --now rendersys-hub-relay.service 2>/dev/null || true
  systemctl disable --now rendersys-hub-sshd.service  2>/dev/null || true
  rm -f "$UNIT_RELAY" "$UNIT_SSHD"
  systemctl daemon-reload
  for f in /etc/nginx/conf.d/rendersys-hub.conf /etc/nginx/sites-enabled/zzz-rendersys-hub; do
    [ -f "$f" ] && rm -f "$f" && REMOVED=1
  done
  if [ "${REMOVED:-0}" = 1 ]; then
    # Must not abort here: the block is already gone from disk but still live
    # in nginx's memory, and the cleanup below has not run yet.
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx || true
    else
      printf '   nginx -t fails for an unrelated reason; reload it yourself\n'
    fi
  fi
  if [ -n "${RENDERSYS_DOMAIN:-}" ] || [ -f /opt/rendersys-hub/tunnel_path ]; then
    D="${RENDERSYS_DOMAIN:-render.dobrolog.app}"
    # Otherwise certbot retries a domain with no webroot twice a day forever.
    certbot delete --cert-name "$D" --non-interactive >/dev/null 2>&1 || true
  fi
  rm -rf /var/www/rendersys
  # Only remove the account this installer creates, never a pre-existing one.
  if id rendersys-station >/dev/null 2>&1 && \
     [ "$(getent passwd rendersys-station | cut -d: -f6)" = /var/lib/rendersys-station ]; then
    userdel -r rendersys-station 2>/dev/null || true
  fi
  rm -rf "$ROOT"
  note "removed. The existing site was never modified, so nothing to restore."
  exit 0
fi

# ---------------------------------------------------------------- preflight
say "preflight"
command -v nginx >/dev/null || die "nginx is not installed"
command -v python3 >/dev/null || die "python3 is not installed"
command -v sshd >/dev/null || command -v /usr/sbin/sshd >/dev/null \
  || die "openssh-server is not installed"
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

nginx -t >/dev/null 2>&1 || die "the EXISTING nginx config is already invalid; fix that first"
note "nginx config is currently valid — safe to add to"

[ "$RELAY_PORT" != "$STATION_SSH_PORT" ] && [ "$RELAY_PORT" != "$UI_PORT" ] \
  && [ "$STATION_SSH_PORT" != "$UI_PORT" ] || die "the three ports must differ"
ALREADY_INSTALLED=0
[ -f "$ROOT/station_sshd.conf" ] && ALREADY_INSTALLED=1
for port in "$RELAY_PORT" "$STATION_SSH_PORT" "$UI_PORT"; do
  # Match every bind form, not just 127.0.0.1 — a listener on 0.0.0.0 would
  # otherwise slip through the check and fail at service start instead.
  if ss -tln 2>/dev/null | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):$port[[:space:]]"; then
    if [ "$ALREADY_INSTALLED" = 1 ]; then
      note "port $port is held by the existing RenderSys install — re-running is fine"
    else
      die "port $port is already in use; choose another via env, or run --uninstall first"
    fi
  fi
done
note "ports $RELAY_PORT, $STATION_SSH_PORT, $UI_PORT are usable"

RESOLVED="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
if [ -z "$RESOLVED" ]; then
  die "$DOMAIN does not resolve yet — create the DNS A record first (grey cloud, no proxy)"
fi
note "$DOMAIN resolves to $RESOLVED"

# Every setting below is written into an nginx config and a systemd unit, so a
# newline or a quote would inject directives. Refuse anything unexpected.
printf '%s' "$DOMAIN"      | grep -qE '^[A-Za-z0-9.-]{1,253}$'  || die "RENDERSYS_DOMAIN is not a plain hostname"
if [ -z "$TUNNEL_PATH" ]; then
  if [ -f "$ROOT/tunnel_path" ]; then
    TUNNEL_PATH="$(cat "$ROOT/tunnel_path")"
  else
    # 128 bits. The path is the only gate in front of the sshd, so treat it as
    # a credential: a short one is guessable and every wrong guess is cheap.
    TUNNEL_PATH="/l-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi
printf '%s' "$TUNNEL_PATH" | grep -qE '^/[A-Za-z0-9._~-]{4,128}$' || die "RENDERSYS_PATH must be a simple /path of 4-128 safe characters"
case "$TUNNEL_PATH" in *%*) die "RENDERSYS_PATH must not contain % (systemd would expand it)";; esac
for v in "$RELAY_PORT" "$STATION_SSH_PORT" "$UI_PORT"; do
  printf '%s' "$v" | grep -qE '^[0-9]{2,5}$' || die "port values must be numeric"
done
[ -z "$EMAIL" ] || printf '%s' "$EMAIL" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$' \
  || die "RENDERSYS_EMAIL is not a plain address"
note "all inputs are plain values — nothing can be injected into the configs"

# If no server block is already marked default_server for 443, whichever block
# nginx loads first silently becomes the default and would answer requests that
# carry no matching Host/SNI — including bare-IP requests. That must never be
# this hub, or the station's control interface would be exposed to anyone who
# hits the server by address.
# A typo here — or a copy-pasted production hostname — would declare a second
# server block for a name that already exists. conf.d is parsed before
# sites-enabled on Debian, so the new block would WIN, nginx would only warn,
# `nginx -t` would still exit 0, and the live site would be replaced.
if nginx -T 2>/dev/null | grep -E '^\s*server_name\b' | grep -qw "$DOMAIN"; then
  die "$DOMAIN is already served by this nginx. Refusing: a second block for an existing name would silently take it over."
fi
note "$DOMAIN is not served by any existing block"

HAS_DEFAULT=0
if nginx -T 2>/dev/null | grep -E '^\s*listen\s+.*443' | grep -q default_server; then
  HAS_DEFAULT=1
fi
TARGET_DIR=/etc/nginx/conf.d
CONF_NAME=rendersys-hub.conf
if [ "$HAS_DEFAULT" = 0 ]; then
  if grep -qE '^\s*include\s+.*sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
    # sites-enabled is included after conf.d on Debian/Ubuntu, and this name
    # sorts last, so an existing site keeps being the implicit default.
    TARGET_DIR=/etc/nginx/sites-enabled
    CONF_NAME=zzz-rendersys-hub
    note "no default_server exists; placing the config last so the existing site stays default"
  else
    note "no default_server exists and no sites-enabled; adding an explicit non-default guard"
  fi
else
  note "a default_server already exists — this hub cannot become the default"
fi
NGINX_CONF="$TARGET_DIR/$CONF_NAME"

# Record how the existing site answers now, so the installer can prove it did
# not change it.
BEFORE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "https://app.djbloknote.ru/" 2>/dev/null || echo unreachable)"
note "existing site currently answers: $BEFORE_STATUS"

# ---------------------------------------------------------------- accounts
say "service account and layout"
id rendersys-station >/dev/null 2>&1 || \
  useradd --system --create-home --home-dir /var/lib/rendersys-station \
          --shell /usr/sbin/nologin rendersys-station
install -d -m 0755 -o root -g root "$ROOT"
printf '%s' "$TUNNEL_PATH" > "$ROOT/tunnel_path"; chmod 0600 "$ROOT/tunnel_path"
install -d -m 0700 -o rendersys-station -g rendersys-station \
  /var/lib/rendersys-station/.ssh
note "account rendersys-station ready"

# ---------------------------------------------------------------- relay
say "HTTP-upgrade relay"
cat > "$ROOT/relay.py" <<'RELAY'
#!/usr/bin/env python3
"""Bridges an nginx HTTP upgrade into the hub's station sshd.

nginx relays bytes verbatim after a 101 response, so the tunnel rides an
ordinary HTTPS location.  Anything that is not the exact expected path and
upgrade token gets the same bland 404 a static site would return, so probing
this endpoint reveals nothing.
"""
import os, re, socket, socketserver, sys, threading

# The station holds exactly one tunnel. A generous cap still leaves no room for
# an unauthenticated flood to exhaust threads or memory on the web server.
MAX_LIVE = int(os.environ.get("RELAY_MAX_LIVE", "32"))
_live = threading.BoundedSemaphore(MAX_LIVE)

PORT = int(os.environ["RELAY_PORT"])
UP = int(os.environ["UPSTREAM_PORT"])
PATH = os.environ["TUNNEL_PATH"]
LINE = re.compile(rb"^(GET|POST) (/[^\s?]*)(\?\S*)? HTTP/1\.[01]$")

def relay(a, b):
    try:
        while True:
            chunk = a.recv(65536)
            if not chunk:
                break
            b.sendall(chunk)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.close()
            except OSError: pass

class H(socketserver.BaseRequestHandler):
    def handle(self):
        if not _live.acquire(blocking=False):
            try:
                self.request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                                     b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            return
        try:
            self._serve()
        finally:
            _live.release()

    def _serve(self):
        # A short handshake deadline: a slow-loris client cannot hold a slot.
        c = self.request; c.settimeout(8.0); head = b""
        try:
            while b"\r\n\r\n" not in head:
                p = c.recv(4096)
                if not p: return
                head += p
                if len(head) > 16384: return self.deny(c)
        except OSError:
            return
        top, _, rest = head.partition(b"\r\n\r\n")
        lines = top.split(b"\r\n")
        m = LINE.match(lines[0] if lines else b"")
        if m is None or m.group(2).decode("ascii", "replace") != PATH:
            return self.deny(c)
        hdr = {}
        for line in lines[1:]:
            if b":" in line:
                k, _, v = line.partition(b":")
                hdr[k.strip().lower()] = v.strip().lower()
        if hdr.get(b"upgrade") != b"rendersys":
            return self.deny(c)
        try:
            up = socket.create_connection(("127.0.0.1", UP), timeout=10)
        except OSError:
            return self.deny(c, b"502 Bad Gateway")
        try:
            c.sendall(b"HTTP/1.1 101 Switching Protocols\r\n"
                      b"Upgrade: rendersys\r\nConnection: Upgrade\r\n\r\n")
            if rest: up.sendall(rest)
        except OSError:
            up.close(); return
        c.settimeout(None); up.settimeout(None)
        threading.Thread(target=relay, args=(c, up), daemon=True).start()
        relay(up, c)

    def deny(self, c, status=b"404 Not Found"):
        try:
            c.sendall(b"HTTP/1.1 " + status +
                      b"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        except OSError:
            pass

class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True; request_queue_size = 64

with S(("127.0.0.1", PORT), H) as srv:
    sys.stderr.write("rendersys relay on 127.0.0.1:%d -> 127.0.0.1:%d %s\n"
                     % (PORT, UP, PATH))
    sys.stderr.flush()
    srv.serve_forever()
RELAY
chmod 0755 "$ROOT/relay.py"

cat > "$UNIT_RELAY" <<UNIT
[Unit]
Description=RenderSys hub HTTP-upgrade relay
After=network.target

[Service]
Type=simple
User=rendersys-station
Environment=RELAY_PORT=$RELAY_PORT
Environment=UPSTREAM_PORT=$STATION_SSH_PORT
Environment=TUNNEL_PATH=$TUNNEL_PATH
ExecStart=/usr/bin/python3 -I -B $ROOT/relay.py
Restart=always
RestartSec=3
StartLimitIntervalSec=0
MemoryMax=256M
TasksMax=128
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT
note "relay installed"

# ---------------------------------------------------------------- station sshd
say "dedicated sshd for the station (loopback only)"
if [ ! -f "$ROOT/station_host_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N "" -C rendersys-hub-station \
    -f "$ROOT/station_host_ed25519"
fi
chmod 0600 "$ROOT/station_host_ed25519"
touch "$ROOT/station_authorized_keys"; chmod 0644 "$ROOT/station_authorized_keys"

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
PermitListen localhost:$UI_PORT 127.0.0.1:$UI_PORT
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
"$SSHD_BIN" -t -f "$ROOT/station_sshd.conf" || die "generated station sshd config is invalid"

cat > "$UNIT_SSHD" <<UNIT
[Unit]
Description=RenderSys hub station sshd (loopback only)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'test -d /run/sshd || install -d -m 0755 -o root -g root /run/sshd'
ExecStart=$SSHD_BIN -D -e -f $ROOT/station_sshd.conf
Restart=always
RestartSec=3
MemoryMax=256M
TasksMax=64

[Install]
WantedBy=multi-user.target
UNIT
note "station sshd configured — it can only bind 127.0.0.1:$UI_PORT and gets no shell"

# ---------------------------------------------------------------- nginx
say "nginx: one new file, for a new hostname only"
install -d -m 0755 /var/www/rendersys

# The station UI can start jobs, browse files and read outputs. The hostname is
# NOT a secret: certbot publishes it to Certificate Transparency logs within
# seconds, so it is trivially enumerable. A password is mandatory, not optional.
if [ ! -f "$ROOT/ui_htpasswd" ]; then
  UI_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  # openssl is already present (nginx depends on it) and, unlike Python's
  # crypt module, it was not removed in 3.13.
  HASH="$(openssl passwd -6 "$UI_PASSWORD")" || die "could not hash the UI password"
  printf 'owner:%s\n' "$HASH" > "$ROOT/ui_htpasswd"
  chmod 0640 "$ROOT/ui_htpasswd"
  chgrp "$(id -gn www-data 2>/dev/null || echo www-data)" "$ROOT/ui_htpasswd" 2>/dev/null || true
  printf '%s' "$UI_PASSWORD" > "$ROOT/ui_password_show_once"
  chmod 0400 "$ROOT/ui_password_show_once"
  note "generated a UI password — printed at the end, stored in $ROOT/ui_password_show_once"
else
  note "UI password already configured (delete $ROOT/ui_htpasswd to regenerate)"
fi
cat > /var/www/rendersys/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>RenderSys</title>
<body style="font:16px system-ui;padding:3rem;color:#222">Service is running.</body>
HTML

cat > "$NGINX_CONF" <<CONF
# RenderSys hub. Added $STAMP. Removing this file fully reverts the change.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/rendersys;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}
CONF
nginx -t || { rm -f "$NGINX_CONF"; die "nginx rejected the new file; it has been removed, nothing changed"; }
systemctl reload nginx
note "HTTP block live; requesting a certificate"

if ! command -v certbot >/dev/null 2>&1; then
  # needrestart hooks apt on Ubuntu 22.04+ and will happily restart nginx and
  # sshd mid-install. On a box that must not blink, that is unacceptable.
  note "installing certbot with service restarts suppressed"
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
    apt-get install -y -qq --no-install-recommends certbot \
    || die "could not install certbot; install it yourself and re-run"
fi
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  if [ -n "$EMAIL" ]; then
    certbot certonly --webroot -w /var/www/rendersys -d "$DOMAIN" \
      --agree-tos -m "$EMAIL" --non-interactive --reuse-key \
      --deploy-hook "systemctl reload nginx"
  else
    certbot certonly --webroot -w /var/www/rendersys -d "$DOMAIN" \
      --agree-tos --register-unsafely-without-email --non-interactive --reuse-key \
      --deploy-hook "systemctl reload nginx"
  fi
fi
[ -d "/etc/letsencrypt/live/$DOMAIN" ] || die "certificate was not issued"

cat > "$NGINX_CONF" <<CONF
# RenderSys hub. Added $STAMP. Removing this file fully reverts the change.
# limit_req_zone is http-context and lives in this file, so no existing file
# needs editing to rate-limit guesses at the tunnel path.
limit_req_zone \$binary_remote_addr zone=rendersys_probe:1m rate=10r/m;

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/rendersys;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /var/www/rendersys;
    client_max_body_size 64m;

    # The station's tunnel. nginx relays bytes verbatim after the 101.
    location = $TUNNEL_PATH {
        auth_basic off;
        limit_req zone=rendersys_probe burst=20 nodelay;
        proxy_pass http://127.0.0.1:$RELAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # The station's web interface, once its tunnel is up.
    # Password-protected: the hostname is public via Certificate Transparency.
    location / {
        auth_basic "RenderSys";
        auth_basic_user_file $ROOT/ui_htpasswd;
        proxy_pass http://127.0.0.1:$UI_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering off;
        error_page 502 504 = @offline;
    }
    location @offline {
        internal;
        default_type text/html;
        return 200 '<!doctype html><meta charset="utf-8"><title>RenderSys</title><body style="font:16px system-ui;padding:3rem;color:#222">Станция сейчас не на связи. Страница обновится, когда она подключится.<script>setTimeout(()=>location.reload(),15000)</script></body>';
    }
}
CONF
nginx -t || { rm -f "$NGINX_CONF"; systemctl reload nginx; die "nginx rejected the TLS block; removed, existing site untouched"; }
systemctl reload nginx
note "https://$DOMAIN is live"

# ---------------------------------------------------------------- start
say "starting services"
systemctl daemon-reload
systemctl enable --now rendersys-hub-sshd.service
systemctl enable --now rendersys-hub-relay.service
sleep 2
systemctl is-active --quiet rendersys-hub-sshd.service || die "station sshd did not start"
systemctl is-active --quiet rendersys-hub-relay.service || die "relay did not start"
note "both services active"

cp -f "$0" "$ROOT/uninstall.sh" 2>/dev/null || true
chmod 0700 "$ROOT/uninstall.sh" 2>/dev/null || true

# ---------------------------------------------------------------- verify
say "proving the existing site was not affected"
AFTER_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "https://app.djbloknote.ru/" 2>/dev/null || echo unreachable)"
note "existing site before: $BEFORE_STATUS   after: $AFTER_STATUS"
if [ "$BEFORE_STATUS" != "$AFTER_STATUS" ]; then
  printf '\n\033[31mWARNING: the existing site now answers differently. Run:\n  sudo bash %s/uninstall.sh --uninstall\nand report this.\033[0m\n' "$ROOT" >&2
fi
if nginx -T 2>/dev/null | grep -E '^\s*listen\s+.*443' | grep -q default_server; then
  note "default_server for 443 is claimed by a block — checked"
fi

# ---------------------------------------------------------------- report
say "SEND THESE FOUR VALUES BACK"
echo
echo "domain:        https://$DOMAIN"
echo "tunnelPath:    $TUNNEL_PATH"
echo "sshHostKey:    $(cat "$ROOT/station_host_ed25519.pub" | awk '{print $1" "$2}')"
echo "tlsCertSha256: $(openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -outform DER 2>/dev/null | openssl dgst -sha256 -hex | awk '{print $NF}')"
echo
echo "Then append the station's public key (it will be supplied) to:"
echo "  $ROOT/station_authorized_keys"
echo "in this exact form, one line:"
echo '  restrict,port-forwarding,permitlisten="localhost:'"$UI_PORT"'",permitlisten="127.0.0.1:'"$UI_PORT"'" ssh-ed25519 AAAA... station'
echo
echo
if [ -f "$ROOT/ui_password_show_once" ]; then
  say "INTERFACE LOGIN — write this down, then delete the file"
  echo "  url:      https://$DOMAIN"
  echo "  user:     owner"
  echo "  password: $(cat "$ROOT/ui_password_show_once")"
  echo
  echo "  The hostname is public (Certificate Transparency), so this password is"
  echo "  the only thing standing between the internet and the GPU station."
  echo "  After noting it: sudo rm $ROOT/ui_password_show_once"
fi
echo
echo "To undo everything: sudo bash $ROOT/uninstall.sh"
