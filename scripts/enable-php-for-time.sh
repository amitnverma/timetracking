#!/usr/bin/env bash
# Enable PHP-FPM for /time ONLY on this CloudPanel/Hostinger nginx VPS.
# Does not change other websites. Safe to re-run (idempotent).
#
# Requires root (CloudPanel admin / sudo):
#   sudo bash /home/cloudmosaicaissh/htdocs/cloudmosaic.ai/time/scripts/enable-php-for-time.sh
#
# Verify:
#   curl -sS https://cloudmosaic.ai/time/hello.php
# Expected: {"ok":true,"php":"..."} — not raw <?php source.

set -euo pipefail

DOMAIN="${TIME_DOMAIN:-cloudmosaic.ai}"
SITE_ROOT="${TIME_SITE_ROOT:-/home/cloudmosaicai/htdocs/${DOMAIN}}"
TIME_URI="${TIME_URI_PREFIX:-/time}"
SNIPPET_NAME="time-php-${DOMAIN}.conf"
MARKER_BEGIN="# BEGIN time-tracking-php"
MARKER_END="# END time-tracking-php"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

if [[ ! -d "$SITE_ROOT/time" ]]; then
  echo "Missing app folder: $SITE_ROOT/time"
  exit 1
fi

detect_fpm() {
  # CloudPanel per-site pools often listen on 127.0.0.1:2xxxx
  local pool=""
  for pool in \
    "/etc/php/8.5/fpm/pool.d/${DOMAIN}.conf" \
    "/etc/php/8.4/fpm/pool.d/${DOMAIN}.conf" \
    "/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf" \
    "/etc/php/8.2/fpm/pool.d/${DOMAIN}.conf" \
    "/etc/php/8.1/fpm/pool.d/${DOMAIN}.conf"
  do
    if [[ -r "$pool" ]]; then
      local listen
      listen="$(awk -F= '/^listen[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$pool")"
      if [[ -n "$listen" ]]; then
        if [[ "$listen" == /* ]]; then
          echo "unix:$listen"
        else
          echo "$listen"
        fi
        return 0
      fi
    fi
  done

  local sock
  for sock in \
    /run/php/php8.5-fpm.sock \
    /run/php/php8.4-fpm.sock \
    /run/php/php8.3-fpm.sock \
    /run/php/php8.2-fpm.sock \
    /run/php/php8.1-fpm.sock \
    /var/run/php/php8.2-fpm.sock \
    /run/php/php-fpm.sock
  do
    if [[ -S "$sock" ]]; then
      echo "unix:$sock"
      return 0
    fi
  done
  return 1
}

FPM_PASS="$(detect_fpm || true)"
if [[ -z "${FPM_PASS}" ]]; then
  echo "Could not detect PHP-FPM listen address for ${DOMAIN}."
  echo "In CloudPanel: Sites → ${DOMAIN} → confirm PHP is enabled, then re-run."
  exit 1
fi
echo "Using PHP-FPM: $FPM_PASS"

SNIPPET_DIR="/etc/nginx/snippets"
mkdir -p "$SNIPPET_DIR"
SNIPPET_PATH="$SNIPPET_DIR/$SNIPPET_NAME"

cat > "$SNIPPET_PATH" <<EOF
${MARKER_BEGIN}
# Scoped to ${TIME_URI}/ under ${DOMAIN} only — other sites untouched.
location ^~ ${TIME_URI}/ {
    root ${SITE_ROOT};
    index index.html index.php;
    try_files \$uri \$uri/ =404;

    location ~ \\.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass ${FPM_PASS};
        fastcgi_read_timeout 60s;
    }
}
${MARKER_END}
EOF
echo "Wrote $SNIPPET_PATH"

INCLUDE_LINE="    include ${SNIPPET_PATH};"
mapfile -t CONF_CANDIDATES < <(
  grep -Rsl --include='*.conf' -E "server_name[[:space:]].*${DOMAIN}|${SITE_ROOT}" /etc/nginx 2>/dev/null || true
)

if [[ "${#CONF_CANDIDATES[@]}" -eq 0 ]]; then
  echo "Could not auto-detect nginx vhost for ${DOMAIN}."
  echo "CloudPanel UI alternate (no other sites touched):"
  echo "  Sites → ${DOMAIN} → Vhost / Nginx → Additional Nginx Directives"
  echo "Paste the contents of ${SNIPPET_PATH}, save, and reload."
  echo "Or add inside the server block: include ${SNIPPET_PATH};"
  exit 2
fi

UPDATED=0
for conf in "${CONF_CANDIDATES[@]}"; do
  if grep -Fq "$SNIPPET_PATH" "$conf"; then
    echo "Already included in $conf"
    UPDATED=1
    continue
  fi
  if grep -q 'server_name' "$conf" && grep -q "$DOMAIN" "$conf"; then
    python3 - "$conf" "$INCLUDE_LINE" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
include_line = sys.argv[2].rstrip() + "\n"
text = path.read_text()
if include_line.strip() in text:
    print(f"skip {path}")
    raise SystemExit(0)
lines = text.splitlines(True)
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.lstrip().startswith("server {"):
        out.append(include_line)
        inserted = True
if not inserted:
    out.append("\n" + include_line)
path.write_text("".join(out))
print(f"updated {path}")
PY
    UPDATED=1
  fi
done

if [[ "$UPDATED" -eq 0 ]]; then
  echo "Found configs but none matched server_name ${DOMAIN}."
  echo "Add inside that domain's server { } block:"
  echo "  include ${SNIPPET_PATH};"
  exit 2
fi

nginx -t
systemctl reload nginx || service nginx reload
echo "nginx reloaded."
echo "Verify: curl -sS https://${DOMAIN}${TIME_URI}/hello.php"
echo "Expected JSON with ok:true (not <?php source)."
