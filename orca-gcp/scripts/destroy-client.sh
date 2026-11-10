#!/usr/bin/env bash
# destroy-client.sh - elimina TODO lo que create-client.sh creó para un cliente.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
# shellcheck source-path=SCRIPTDIR
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Uso: destroy-client.sh <slug> [--dry-run] [--keep-secret] [--delete-snapshots] [--help]

Borra los recursos de GCP del cliente (solo los que existan), tras listarlos y exigir que
escribas el slug para confirmar:
  - VM orca-<slug> y su disco de arranque
  - Secreto tailscale-authkey-<slug>           (se conserva con --keep-secret)
  - Cuenta de servicio orca-vm-<slug>@bove-orca.iam.gserviceaccount.com
  - Políticas de recursos orca-horario-<slug> y orca-snapshots-<slug>
  - Snapshots del disco                        (solo con --delete-snapshots; por defecto SE CONSERVAN)

Opciones:
  --dry-run            lista y muestra los comandos; no consulta GCP, no pregunta, no borra
  --keep-secret        no borra el secreto (sí quita el permiso de la cuenta de servicio sobre él)
  --delete-snapshots   borra también los snapshots del disco (son tu respaldo: opt-in)
  -h, --help           esta ayuda

No revoca roles a nivel de proyecto ni borra el dispositivo en la consola de Tailscale
(ver el recordatorio al final).
EOF
}

main() {
  ALLOWED_FLAGS=(--keep-secret --delete-snapshots)
  parse_args "$@"
  if [[ $SHOW_HELP -eq 1 ]]; then usage; return 0; fi
  [[ ${#ARGS[@]} -eq 1 ]] || { usage >&2; die "Indica exactamente un slug."; }
  client_vars "${ARGS[0]}"
  preflight

  local keep_secret=0 del_snaps=0
  has_flag --keep-secret && keep_secret=1
  has_flag --delete-snapshots && del_snaps=1

  [[ $DRY_RUN -eq 1 ]] && info "MODO DRY-RUN: no se consulta ni se borra nada en GCP; se asume que todo existe"

  # --- Qué existe ---------------------------------------------------------------
  local has_vm=1 has_disk=1 has_secret=1 has_sa=1 has_sched=1 has_snappol=1
  local snapshots=()
  if [[ $DRY_RUN -eq 1 ]]; then
    snapshots=("<snapshots de orca-${CLIENT}, se listan al ejecutar>")
  else
    resource_exists "VM $VM_NAME" "$GCLOUD" compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format="value(name)" || has_vm=0
    resource_exists "disco $VM_NAME" "$GCLOUD" compute disks describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format="value(name)" || has_disk=0
    resource_exists "secreto $SECRET_TS_AUTHKEY" "$GCLOUD" secrets describe "$SECRET_TS_AUTHKEY" --project="$PROJECT_ID" --format="value(name)" || has_secret=0
    resource_exists "cuenta de servicio" "$GCLOUD" iam service-accounts describe "$SERVICE_ACCOUNT" --project="$PROJECT_ID" --format="value(email)" || has_sa=0
    resource_exists "política $SCHEDULE_NAME" "$GCLOUD" compute resource-policies describe "$SCHEDULE_NAME" --region="$REGION" --project="$PROJECT_ID" --format="value(name)" || has_sched=0
    resource_exists "política $SNAPSHOT_POLICY" "$GCLOUD" compute resource-policies describe "$SNAPSHOT_POLICY" --region="$REGION" --project="$PROJECT_ID" --format="value(name)" || has_snappol=0
    mapfile -t snapshots < <("$GCLOUD" compute snapshots list --project="$PROJECT_ID" \
      --filter="sourceDisk~/disks/${VM_NAME}\$" --format="value(name)")
  fi

  # --- Lista de lo que se borrará ---------------------------------------------
  echo
  echo "Proyecto: $PROJECT_ID | Cliente: $CLIENT"
  echo "SE BORRARÁ (irreversible):"
  [[ $has_vm -eq 1 ]]      && echo "  - VM $VM_NAME ($ZONE)"
  [[ $has_vm -eq 1 || $has_disk -eq 1 ]] && echo "  - Disco $VM_NAME y todos sus datos (repos, credenciales, historial de Orca)"
  if [[ $has_secret -eq 1 && $keep_secret -eq 0 ]]; then echo "  - Secreto $SECRET_TS_AUTHKEY (todas sus versiones)"; fi
  [[ $has_sa -eq 1 ]]      && echo "  - Cuenta de servicio $SERVICE_ACCOUNT"
  [[ $has_sched -eq 1 ]]   && echo "  - Política de horario $SCHEDULE_NAME"
  [[ $has_snappol -eq 1 ]] && echo "  - Política de snapshots $SNAPSHOT_POLICY"
  if [[ $del_snaps -eq 1 && ${#snapshots[@]} -gt 0 ]]; then
    local s; for s in "${snapshots[@]}"; do echo "  - Snapshot $s"; done
  fi
  echo "SE CONSERVARÁ:"
  if [[ $keep_secret -eq 1 && $has_secret -eq 1 ]]; then
    echo "  - Secreto $SECRET_TS_AUTHKEY (--keep-secret; se quita el permiso de la cuenta de servicio)"
  fi
  if [[ $del_snaps -eq 0 ]]; then
    echo "  - Snapshots del disco (usa --delete-snapshots para borrarlos; siguen generando costo)"
    if [[ ${#snapshots[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
      local s; for s in "${snapshots[@]}"; do echo "      · $s"; done
    fi
  fi
  echo

  if [[ $has_vm -eq 0 && $has_disk -eq 0 && $has_secret -eq 0 && $has_sa -eq 0 && $has_sched -eq 0 && $has_snappol -eq 0 && ${#snapshots[@]} -eq 0 ]]; then
    info "No existe ningún recurso del cliente $CLIENT. Nada que hacer."
    return 0
  fi

  # --- Confirmación explícita -------------------------------------------------
  if [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) en una ejecución real se te pediría escribir el slug '$CLIENT' para confirmar."
  else
    local typed=""
    printf "Para confirmar escribe el slug del cliente (%s): " "$CLIENT" >&2
    read -r typed || true
    [[ "$typed" == "$CLIENT" ]] || die "Confirmación incorrecta. No se borró nada."
  fi

  # --- Borrado (orden: VM -> disco -> políticas -> secreto -> cuenta de servicio) ---
  if [[ $has_vm -eq 1 ]]; then
    gc compute instances delete "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --delete-disks=all --quiet
    # Si el disco no tenía auto-delete, sigue existiendo: se borra aparte.
    if [[ $DRY_RUN -eq 0 ]] && resource_exists "disco $VM_NAME" "$GCLOUD" compute disks describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format="value(name)"; then
      has_disk=1
    else
      has_disk=0
    fi
  fi
  if [[ $has_disk -eq 1 ]]; then
    gc compute disks delete "$VM_NAME" --project="$PROJECT_ID" --zone="$ZONE" --quiet
  fi
  if [[ $has_sched -eq 1 ]]; then
    gc compute resource-policies delete "$SCHEDULE_NAME" --project="$PROJECT_ID" --region="$REGION" --quiet
  fi
  if [[ $has_snappol -eq 1 ]]; then
    gc compute resource-policies delete "$SNAPSHOT_POLICY" --project="$PROJECT_ID" --region="$REGION" --quiet
  fi
  if [[ $del_snaps -eq 1 && ${#snapshots[@]} -gt 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      gc compute snapshots delete "<cada-snapshot-de-${VM_NAME}>" --project="$PROJECT_ID" --quiet
    else
      local s; for s in "${snapshots[@]}"; do
        gc compute snapshots delete "$s" --project="$PROJECT_ID" --quiet
      done
    fi
  fi
  if [[ $has_secret -eq 1 ]]; then
    if [[ $keep_secret -eq 1 ]]; then
      # Puede no existir el binding (nunca concedido / ya quitado): no debe impedir borrar la cuenta.
      gc_try secrets remove-iam-policy-binding "$SECRET_TS_AUTHKEY" --project="$PROJECT_ID" \
        --member="serviceAccount:${SERVICE_ACCOUNT}" --role=roles/secretmanager.secretAccessor
    else
      gc secrets delete "$SECRET_TS_AUTHKEY" --project="$PROJECT_ID" --quiet
    fi
  fi
  if [[ $has_sa -eq 1 ]]; then
    gc iam service-accounts delete "$SERVICE_ACCOUNT" --project="$PROJECT_ID" --quiet
  fi

  cat <<EOF

Pendiente de tu parte (no se puede automatizar sin tus credenciales de Tailscale):
  - Elimina el dispositivo "${TS_HOSTNAME}" en https://login.tailscale.com/admin/machines
    y borra el tag ${TS_TAG} de tu ACL si ya no se usa.
  - Quita el servidor de Settings > Remote Orca Servers en tu Mac.
  - Revoca el token de GitHub y las sesiones de Claude/Codex que usaste en esa VM.
TODO(workspace 0): si bootstrap-project.sh client-sa otorga roles a nivel de proyecto a la
cuenta de servicio, deben revocarse (idealmente con un subcomando "client-sa-delete").
EOF
}

main "$@"
