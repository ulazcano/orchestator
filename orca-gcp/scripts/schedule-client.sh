#!/usr/bin/env bash
# schedule-client.sh — snapshots diarios, presupuesto y (opcional) horario de encendido/apagado de un cliente.
#
# Uso:
#   schedule-client.sh <slug> [--auto-shutdown [--on HH:MM] [--off HH:MM] [--tz America/Santiago]]
#                      [--budget-amount N] [--snapshot-time HH:00] [--yes] [--dry-run]
#
# Crea (si no existen) y adjunta:
#   - instance-schedule  orca-horario-<slug>    -> VM orca-<slug>   SOLO con --auto-shutdown (08:00 on / 21:00 off, lun-vie)
#   - snapshot-schedule  orca-snapshots-<slug>  -> disco de la VM   (diario, retención 7 días)
#   - presupuesto        orca-presupuesto-<slug> en la cuenta de facturación (alertas 50/80/100 %)
#
# Variables de entorno:
#   BILLING_ACCOUNT_ID  cuenta de facturación para el presupuesto (la elige el dueño; nunca se adivina)
#   BUDGET_CURRENCY     opcional, p. ej. USD; si falta se usa la moneda de la cuenta de facturación
#   PROJECT_ID          por defecto bove-orca
#
# Por defecto la VM queda encendida 24/7 (sin horario). El horario es opt-in con --auto-shutdown.
# No contiene ni imprime secretos. Con --auto-shutdown ver orca-gcp/README.md para el prerequisito de IAM
# (Compute Engine Service Agent con roles/compute.instanceAdmin.v1).
set -euo pipefail

# ---------- Contratos compartidos (docs/PLAN.md) ----------
PROJECT_ID="${PROJECT_ID:-bove-orca}"
REGION="us-central1"
ZONE="us-central1-a"

# ---------- Valores por defecto ----------
ON_TIME="08:00"
OFF_TIME="21:00"
TIMEZONE="America/Santiago"
SNAPSHOT_TIME_UTC="06:00"   # los snapshots programados se definen en UTC, en punto
RETENTION_DAYS="7"
BUDGET_AMOUNT=""
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-}"
BUDGET_CURRENCY="${BUDGET_CURRENCY:-}"
DRY_RUN=0
ASSUME_YES=0
AUTO_SHUTDOWN=0
CLIENT=""

usage() {
  cat <<'EOF'
Uso: schedule-client.sh <slug> [opciones]

  --auto-shutdown       crear y adjuntar el horario de encendido/apagado (por defecto NO: VM 24/7)
  --on HH:MM            encendido (por defecto 08:00; solo con --auto-shutdown)
  --off HH:MM           apagado (por defecto 21:00; solo con --auto-shutdown)
  --tz ZONA             zona IANA (por defecto America/Santiago; solo con --auto-shutdown)
  --budget-amount N     monto mensual del presupuesto; requiere BILLING_ACCOUNT_ID
  --snapshot-time HH:00 hora UTC del snapshot diario (por defecto 06:00)
  --yes                 no pedir confirmación
  --dry-run             solo imprime los comandos gcloud, no ejecuta nada
  -h, --help            esta ayuda

Variables: BILLING_ACCOUNT_ID, BUDGET_CURRENCY (opcional), PROJECT_ID (bove-orca).
Sin --budget-amount no se crea presupuesto.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- Argumentos ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --auto-shutdown) AUTO_SHUTDOWN=1; shift ;;
    --on) [[ $# -ge 2 ]] || die "--on requiere HH:MM"; ON_TIME="$2"; shift 2 ;;
    --off) [[ $# -ge 2 ]] || die "--off requiere HH:MM"; OFF_TIME="$2"; shift 2 ;;
    --tz) [[ $# -ge 2 ]] || die "--tz requiere una zona IANA"; TIMEZONE="$2"; shift 2 ;;
    --budget-amount) [[ $# -ge 2 ]] || die "--budget-amount requiere un número"; BUDGET_AMOUNT="$2"; shift 2 ;;
    --snapshot-time) [[ $# -ge 2 ]] || die "--snapshot-time requiere HH:00"; SNAPSHOT_TIME_UTC="$2"; shift 2 ;;
    -*) usage >&2; die "opción desconocida: $1" ;;
    *)
      [[ -z "$CLIENT" ]] || die "solo se admite un slug (recibí '$CLIENT' y '$1')"
      CLIENT="$1"; shift ;;
  esac
done

[[ -n "$CLIENT" ]] || { usage >&2; die "falta <slug>"; }
[[ "$CLIENT" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die "slug inválido '$CLIENT' (minúsculas, dígitos y guiones, ej: cliente-a)"
[[ "$ON_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--on inválido '$ON_TIME' (HH:MM)"
[[ "$OFF_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--off inválido '$OFF_TIME' (HH:MM)"
[[ "$SNAPSHOT_TIME_UTC" =~ ^([01][0-9]|2[0-3]):00$ ]] || die "--snapshot-time debe ser HH:00 en UTC"
[[ "$TIMEZONE" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || die "--tz inválida '$TIMEZONE'"
if [[ -n "$BUDGET_AMOUNT" ]]; then
  [[ "$BUDGET_AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget-amount debe ser numérico (sin moneda; usa BUDGET_CURRENCY)"
  [[ -n "$BILLING_ACCOUNT_ID" ]] || die "--budget-amount requiere BILLING_ACCOUNT_ID en el entorno (lo elige el dueño; no se adivina)"
  [[ "$BILLING_ACCOUNT_ID" =~ ^[A-Za-z0-9-]+$ ]] || die "BILLING_ACCOUNT_ID con formato inválido"
  [[ -z "$BUDGET_CURRENCY" || "$BUDGET_CURRENCY" =~ ^[A-Z]{3}$ ]] || die "BUDGET_CURRENCY debe ser un código de 3 letras (USD)"
fi

# Minutos desde medianoche (10# evita que 08/09 se lean como octal).
to_minutes() { local h="${1%%:*}" m="${1##*:}"; echo $((10#$h * 60 + 10#$m)); }
ON_MIN="$(to_minutes "$ON_TIME")"
OFF_MIN="$(to_minutes "$OFF_TIME")"
# La doc exige operaciones separadas por >= 15 min y pueden retrasarse hasta 15 min.
(( OFF_MIN - ON_MIN >= 60 )) || die "--off debe ser al menos 60 min después de --on, el mismo día (recibí $ON_TIME -> $OFF_TIME)"

cron_for() { local t="$1"; echo "$((10#${t##*:})) $((10#${t%%:*})) * * 1-5"; }
START_CRON="$(cron_for "$ON_TIME")"
STOP_CRON="$(cron_for "$OFF_TIME")"

# ---------- Nombres (contratos compartidos) ----------
VM_NAME="orca-${CLIENT}"
LABEL="cliente=${CLIENT}"
SCHEDULE_NAME="orca-horario-${CLIENT}"
SNAPSHOT_POLICY="orca-snapshots-${CLIENT}"
BUDGET_NAME="orca-presupuesto-${CLIENT}"

# ---------- Utilidades ----------
# Imprime el comando; lo ejecuta solo si no es --dry-run.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( DRY_RUN )); then return 0; fi
  "$@"
}

# Lecturas (idempotencia). En --dry-run no se llama a gcloud: se asume "no existe".
exists() {
  if (( DRY_RUN )); then return 1; fi
  "$@" >/dev/null 2>&1
}

# ¿La política $1 está adjunta al recurso descrito por "${@:2}" (instances|disks describe ...)?
attached() {
  local policy="$1" out; shift
  (( DRY_RUN )) && return 1
  out="$("${GCLOUD[@]}" "$@" --format="value(resourcePolicies)" 2>/dev/null)" || return 1
  grep -q "/${policy}" <<<"$out"
}

confirm() {
  (( DRY_RUN || ASSUME_YES )) && return 0
  [[ -t 0 ]] || die "sin terminal interactiva: usa --yes para confirmar o --dry-run para ver el plan"
  read -r -p "¿Crear estos recursos con costo en el proyecto ${PROJECT_ID}? [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]] || die "cancelado"
}

GCLOUD=(gcloud --project="$PROJECT_ID")

# ---------- Plan ----------
echo "== Plan para el cliente '${CLIENT}' (proyecto ${PROJECT_ID}) =="
if (( AUTO_SHUTDOWN )); then
  echo "  Horario    : ${SCHEDULE_NAME}  encendido ${ON_TIME}, apagado ${OFF_TIME}, lun-vie, ${TIMEZONE}"
  echo "               cron start='${START_CRON}'  stop='${STOP_CRON}'  -> VM ${VM_NAME} (${ZONE})"
else
  echo "  Horario    : (omitido: VM encendida 24/7; usa --auto-shutdown para programarlo)"
fi
echo "  Snapshots  : ${SNAPSHOT_POLICY}  diario ${SNAPSHOT_TIME_UTC} UTC, retención ${RETENTION_DAYS} días, ubicación ${REGION}"
if [[ -n "$BUDGET_AMOUNT" ]]; then
  echo "  Presupuesto: ${BUDGET_NAME}  ${BUDGET_AMOUNT}${BUDGET_CURRENCY}/mes, alertas 50/80/100 %, filtro ${LABEL}"
else
  echo "  Presupuesto: (omitido: falta --budget-amount)"
fi
(( DRY_RUN )) && echo "  Modo --dry-run: no se ejecuta nada."
echo
confirm

# ---------- 1. Instance schedule ----------
if (( ! AUTO_SHUTDOWN )); then
  echo "-- 1/3 instance-schedule: omitido (VM 24/7; usa --auto-shutdown para crearlo)"
else
  echo "-- 1/3 instance-schedule ${SCHEDULE_NAME}"
  if exists "${GCLOUD[@]}" compute resource-policies describe "$SCHEDULE_NAME" --region="$REGION"; then
    echo "   ya existe; se conserva (para cambiar horas: gcloud compute resource-policies update instance-schedule ...)"
  else
    run "${GCLOUD[@]}" compute resource-policies create instance-schedule "$SCHEDULE_NAME" \
      --region="$REGION" \
      --vm-start-schedule="$START_CRON" \
      --vm-stop-schedule="$STOP_CRON" \
      --timezone="$TIMEZONE" \
      --description="Horario laboral de ${VM_NAME}"
  fi
  if attached "$SCHEDULE_NAME" compute instances describe "$VM_NAME" --zone="$ZONE"; then
    echo "   ya adjunto a ${VM_NAME}"
  else
    run "${GCLOUD[@]}" compute instances add-resource-policies "$VM_NAME" \
      --zone="$ZONE" --resource-policies="$SCHEDULE_NAME"
  fi
fi

# ---------- 2. Snapshots ----------
echo "-- 2/3 snapshot-schedule ${SNAPSHOT_POLICY}"
if exists "${GCLOUD[@]}" compute resource-policies describe "$SNAPSHOT_POLICY" --region="$REGION"; then
  echo "   ya existe; se conserva"
else
  # --storage-location explícito: sin él GCP elige una ubicación "cercana", posiblemente
  # multi-regional (más cara que la regional us-central1).
  run "${GCLOUD[@]}" compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" \
    --region="$REGION" \
    --daily-schedule \
    --start-time="$SNAPSHOT_TIME_UTC" \
    --max-retention-days="$RETENTION_DAYS" \
    --on-source-disk-delete=keep-auto-snapshots \
    --storage-location="$REGION" \
    --snapshot-labels="$LABEL"
fi

# El disco de arranque se descubre desde la VM (su nombre lo decide create-client.sh).
if (( DRY_RUN )); then
  DISK_NAME="${VM_NAME}"   # supuesto en dry-run: el disco de arranque se llama como la VM
else
  DISK_NAME="$("${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE" \
    --format="value(disks[0].source.basename())")" || die "no pude leer la VM ${VM_NAME}; ¿existe? (la crea create-client.sh)"
  [[ -n "$DISK_NAME" ]] || die "no pude determinar el disco de ${VM_NAME}"
fi
if attached "$SNAPSHOT_POLICY" compute disks describe "$DISK_NAME" --zone="$ZONE"; then
  echo "   ya adjunta al disco ${DISK_NAME}"
else
  run "${GCLOUD[@]}" compute disks add-resource-policies "$DISK_NAME" \
    --zone="$ZONE" --resource-policies="$SNAPSHOT_POLICY"
fi

# ---------- 3. Presupuesto ----------
echo "-- 3/3 presupuesto ${BUDGET_NAME}"
if [[ -z "$BUDGET_AMOUNT" ]]; then
  echo "   omitido (sin --budget-amount). Para crearlo: BILLING_ACCOUNT_ID=<id> $0 ${CLIENT} --budget-amount N"
else
  existing=""
  if (( ! DRY_RUN )); then
    existing="$("${GCLOUD[@]}" billing budgets list --billing-account="$BILLING_ACCOUNT_ID" \
      --filter="displayName=${BUDGET_NAME}" --format="value(name)" 2>/dev/null || true)"
  fi
  if [[ -n "$existing" ]]; then
    echo "   ya existe (${existing##*/}); se conserva. Para cambiar el monto: gcloud billing budgets update ${existing##*/} --billing-account=<id> --budget-amount=N"
  else
    run "${GCLOUD[@]}" billing budgets create \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --display-name="$BUDGET_NAME" \
      --budget-amount="${BUDGET_AMOUNT}${BUDGET_CURRENCY}" \
      --calendar-period=month \
      --filter-projects="projects/${PROJECT_ID}" \
      --filter-labels="$LABEL" \
      --threshold-rule=percent=0.5 \
      --threshold-rule=percent=0.8 \
      --threshold-rule=percent=1.0
  fi
fi

echo
echo "Listo."
if (( AUTO_SHUTDOWN )); then
  echo "Recordatorio: el Compute Engine Service Agent necesita roles/compute.instanceAdmin.v1"
  echo "en el proyecto para que el horario encienda/apague la VM (ver orca-gcp/README.md)."
fi
