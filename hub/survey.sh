#!/bin/sh
# RenderSys hub — READ-ONLY survey. Changes nothing, installs nothing.
#
# Run this on app.djbloknote.ru as root and send the whole output back.
# It answers the questions that decide how the hub is installed, so that the
# actual change can be prepared exactly instead of guessed at.

set -u
echo "=== RenderSys hub survey ==="
echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "host: $(hostname)"
echo

echo "--- os ---"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -a
echo "arch: $(uname -m)"
echo

echo "--- web server ---"
if command -v nginx >/dev/null 2>&1; then
  nginx -v 2>&1
  echo "config test: $(nginx -t 2>&1 | tr '\n' ' ')"
  echo "has stream module: $(nginx -V 2>&1 | grep -c -- --with-stream)"
  echo "site configs:"
  ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /'
  ls -1 /etc/nginx/conf.d/ 2>/dev/null | sed 's/^/  /'
  echo "server_name / listen lines:"
  grep -rhE '^\s*(server_name|listen)' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null \
    | sed 's/^/  /' | head -40
else
  echo "nginx NOT installed"
  command -v caddy >/dev/null 2>&1 && echo "caddy present: $(caddy version 2>&1)"
  command -v apache2 >/dev/null 2>&1 && echo "apache2 present"
  command -v docker >/dev/null 2>&1 && echo "docker present: $(docker --version 2>&1)"
fi
echo

echo "--- certificates ---"
ls -1 /etc/letsencrypt/live/ 2>/dev/null | sed 's/^/  /' || echo "  no letsencrypt dir"
echo

echo "--- listening sockets ---"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | sed 's/^/  /' | head -30
echo

echo "--- firewall ---"
command -v ufw >/dev/null 2>&1 && ufw status 2>&1 | head -12 | sed 's/^/  /'
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>&1 | sed 's/^/  /'
iptables -S 2>/dev/null | head -12 | sed 's/^/  /'
echo

echo "--- what is already running ---"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | awk '{print "  "$1}' | head -25
echo

echo "--- python and ssh ---"
echo "  python3: $(python3 -V 2>&1)"
echo "  sshd:    $(sshd -V 2>&1 | head -1 || ssh -V 2>&1)"
echo "  sshd port(s): $(grep -hE '^\s*Port' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tr '\n' ' ')"
echo

echo "--- disk and memory ---"
df -h / 2>/dev/null | tail -1 | sed 's/^/  /'
free -h 2>/dev/null | sed -n 2p | sed 's/^/  /'
echo
echo "=== end of survey ==="
