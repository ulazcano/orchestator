#!/usr/bin/env bash
# bootstrap-project.sh: base del proyecto GCP para Orca (Fase 1).
# Ver orca-gcp/docs/diagnostico.md y docs/orca-gcp-spec.md.
set -euo pipefail

# --- Contratos compartidos (docs/PLAN.md); no cambiar nombres ---
PROJECT_ID="bove-orca"
REGION="us-central1"
NETWORK="orca-vpc"
SUBNET="orca-subnet"
SUBNET_RANGE="10.10.0.0/24"
NETWORK_TAG="orca"
IAP_RANGE="35.235.240.0/20"
FW_RULE_IAP="orca-allow-iap-ssh"
APIS=(compute.googleapis.com iap.googleapis.com secretmanager.googleapis.com)

DRY_RUN=0
SLUG_RE='^[a-z][a-z0-9-]{0,20}[a-z0-9]$'   # SA "orca-vm-<slug>" <= 30 caracteres

usage() {
  cat <<USAGE
Uso: $(basename "$0") [--dry-run] <subcomando> [args]

Subcomandos:
  apis                      Habilita compute, iap y secretmanager.
  network                   Crea la VPC ${NETWORK} (custom) y la subred ${SUBNET} (${SUBNET_RANGE}, ${REGION}).
  firewall                  Crea la unica regla de ingreso ${FW_RULE_IAP} (IAP, tcp:22, tag ${NETWORK_TAG}).
  all                       apis + network + firewall (idempotente).
  client-sa <slug>          Crea la cuenta de servicio orca-vm-<slug>, le da logging.logWriter en el
                            proyecto y secretAccessor SOLO sobre el secreto tailscale-authkey-<slug>.
                            El secreto debe existir antes (lo crea create-client.sh).
  purge-default-network     Borra las reglas y la red 'default' (ingreso publico). Accion destructiva
                            y separada; ejecutar solo con confirmacion del dueno.

Opciones:
  --dry-run   Imprime los comandos gcloud sin ejecutarlos (no llama a gcloud).
  -h, --help  Muestra esta ayuda.

Alternativa sin IP externa + Cloud NAT (NO se aplica; ver el final de este archivo).
No lee ni imprime secretos.
USAGE
}

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Ejecuta (o imprime en --dry-run) un comando que cambia recursos.
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# true si el recurso existe. En --dry-run no llama a gcloud: asume que no existe.
exists() {
  [[ "$DRY_RUN" -eq 1 ]] && return 1
  "$@" >/dev/null 2>&1
}

GC=(gcloud --project "$PROJECT_ID" --quiet)

check_slug() {
  [[ "${1:-}" =~ $SLUG_RE ]] || die "slug invalido '${1:-}': usa minusculas, digitos y '-', 2-22 caracteres, empezando con letra."
  [[ ${#1} -le 22 ]] || die "slug demasiado largo (max 22) para el nombre de la cuenta de servicio."
}

cmd_apis() {
  log "== Habilitando APIs: ${APIS[*]}"
  run "${GC[@]}" services enable "${APIS[@]}"
}

cmd_network() {
  log "== Red ${NETWORK} y subred ${SUBNET}"
  if exists "${GC[@]}" compute networks describe "$NETWORK"; then
    log "   ${NETWORK} ya existe, se omite"
  else
    run "${GC[@]}" compute networks create "$NETWORK" --subnet-mode=custom
  fi
  if exists "${GC[@]}" compute networks subnets describe "$SUBNET" --region "$REGION"; then
    log "   ${SUBNET} ya existe, se omite"
  else
    # Private Google Access: sin costo; deja leer Secret Manager si algun dia no hay IP externa.
    run "${GC[@]}" compute networks subnets create "$SUBNET" --network "$NETWORK" \
      --region "$REGION" --range "$SUBNET_RANGE" --enable-private-ip-google-access
  fi
}

cmd_firewall() {
  log "== Regla de ingreso ${FW_RULE_IAP} (unica regla de ingreso)"
  if exists "${GC[@]}" compute firewall-rules describe "$FW_RULE_IAP"; then
    log "   ${FW_RULE_IAP} ya existe, se omite"
  else
    run "${GC[@]}" compute firewall-rules create "$FW_RULE_IAP" --network "$NETWORK" \
      --direction=INGRESS --action=allow --rules=tcp:22 \
      --source-ranges="$IAP_RANGE" --target-tags="$NETWORK_TAG" --priority=1000
  fi
}

cmd_client_sa() {
  local slug="${1:-}"
  check_slug "$slug"
  local sa_name="orca-vm-${slug}"
  local sa_email="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"
  local secret="tailscale-authkey-${slug}"

  log "== Cuenta de servicio ${sa_email}"
  if exists "${GC[@]}" iam service-accounts describe "$sa_email"; then
    log "   ya existe, se omite la creacion"
  else
    run "${GC[@]}" iam service-accounts create "$sa_name" --display-name="Orca VM ${slug}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      # La cuenta tarda unos segundos en ser visible para IAM: se espera, no se reintenta el cambio.
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do
        exists "${GC[@]}" iam service-accounts describe "$sa_email" && break
        [[ "$i" -eq 10 ]] && die "la cuenta ${sa_email} no aparece tras 20 s; revisa permisos y propagacion de IAM."
        sleep 2
      done
    fi
  fi

  log "== roles/logging.logWriter (proyecto) para ${sa_email}"
  run "${GC[@]}" projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa_email}" --role=roles/logging.logWriter --condition=None --format=none

  log "== roles/secretmanager.secretAccessor solo sobre el secreto ${secret}"
  if [[ "$DRY_RUN" -eq 0 ]] && ! exists "${GC[@]}" secrets describe "$secret"; then
    die "el secreto ${secret} no existe. Crealo primero (sin valor) con: gcloud secrets create ${secret} --project ${PROJECT_ID} --replication-policy=automatic"
  fi
  run "${GC[@]}" secrets add-iam-policy-binding "$secret" \
    --member="serviceAccount:${sa_email}" --role=roles/secretmanager.secretAccessor --condition=None --format=none
}

cmd_purge_default() {
  log "== Eliminando red 'default' y sus reglas (destructivo)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run "${GC[@]}" compute firewall-rules list --filter="network~'.*/default$'" --format="value(name)"
    printf '+ gcloud --project %s --quiet compute firewall-rules delete <cada regla listada arriba>\n' "$PROJECT_ID"
    run "${GC[@]}" compute networks delete default
    return 0
  fi
  if ! exists "${GC[@]}" compute networks describe default; then
    log "   la red 'default' no existe, nada que hacer"
    return 0
  fi
  local rules
  rules="$("${GC[@]}" compute firewall-rules list --filter="network~'.*/default$'" --format="value(name)")"
  if [[ -n "$rules" ]]; then
    log "   reglas a borrar: $(tr '\n' ' ' <<<"$rules")"
    # shellcheck disable=SC2086  # nombres de regla sin espacios; se separan a proposito
    run "${GC[@]}" compute firewall-rules delete $rules
  fi
  run "${GC[@]}" compute networks delete default
}

main() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  [[ ${#args[@]} -ge 1 ]] || { usage >&2; exit 2; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v gcloud >/dev/null || die "gcloud no esta instalado."
  fi
  case "${args[0]}" in
    apis)     cmd_apis ;;
    network)  cmd_network ;;
    firewall) cmd_firewall ;;
    all)      cmd_apis; cmd_network; cmd_firewall ;;
    client-sa) cmd_client_sa "${args[1]:-}" ;;
    purge-default-network) cmd_purge_default ;;
    *) usage >&2; exit 2 ;;
  esac
}

# Permite hacer `source` desde create-client.sh y llamar cmd_client_sa sin ejecutar main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

# -----------------------------------------------------------------------------
# ALTERNATIVA DOCUMENTADA, NO APLICADA: VM sin IP externa + Cloud NAT
#
#   gcloud compute routers create orca-router --network orca-vpc --region us-central1
#   gcloud compute routers nats create orca-nat --router orca-router --region us-central1 \
#     --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
#   # y crear las VMs con --no-address
#
# Costo aproximado (NO verificado en las paginas de precios; confirmar en
# cloud.google.com/nat/pricing y cloud.google.com/vpc/network-pricing):
#   - IP externa efimera en uso: ~US$0.004-0.005/h por VM  (~US$3-4/mes, ~US$3 con horario 08-21 lun-vie).
#   - Cloud NAT: ~US$0.0014/h por VM atendida (~US$1/mes 24/7) + ~US$0.045/GiB procesado,
#     mas las IP de NAT. Para una VM, el ahorro frente a la IP externa es casi nulo y se suma
#     trafico (apt, npm, git, modelos) facturado por GiB.
# Ventajas: la VM no tiene IP publica. Como no hay reglas de ingreso publicas, la exposicion real ya es
# la misma; la ganancia es de higiene. Con IAP SSH y Tailscale (saliente) ambas opciones funcionan.
# Recomendacion: mantener IP externa efimera en el piloto; reevaluar con >3 clientes.
# -----------------------------------------------------------------------------
