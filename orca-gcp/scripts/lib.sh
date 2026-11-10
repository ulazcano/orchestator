#!/usr/bin/env bash
# lib.sh - funciones y variables compartidas por los scripts de orca-gcp.
# Se usa con `source`; no se ejecuta directamente.
#
# Contratos de nombres: docs/PLAN.md, sección "Contratos compartidos".
# Regla: este archivo NUNCA recibe, guarda ni imprime secretos.
# shellcheck shell=bash
# shellcheck disable=SC2034  # las variables las consumen los scripts que hacen source

# ---------------------------------------------------------------------------
# Variables fijas del contrato (las derivadas por cliente las fija client_vars)
# ---------------------------------------------------------------------------
PROJECT_ID="bove-orca"
REGION="us-central1"
ZONE="us-central1-a"
NETWORK="orca-vpc"
SUBNET="orca-subnet"
NETWORK_TAG="orca"
IAP_RANGE="35.235.240.0/20"
FW_RULE_IAP="orca-allow-iap-ssh"
MACHINE_TYPE="n4-standard-8"
DISK_GB="200"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
ORCA_PORT="6768"
ORCA_USER="orca"
ADMIN_USER="admin"
STARTUP_LOG="/var/log/orca-startup.log"

# Binario de gcloud; las pruebas lo sustituyen por un stub (nunca llama a GCP real).
GCLOUD="${GCLOUD:-gcloud}"

# Estado del parseo de argumentos
DRY_RUN=0
SHOW_HELP=0
ARGS=()    # argumentos posicionales
FLAGS=()   # flags extra permitidos por el script (ver ALLOWED_FLAGS)
ALLOWED_FLAGS=()

# Derivados por cliente (se llenan en client_vars)
CLIENT=""
VM_NAME=""
LABEL=""
SERVICE_ACCOUNT=""
SECRET_TS_AUTHKEY=""
TS_HOSTNAME=""
TS_TAG=""
SCHEDULE_NAME=""
SNAPSHOT_POLICY=""

# ---------------------------------------------------------------------------
# Logging (stderr, sin secretos)
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
info() { printf '[info] %s\n' "$*" >&2; }
warn() { printf '[aviso] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------

# Slug: minúsculas, dígitos y guiones. Empieza con letra, no termina en guion.
# Máximo 22 caracteres: el ID de la cuenta de servicio "orca-vm-<slug>" admite 30.
validate_slug() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || die "Falta el slug del cliente."
  if [[ ${#slug} -gt 22 ]]; then
    die "Slug '$slug' demasiado largo (${#slug} > 22): el ID de la cuenta de servicio orca-vm-<slug> admite 30 caracteres."
  fi
  if ! [[ "$slug" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
    die "Slug inválido '$slug': usa minúsculas, dígitos y guiones; empieza con letra y no termina en guion."
  fi
}

# Define las variables derivadas del contrato para el cliente dado.
client_vars() {
  validate_slug "${1:-}"
  CLIENT="$1"
  VM_NAME="orca-${CLIENT}"
  LABEL="cliente=${CLIENT}"
  SERVICE_ACCOUNT="orca-vm-${CLIENT}@${PROJECT_ID}.iam.gserviceaccount.com"
  SECRET_TS_AUTHKEY="tailscale-authkey-${CLIENT}"
  TS_HOSTNAME="orca-${CLIENT}"
  TS_TAG="tag:orca-${CLIENT}"
  SCHEDULE_NAME="orca-horario-${CLIENT}"
  SNAPSHOT_POLICY="orca-snapshots-${CLIENT}"
}

# ORCA_VERSION es obligatoria (la misma que el Mac); sin auto-update.
require_orca_version() {
  ORCA_VERSION="${ORCA_VERSION:-}"
  [[ -n "$ORCA_VERSION" ]] || die "Define ORCA_VERSION con la versión exacta de tu Orca en el Mac (ej: export ORCA_VERSION=1.4.255)."
  # Estricto X.Y.Z: es lo único que acepta vm-startup.sh (nombre del .deb y tag vX.Y.Z).
  [[ "$ORCA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "ORCA_VERSION='$ORCA_VERSION' no es válida (esperado X.Y.Z, sin 'v' ni sufijos)."
}

# ---------------------------------------------------------------------------
# Argumentos: --dry-run, --help/-h y flags extra declarados en ALLOWED_FLAGS
# ---------------------------------------------------------------------------
parse_args() {
  local arg allowed ok
  DRY_RUN=0; SHOW_HELP=0; ARGS=(); FLAGS=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) SHOW_HELP=1 ;;
      --*)
        ok=0
        for allowed in "${ALLOWED_FLAGS[@]+"${ALLOWED_FLAGS[@]}"}"; do
          [[ "$arg" == "$allowed" ]] && { ok=1; FLAGS+=("$arg"); }
        done
        [[ $ok -eq 1 ]] || die "Flag desconocido: $arg (usa --help)."
        ;;
      *) ARGS+=("$arg") ;;
    esac
  done
}

has_flag() {
  local f
  for f in "${FLAGS[@]+"${FLAGS[@]}"}"; do [[ "$f" == "$1" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Ejecución de comandos
# ---------------------------------------------------------------------------

# Imprime un comando pegable en bash, un flag "--x" por línea.
# (%q escapa la coma, que en bash no es especial; se deja sin escapar por legibilidad.)
print_cmd() {
  local out="" arg first=1
  for arg in "$@"; do
    arg="$(printf '%q' "$arg")"; arg="${arg//\\,/,}"
    if [[ $first -eq 1 ]]; then
      out+="$arg"; first=0
    elif [[ "$arg" == --* ]]; then
      out+=" \\"$'\n'"    $arg"
    else
      out+=" $arg"
    fi
  done
  printf '%s\n' "$out"
}

# Defensa en profundidad: ningún comando debe llevar algo que parezca una auth key.
refuse_secrets() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *tskey-*|*AIza*|*ghp_*|*github_pat_*|*sk-ant-*)
        die "Un argumento parece un secreto; se aborta sin imprimirlo." ;;
    esac
  done
}

# run CMD...: imprime el comando; lo ejecuta solo si no es --dry-run.
run() {
  refuse_secrets "$@"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] '
    print_cmd "$@"
    return 0
  fi
  printf '+ '
  print_cmd "$@"
  "$@"
}

# gc ARGS...: atajo para run "$GCLOUD" ...
gc() { run "$GCLOUD" "$@"; }

# preflight: antes de actuar de verdad, comprueba que gcloud existe y que el proyecto es accesible.
# Evita confundir "gcloud ausente / proyecto equivocado" con "el recurso no existe". Sin efecto en --dry-run.
preflight() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  command -v "$GCLOUD" >/dev/null 2>&1 || die "No encuentro '$GCLOUD' en el PATH."
  local out
  out="$("$GCLOUD" projects describe "$PROJECT_ID" --format="value(projectId)" 2>&1)" \
    || die "No puedo acceder al proyecto $PROJECT_ID (¿gcloud auth? ¿proyecto correcto?). Error real:"$'\n'"$out"
}

# gc_try ARGS...: como gc, pero un fallo solo avisa (para pasos opcionales/ya hechos).
gc_try() {
  run "$GCLOUD" "$@" || warn "El comando anterior falló (se continúa)."
  return 0
}

# resource_exists DESCRIPCIÓN CMD...: 0 si existe, 1 si no existe (NOT_FOUND).
# Cualquier otro error (auth, permisos, red) aborta mostrando el error real.
# En --dry-run no consulta GCP: asume que no existe.
resource_exists() {
  local what="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) no se consulta GCP; se asume que no existe: $what"
    return 1
  fi
  local out
  if out="$("$@" 2>&1)"; then
    return 0
  fi
  # "command not found" (gcloud ausente) NO es un recurso inexistente.
  if grep -v 'command not found' <<<"$out" | grep -qiE 'not found|NOT_FOUND|does not exist'; then
    return 1
  fi
  die "No pude consultar '$what'. Error real de gcloud:"$'\n'"$out"
}
