#!/usr/bin/env bash
# Sync this repo into ONE Hostinger folder only.
set -euo pipefail

ALLOWED_USER="cloudmosaicaissh"
ALLOWED_PATH="/home/cloudmosaicaissh/htdocs/cloudmosaic.ai/time"

HOST="${HOSTINGER_HOST:?Set HOSTINGER_HOST}"
USER="${HOSTINGER_USER:-$ALLOWED_USER}"
KEY_FILE="${HOSTINGER_SSH_KEY_FILE:?Set HOSTINGER_SSH_KEY_FILE}"

if [[ "$USER" != "$ALLOWED_USER" ]]; then
  echo "Refusing deploy: SSH user must be ${ALLOWED_USER} (got ${USER})."
  exit 1
fi
if [[ ! -f "$KEY_FILE" ]]; then
  echo "SSH key file not found: $KEY_FILE"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ssh_base_opts() {
  local port="$1"
  printf '%s\n' \
    -i "$KEY_FILE" \
    -p "$port" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=25 \
    -o ConnectionAttempts=3 \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -o HostKeyAlgorithms=+ssh-rsa,rsa-sha2-256,rsa-sha2-512,ssh-ed25519 \
    -o PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256,rsa-sha2-512,ssh-ed25519 \
    -o KexAlgorithms=+diffie-hellman-group14-sha256,diffie-hellman-group-exchange-sha256,curve25519-sha256
}

tcp_probe() {
  local port="$1"
  python3 - "$HOST" "$port" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(20)
try:
    s.connect((host, port))
except OSError as e:
    print(f"TCP {host}:{port} closed/filtered ({e})")
    sys.exit(1)
else:
    print(f"TCP {host}:{port} open")
    sys.exit(0)
finally:
    s.close()
PY
}

unique_ports() {
  local seen=" "
  local port
  for port in "$@"; do
    [[ -z "$port" ]] && continue
    [[ "$seen" == *" $port "* ]] && continue
    seen+="$port "
    echo "$port"
  done
}

PORTS=()
while IFS= read -r port; do
  PORTS+=("$port")
done < <(unique_ports "${HOSTINGER_PORT:-}" "22" "65002")

echo "Deploy target ${USER}@${HOST} → ${ALLOWED_PATH}"
echo "SSH key: $(ssh-keygen -l -f "$KEY_FILE" 2>/dev/null || echo unknown)"
echo "Will try SSH ports: ${PORTS[*]}"

PORT=""
LAST_ERR=""
for try_port in "${PORTS[@]}"; do
  echo "Probing TCP then SSH on port ${try_port}…"
  if ! tcp_probe "$try_port"; then
    continue
  fi
  mapfile -t probe_opts < <(ssh_base_opts "$try_port")
  set +e
  LAST_ERR="$(ssh "${probe_opts[@]}" "${USER}@${HOST}" "echo PREFLIGHT_SSH_OK" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    PORT="$try_port"
    echo "SSH ok on port ${PORT}"
    break
  fi
  echo "Port ${try_port}: SSH failed (exit ${status})."
  echo "$LAST_ERR" | grep -Eiv 'Warning: Permanently added' | tail -n 20 || true
done

if [[ -z "$PORT" ]]; then
  echo "::error::SSH never connected. GitHub could not log into Hostinger."
  echo "Put this PUBLIC key into /home/${ALLOWED_USER}/.ssh/authorized_keys on the VPS:"
  ssh-keygen -y -f "$KEY_FILE" || true
  echo "Also confirm HOSTINGER_HOST is the VPS IP from hPanel → VPS → Overview,"
  echo "HOSTINGER_USER is ${ALLOWED_USER}, and firewall allows SSH from the internet."
  exit 255
fi

mapfile -t SSH_OPTS < <(ssh_base_opts "$PORT")
SSH_WRAP="$(mktemp)"
{
  printf '#!/usr/bin/env bash\nexec ssh'
  printf ' %q' "${SSH_OPTS[@]}"
  printf ' "$@"\n'
} > "$SSH_WRAP"
chmod 700 "$SSH_WRAP"
trap 'rm -f "$SSH_WRAP"' EXIT

ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" "mkdir -p '${ALLOWED_PATH}'"

echo "Rsync → ${USER}@${HOST}:${ALLOWED_PATH}/"
rsync -avz --delete \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude '.gitignore' \
  --exclude '.DS_Store' \
  --exclude 'config/db.local.php' \
  --exclude 'config/db.local.php.example' \
  -e "$SSH_WRAP" \
  "${ROOT}/" "${USER}@${HOST}:${ALLOWED_PATH}/"

echo "Deployed to ${ALLOWED_PATH}/ only."
