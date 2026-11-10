#!/usr/bin/env bash
# create-client.sh - crea la VM de Orca de un cliente (y lo que necesita).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_SCRIPT="${SCRIPT_DIR}/vm-startup.sh"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-${SCRIPT_DIR}/bootstrap-project.sh}"   # lo posee el workspace 0 (override: pruebas)

# shellcheck source=lib.sh
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Uso: create-client.sh <slug> [machine-type] [disk-gb] [--dry-run] [--help]

Crea, de forma idempotente, la VM "orca-<slug>" en us-central1-a del proyecto bove-orca:
  1. Secreto "tailscale-authkey-<slug>" en Secret Manager (SIN valor; lo cargas tú).
  2. Cuenta de servicio del cliente (bootstrap-project.sh client-sa <slug>, workspace 0).
  3. VM Ubuntu 24.04, sin IP pública entrante, tag de red "orca", etiqueta cliente=<slug>
     en VM y disco, con vm-startup.sh como startup-script.
  4. Adjunta orca-horario-<slug> y orca-snapshots-<slug> si ya existen.

Argumentos:
  slug          minúsculas, dígitos y guiones; empieza con letra; máx. 22 caracteres
  machine-type  por defecto n4-standard-8
  disk-gb       por defecto 200 (hyperdisk-balanced)

Variables de entorno:
  ORCA_VERSION  OBLIGATORIA. Versión exacta de Orca (la misma que tu Mac), ej: 1.4.255

Opciones:
  --dry-run     imprime los comandos sin ejecutarlos y sin consultar GCP
  -h, --help    esta ayuda

Si la VM ya existe, lo indica y termina sin error. No hay secretos en argumentos,
metadata ni salida: la auth key de Tailscale la cargas tú directamente en Secret Manager.
EOF
}

main() {
  ALLOWED_FLAGS=()
  parse_args "$@"
  if [[ $SHOW_HELP -eq 1 ]]; then usage; return 0; fi

  [[ ${#ARGS[@]} -ge 1 && ${#ARGS[@]} -le 3 ]] || { usage >&2; die "Número de argumentos inválido."; }
  client_vars "${ARGS[0]}"
  local machine_type="${ARGS[1]:-$MACHINE_TYPE}"
  local disk_gb="${ARGS[2]:-$DISK_GB}"

  [[ "$machine_type" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "machine-type inválido: '$machine_type'."
  [[ "$disk_gb" =~ ^[1-9][0-9]*$ && "$disk_gb" -ge 50 && "$disk_gb" -le 4000 ]] \
    || die "disk-gb inválido: '$disk_gb' (entero entre 50 y 4000)."
  require_orca_version
  [[ -f "$STARTUP_SCRIPT" ]] || die "No existe $STARTUP_SCRIPT."

  info "Cliente: $CLIENT | VM: $VM_NAME | $machine_type | ${disk_gb} GB hyperdisk-balanced | $ZONE | proyecto $PROJECT_ID"
  info "Orca fijada en la versión $ORCA_VERSION (sin auto-update)"
  [[ $DRY_RUN -eq 1 ]] && info "MODO DRY-RUN: no se ejecuta ni se consulta nada en GCP"

  preflight

  # --- Idempotencia: si la VM existe no se recrea; solo se completa lo que falte -----
  # (etiqueta del disco y políticas), para poder terminar una ejecución a medias.
  if resource_exists "VM $VM_NAME" \
       "$GCLOUD" compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format="value(name)"; then
    info "La VM $VM_NAME ya existe en $ZONE: no se recrea. Se verifican etiqueta del disco y políticas."
    label_disk
    attach_policy "$SCHEDULE_NAME" instances
    attach_policy "$SNAPSHOT_POLICY" disks
    return 0
  fi

  # --- 1. Secreto de la auth key (sin valor) ---------------------------------
  local need_secret_value=1
  if resource_exists "secreto $SECRET_TS_AUTHKEY" \
       "$GCLOUD" secrets describe "$SECRET_TS_AUTHKEY" --project="$PROJECT_ID" --format="value(name)"; then
    info "El secreto $SECRET_TS_AUTHKEY ya existe; no se toca."
    if [[ -n "$("$GCLOUD" secrets versions list "$SECRET_TS_AUTHKEY" --project="$PROJECT_ID" \
          --filter="state=ENABLED" --limit=1 --format="value(name)" 2>/dev/null)" ]]; then
      need_secret_value=0
    fi
  else
    gc secrets create "$SECRET_TS_AUTHKEY" \
      --project="$PROJECT_ID" \
      --replication-policy=automatic \
      --labels="$LABEL"
  fi

  # --- 2. Cuenta de servicio del cliente (workspace 0) -------------------------
  # bootstrap-project.sh client-sa (workspace 0): idempotente; crea la SA y da secretAccessor SOLO
  # sobre $SECRET_TS_AUTHKEY, por eso corre DESPUÉS de crear el secreto (paso 1).
  local bootstrap_args=("$BOOTSTRAP_SCRIPT" client-sa "$CLIENT")
  [[ $DRY_RUN -eq 1 ]] && bootstrap_args+=(--dry-run)
  if [[ -f "$BOOTSTRAP_SCRIPT" ]]; then
    run bash "${bootstrap_args[@]}"
  elif [[ $DRY_RUN -eq 1 ]]; then
    warn "TODO: $BOOTSTRAP_SCRIPT aún no existe (workspace 0). Llamada prevista:"
    printf '[dry-run] '; print_cmd bash "${bootstrap_args[@]}"
  elif resource_exists "cuenta de servicio $SERVICE_ACCOUNT" \
         "$GCLOUD" iam service-accounts describe "$SERVICE_ACCOUNT" --project="$PROJECT_ID" --format="value(email)"; then
    warn "TODO: bootstrap-project.sh aún no existe; la cuenta de servicio ya existe y se reutiliza (revisa que tenga secretAccessor sobre $SECRET_TS_AUTHKEY)."
  else
    die "Falta ${BOOTSTRAP_SCRIPT} (workspace 0) y la cuenta de servicio $SERVICE_ACCOUNT no existe. Créala con bootstrap-project.sh client-sa $CLIENT y reintenta."
  fi

  # --- 3. VM -------------------------------------------------------------------
  # IP externa efímera (comportamiento por defecto: sin --address ni --no-address).
  # No hay reglas de ingreso públicas: lo controla el firewall del workspace 0 (solo IAP).
  # Scopes: cloud-platform es lo mínimo que acepta Secret Manager; el límite real
  # lo pone IAM (la SA solo lee su secreto).
  gc compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$machine_type" \
    --network="$NETWORK" \
    --subnet="$SUBNET" \
    --tags="$NETWORK_TAG" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="${disk_gb}GB" \
    --boot-disk-type=hyperdisk-balanced \
    --service-account="$SERVICE_ACCOUNT" \
    --scopes=cloud-platform \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --labels="$LABEL" \
    --metadata="client=${CLIENT},orca-version=${ORCA_VERSION}" \
    --metadata-from-file="startup-script=${STARTUP_SCRIPT}"

  label_disk

  # --- 4. Políticas de horario y snapshots (las crea el workspace 2) ---------
  attach_policy "$SCHEDULE_NAME" instances
  attach_policy "$SNAPSHOT_POLICY" disks

  print_next_steps "$need_secret_value"
}

# El disco de arranque se llama igual que la VM; --labels de "instances create" no lo etiqueta.
label_disk() {
  gc compute disks update "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --update-labels="$LABEL"
}

# attach_policy NOMBRE instances|disks: adjunta la política de recursos si existe y aún no está adjunta.
attach_policy() {
  local policy="$1" kind="$2"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) se adjuntaría ${policy} solo si existe (la crea el workspace 2 con schedule-client.sh):"
  elif ! resource_exists "política $policy" \
         "$GCLOUD" compute resource-policies describe "$policy" --region="$REGION" --project="$PROJECT_ID" --format="value(name)"; then
    info "La política $policy aún no existe; no se adjunta. Créala con schedule-client.sh y vuelve a ejecutar create-client.sh (adjunta lo que falte)."
    return 0
  elif "$GCLOUD" compute "$kind" describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
         --format="value(resourcePolicies)" 2>/dev/null | grep -qF "/${policy}"; then
    info "La política $policy ya está adjunta."
    return 0
  fi
  gc compute "$kind" add-resource-policies "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --resource-policies="$policy"
}

print_next_steps() {
  local need_secret_value="$1"
  cat <<EOF

================================================================
Siguiente paso (lo haces tú; el valor nunca pasa por el agente)
================================================================
EOF
  if [[ "$need_secret_value" -eq 1 ]]; then
    cat <<EOF
1. En https://login.tailscale.com/admin/settings/keys genera una auth key con:
   tag ${TS_TAG}, expiración corta, de un solo uso, pre-aprobada.
   (El tag debe existir en "tagOwners" de tu ACL.)
2. Cárgala tú mismo en Secret Manager (pégala y termina con Ctrl-D; no queda en el historial):

   gcloud secrets versions add ${SECRET_TS_AUTHKEY} --project=${PROJECT_ID} --data-file=-

EOF
  else
    echo "El secreto ${SECRET_TS_AUTHKEY} ya tiene una versión activa."
  fi
  cat <<EOF
La VM espera la key hasta ~10 min tras el arranque. Si ya pasó ese tiempo, vuelve a
ejecutar el startup script por IAP (como admin):

   gcloud compute ssh admin@${VM_NAME} --zone=${ZONE} --project=${PROJECT_ID} --tunnel-through-iap \\
     --command='sudo google_metadata_script_runner startup'

Progreso (sin secretos): sudo cat ${STARTUP_LOG}
Luego sigue docs/pasos-manuales.md (logins de Claude/GitHub y pareo con tu Mac).
EOF
}

main "$@"
