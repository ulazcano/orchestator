#!/usr/bin/env bash
# vm-startup.sh - startup script de la VM de Orca de un cliente (Ubuntu 24.04, root).
#
# Se pasa como --metadata-from-file startup-script=. Corre en CADA arranque, por lo que
# es idempotente: cada paso deja una marca en $STARTUP_LOG y los ya hechos se saltan.
# El log NO contiene secretos. La auth key de Tailscale se lee de Secret Manager a memoria
# y se entrega a `tailscale up` por un descriptor de archivo (nunca a disco, log ni argv).
#
# Entradas (metadata de la VM): client, orca-version. Para pruebas fuera de GCP:
#   ORCA_CLIENT, ORCA_VERSION       sustituyen a la metadata
#   ORCA_SKIP_GCP=1                 no consulta el servidor de metadata ni Secret Manager
#   ORCA_SKIP_TAILSCALE=1           instala Tailscale pero no hace `tailscale up`
#   ORCA_SKIP_SERVICE=1             no hace enable-linger ni registra el servicio systemd
#   ORCA_SKIP_ORCA=1 / ORCA_SKIP_CLAUDE=1   saltan la descarga de Orca / Claude Code
#   STARTUP_LOG=ruta                log alternativo
#   ORCA_TS_WAIT_SECS=600           espera máxima a que exista la auth key
set -euo pipefail

# ---------------------------------------------------------------------------
# Variables (contrato compartido)
# ---------------------------------------------------------------------------
PROJECT_ID="bove-orca"
ORCA_PORT="6768"
ORCA_USER="orca"
ADMIN_USER="orca-admin"
STARTUP_LOG="${STARTUP_LOG:-/var/log/orca-startup.log}"
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
ORCA_REPO="stablyai/orca"
TS_WAIT_SECS="${ORCA_TS_WAIT_SECS:-600}"
TS_WAIT_STEP=20

CLIENT="${ORCA_CLIENT:-}"
ORCA_VERSION="${ORCA_VERSION:-}"
FAILED_STEPS=()

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Log por pasos (sin secretos)
# ---------------------------------------------------------------------------
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
mark() { # mark ESTADO PASO  -> "<fecha> ESTADO PASO"
  mkdir -p "$(dirname "$STARTUP_LOG")"
  printf '%s %s %s\n' "$(ts)" "$1" "$2" >>"$STARTUP_LOG"
  printf 'orca-startup: %s %s\n' "$1" "$2" >&2
}
step_done() { # 0 si el paso tiene una marca OK
  [[ -f "$STARTUP_LOG" ]] || return 1
  awk -v s="$1" '$2=="OK" && $3==s {f=1} END{exit !f}' "$STARTUP_LOG"
}

# run_step NOMBRE FUNCION [CHECK]: salta si ya está hecho; un fallo no aborta los demás.
# Si se da CHECK (función), decide ese estado real en vez de la marca del log.
run_step() {
  local name="$1" fn="$2" check="${3:-}" rc
  if [[ -n "$check" ]]; then
    if "$check"; then mark SKIP "$name"; return 0; fi
  elif step_done "$name"; then
    mark SKIP "$name"; return 0
  fi
  mark START "$name"
  set +e
  ( set -e; "$fn" )   # subshell aislada: set -e sí aplica dentro porque no va en un `if`
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    mark OK "$name"
  else
    mark FAIL "$name"
    FAILED_STEPS+=("$name")
  fi
  return 0
}

# apt-get tolerante al lock que toma unattended-upgrades en el primer arranque.
apt_get() { apt-get -o DPkg::Lock::Timeout=300 "$@"; }

skip_flag() { [[ "${!1:-0}" == "1" ]]; }   # skip_flag ORCA_SKIP_X

as_orca() { # as_orca CMD...: ejecuta como el usuario orca con su entorno de systemd de usuario
  local uid; uid="$(id -u "$ORCA_USER")"
  runuser -u "$ORCA_USER" -- env \
    HOME="/home/${ORCA_USER}" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    PATH="/home/${ORCA_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

# ---------------------------------------------------------------------------
# Entradas: metadata de la VM
# ---------------------------------------------------------------------------
md_get() { curl -fsS -m 10 -H 'Metadata-Flavor: Google' "${METADATA_URL}/instance/attributes/$1"; }

load_inputs() {
  if ! skip_flag ORCA_SKIP_GCP; then
    [[ -n "$CLIENT" ]] || CLIENT="$(md_get client)"
    [[ -n "$ORCA_VERSION" ]] || ORCA_VERSION="$(md_get orca-version)"
  fi
  [[ "$CLIENT" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] || { mark FAIL "inputs:client-invalido"; return 1; }
  [[ "$ORCA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { mark FAIL "inputs:orca-version-invalida"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Pasos
# ---------------------------------------------------------------------------
step_base_packages() {
  apt_get update -y
  apt_get install -y --no-install-recommends \
    ca-certificates curl gnupg jq git build-essential sudo unzip openssl lsb-release
}

step_users() {
  # orca: SIN sudo (los agentes ejecutan comandos arbitrarios).
  if ! id "$ORCA_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$ORCA_USER"
  fi
  passwd -l "$ORCA_USER" >/dev/null
  local g
  for g in sudo adm admin wheel google-sudoers docker lxd; do
    if getent group "$g" >/dev/null && id -nG "$ORCA_USER" | tr ' ' '\n' | grep -qx "$g"; then
      gpasswd -d "$ORCA_USER" "$g"
    fi
  done
  # El agente de invitado de GCE puede añadir usuarios a google-sudoers si alguien entra por
  # `gcloud compute ssh orca@...`. Este archivo (se lee después) lo anula para orca.
  install -m 0440 /dev/null /etc/sudoers.d/zz-orca-nosudo
  printf '%s ALL=(ALL:ALL) !ALL\n' "$ORCA_USER" >/etc/sudoers.d/zz-orca-nosudo
  visudo -cf /etc/sudoers.d/zz-orca-nosudo >/dev/null

  # orca-admin: con sudo; sin contraseña (bloqueada) y sin llave: solo entra por IAP con la llave.
  # (No se llama "admin": Ubuntu ya trae un grupo "admin" y useradd falla; el agente de GCE también.)
  # que gcloud añade a la metadata (`gcloud compute ssh orca-admin@VM --tunnel-through-iap`).
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
  fi
  passwd -l "$ADMIN_USER" >/dev/null
  install -m 0440 /dev/null /etc/sudoers.d/90-orca-admin
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >/etc/sudoers.d/90-orca-admin
  visudo -cf /etc/sudoers.d/90-orca-admin >/dev/null

  install -d -o "$ORCA_USER" -g "$ORCA_USER" -m 0755 "/home/${ORCA_USER}/projects"
}

step_linger() {
  skip_flag ORCA_SKIP_SERVICE && { echo "ORCA_SKIP_SERVICE=1: sin enable-linger"; return 0; }
  loginctl enable-linger "$ORCA_USER"
}

step_node() {
  # Node LTS desde NodeSource (script descargado a un archivo temporal, no `curl | bash`).
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/setup_lts.x" https://deb.nodesource.com/setup_lts.x
  bash "${tmp}/setup_lts.x"
  apt_get install -y nodejs
  rm -rf "$tmp"
  node --version
}

step_gh() {
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL -o /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/github-cli.list
  apt_get update -y
  apt_get install -y gh
  gh --version | head -1
}

step_tailscale_install() {
  # Repo oficial de Tailscale para Ubuntu noble.
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL -o /usr/share/keyrings/tailscale-archive-keyring.gpg https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
  curl -fsSL -o /etc/apt/sources.list.d/tailscale.list https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list
  apt_get update -y
  apt_get install -y tailscale
  if ! skip_flag ORCA_SKIP_SERVICE; then
    systemctl enable --now tailscaled
  fi
  tailscale version | head -1
}

# --- Orca (.deb de GitHub Releases, versión fijada) --------------------------
orca_release_url() { printf 'https://github.com/%s/releases/download/v%s' "$ORCA_REPO" "$ORCA_VERSION"; }

sha512_b64() { openssl dgst -sha512 -binary "$1" | base64 -w0; }

# published_sha512 YML ARCHIVO: sha512 (base64) que latest-linux.yml publica para ARCHIVO.
published_sha512() {
  awk -v f="$2" '
    $1=="-" && $2=="url:" { cur=$3 }
    $1=="sha512:" && cur==f { print $2; exit }
  ' "$1"
}

step_orca_install() {
  local arch deb url tmp expected actual pkg
  arch="$(dpkg --print-architecture)"
  deb="orca-ide_${ORCA_VERSION}_${arch}.deb"
  url="$(orca_release_url)"
  tmp="$(mktemp -d)"
  chmod 0755 "$tmp"   # que el usuario _apt pueda leer el .deb
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL -o "${tmp}/${deb}" "${url}/${deb}"

  # La doc de instalación no menciona checksums; GitHub Releases publica latest-linux.yml (sha512).
  # Si no se puede descargar el yml NO se instala (se reintenta en el próximo arranque): no se degrada
  # a "sin verificar" por un fallo de red. Solo se omite la verificación si la release publica el yml
  # pero sin entrada para este .deb ("si lo publican").
  if ! curl -fsSL -o "${tmp}/latest-linux.yml" "${url}/latest-linux.yml"; then
    echo "ERROR: no pude descargar latest-linux.yml de la release v${ORCA_VERSION}; no se instala sin verificar." >&2
    return 1
  fi
  expected="$(published_sha512 "${tmp}/latest-linux.yml" "$deb")"
  if [[ -n "$expected" ]]; then
    actual="$(sha512_b64 "${tmp}/${deb}")"
    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: el sha512 de ${deb} no coincide con el publicado; no se instala." >&2
      return 1
    fi
    echo "sha512 verificado para ${deb}"
  else
    echo "AVISO: la release v${ORCA_VERSION} no publica sha512 para ${deb}; se instala sin verificar checksum." >&2
  fi

  pkg="$(dpkg-deb -f "${tmp}/${deb}" Package)"
  # Un hold previo (de otra versión) impediría cambiar de versión: se levanta, se instala y se vuelve a fijar.
  apt-mark unhold "$pkg" >/dev/null 2>&1 || true
  apt_get install -y --allow-downgrades "${tmp}/${deb}"
  command -v orca-ide >/dev/null
  # Sin auto-update: el paquete queda retenido en esta versión.
  apt-mark hold "$pkg"
  echo "orca instalado: paquete ${pkg} ${ORCA_VERSION}"
}

# --- Claude Code como usuario orca -------------------------------------------
step_claude() {
  local tmp; tmp="$(mktemp -d)"
  chmod 0755 "$tmp"
  curl -fsSL -o "${tmp}/claude-install.sh" https://claude.ai/install.sh
  chmod 0644 "${tmp}/claude-install.sh"
  as_orca bash "${tmp}/claude-install.sh"
  rm -rf "$tmp"
  # Asegura PATH en shells de login/interactivos de orca.
  if ! grep -qs '\.local/bin' "/home/${ORCA_USER}/.profile"; then
    # shellcheck disable=SC2016  # $HOME y $PATH deben expandirse al iniciar sesión, no ahora
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"/home/${ORCA_USER}/.profile"
    chown "${ORCA_USER}:${ORCA_USER}" "/home/${ORCA_USER}/.profile"
  fi
  as_orca test -x "/home/${ORCA_USER}/.local/bin/claude"
}

# --- Servicio de Orca (systemd de usuario de orca) ---------------------------
step_orca_service() {
  skip_flag ORCA_SKIP_SERVICE && { echo "ORCA_SKIP_SERVICE=1: sin registrar el servicio"; return 0; }
  local uid unit; uid="$(id -u "$ORCA_USER")"
  systemctl start "user@${uid}.service"
  # El bus de usuario tarda un momento en aparecer.
  local waited=0
  while [[ ! -S "/run/user/${uid}/bus" && $waited -lt 30 ]]; do sleep 1; waited=$((waited + 1)); done
  as_orca orca-ide serve service install --port "$ORCA_PORT"
  # Que quede habilitado (idempotente). El nombre exacto de la unidad lo decide Orca.
  while read -r unit; do
    if [[ -n "$unit" ]]; then as_orca systemctl --user enable --now "$unit"; fi
  done < <(as_orca systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '/orca/ {print $1}')
  as_orca orca-ide serve service status
}

# --- Tailscale up (último paso: depende de que cargues la auth key) -----------
tailscale_is_up() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1
}

ensure_gcloud() {
  command -v gcloud >/dev/null 2>&1 && return 0
  # Imágenes Ubuntu de GCE suelen traerlo (snap); si no, repo oficial de Google Cloud.
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  printf 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main\n' \
    >/etc/apt/sources.list.d/google-cloud-sdk.list
  apt_get update -y
  apt_get install -y google-cloud-cli
}

step_tailscale_up() {
  local secret="tailscale-authkey-${CLIENT}" key="" waited=0
  ensure_gcloud
  # La key nunca se imprime, no va a disco ni a argv: vive en una variable y se pasa por un pipe.
  while :; do
    if key="$(gcloud secrets versions access latest --secret="$secret" --project="$PROJECT_ID" 2>/dev/null)" \
       && [[ -n "$key" ]]; then
      break
    fi
    key=""
    if [[ $waited -ge $TS_WAIT_SECS ]]; then
      echo "El secreto ${secret} no tiene versión legible tras ${TS_WAIT_SECS}s." >&2
      echo "Cárgalo (gcloud secrets versions add ${secret} --data-file=-) y reejecuta: sudo google_metadata_script_runner startup" >&2
      return 1
    fi
    echo "Esperando valor en ${secret} (${waited}/${TS_WAIT_SECS}s)..." >&2
    sleep "$TS_WAIT_STEP"; waited=$((waited + TS_WAIT_STEP))
  done
  # `file:/dev/fd/3` -> tailscale lee la key de un pipe anónimo (sin archivo en disco).
  tailscale up \
    --auth-key=file:/dev/fd/3 \
    --hostname="orca-${CLIENT}" \
    --advertise-tags="tag:orca-${CLIENT}" \
    3< <(printf '%s' "$key") >/dev/null
  key=""
  tailscale_is_up
}

# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
main() {
  [[ $EUID -eq 0 ]] || { echo "Debe ejecutarse como root." >&2; exit 1; }
  mark START "startup"

  if ! load_inputs; then
    echo "Entradas inválidas (client / orca-version)." >&2
    mark FAIL "startup"
    exit 1
  fi
  mark INFO "client=${CLIENT} orca-version=${ORCA_VERSION}"

  run_step base-packages  step_base_packages
  run_step users          step_users
  run_step linger         step_linger
  run_step node-lts       step_node
  run_step gh             step_gh
  run_step tailscale-install step_tailscale_install
  if skip_flag ORCA_SKIP_ORCA; then mark SKIP "orca-install (ORCA_SKIP_ORCA=1)"
  else run_step "orca-install-${ORCA_VERSION}" step_orca_install; fi
  if skip_flag ORCA_SKIP_CLAUDE; then mark SKIP "claude-code (ORCA_SKIP_CLAUDE=1)"
  else run_step claude-code step_claude; fi
  if skip_flag ORCA_SKIP_ORCA; then mark SKIP "orca-service (ORCA_SKIP_ORCA=1)"
  else run_step "orca-service-${ORCA_PORT}" step_orca_service; fi
  if skip_flag ORCA_SKIP_TAILSCALE || skip_flag ORCA_SKIP_GCP; then
    mark SKIP "tailscale-up (omitido por variable)"
  else
    run_step tailscale-up step_tailscale_up tailscale_is_up
  fi

  if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
    mark FAIL "startup pasos=${FAILED_STEPS[*]}"
    exit 1
  fi
  mark OK "startup"
}

# Permite hacer `source` en pruebas sin ejecutar main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
