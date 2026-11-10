#!/usr/bin/env bash
# verify-client.sh <slug> — Verificación de la Fase 5 (solo lectura).
#
# Ejecuta desde FUERA de la VM lo automatizable del checklist y, vía
# `gcloud compute ssh --tunnel-through-iap`, las comprobaciones internas.
# Imprime PASS / FAIL / WARN / SKIP por ítem y lista los ítems MANUAL.
# No crea ni modifica recursos. No lee el valor de ningún secreto.
set -euo pipefail

# --- Contratos compartidos (docs/PLAN.md) ------------------------------------
PROJECT_ID="${PROJECT_ID:-bove-orca}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
NETWORK="orca-vpc"
SUBNET="orca-subnet"
NETWORK_TAG="orca"
IAP_RANGE="35.235.240.0/20"
FW_RULE_IAP="orca-allow-iap-ssh"
ORCA_PORT="6768"
ORCA_USER="orca"
ADMIN_USER="orca-admin"
STARTUP_LOG="/var/log/orca-startup.log"
SCHEDULE_START_CRON="0 8 * * 1-5"
SCHEDULE_STOP_CRON="0 21 * * 1-5"
SCHEDULE_TZ="America/Santiago"
SNAPSHOT_RETENTION_DAYS="7"
ORCA_VERSION="${ORCA_VERSION:-}" # opcional: si se define, se compara con la metadata
# Patrones que NUNCA deben aparecer en metadata ni en logs (solo se cuentan, no se imprimen).
SECRET_REGEX='tskey-|ghp_[A-Za-z0-9]|github_pat_|gho_[A-Za-z0-9]|sk-ant-|AKIA[0-9A-Z]{12}|BEGIN [A-Z ]*PRIVATE KEY|orca://|pairing[-_ ]?(link|token|code)'

DRY_RUN=0
SKIP_SSH=0
SKIP_SCAN=0
CLIENT=""
PASS_N=0
FAIL_N=0
WARN_N=0
SKIP_N=0

usage() {
  cat <<EOF
Uso: $(basename "$0") [opciones] <slug>

Verificación de solo lectura de la VM orca-<slug> (Fase 5 de la spec).
Debe ejecutarse desde fuera de la VPC (tu Mac) para que el escaneo externo tenga sentido.

Opciones:
  --dry-run     Imprime los comandos gcloud/ssh/nc que ejecutaría, sin ejecutarlos.
  --skip-ssh    Omite las comprobaciones internas por IAP.
  --skip-scan   Omite el escaneo externo a la IP efímera.
  -h, --help    Muestra esta ayuda.

Variables opcionales: PROJECT_ID (bove-orca), REGION, ZONE, ORCA_VERSION.
Salida: una línea [PASS|FAIL|WARN|SKIP] por ítem; las IPs, correos y tokens se enmascaran.
Código de salida: 1 si algún ítem es FAIL, 0 en otro caso.
Nota: 'gcloud compute ssh' puede crear ~/.ssh/google_compute_engine y registrar tu llave
(OS Login o metadata). Es el único efecto lateral; usa --skip-ssh para evitarlo.
Requiere: gcloud autenticado (lo haces tú), nc; opcional: nmap, tailscale.
EOF
}

# --- Utilidades --------------------------------------------------------------
# Enmascara IPs, correos y patrones de tokens en todo lo que se imprime.
redact() {
  sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/(tskey-|ghp_|gho_|github_pat_|sk-ant-)[A-Za-z0-9_-]*/<redactado>/g'
}

say() { printf '%s\n' "$*" | redact; }

record() { # record STATUS ID descripción [detalle...]
  local status="$1" id="$2" desc="$3"
  shift 3
  case "$status" in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)) ;;
    WARN) WARN_N=$((WARN_N + 1)) ;;
    SKIP) SKIP_N=$((SKIP_N + 1)) ;;
    INFO) ;; # informativo, no cuenta
    *) ;;
  esac
  printf '[%s] %-7s %s\n' "$status" "$id" "$desc"
  local line
  for line in "$@"; do
    [[ -n "$line" ]] && printf '        %s\n' "$line" | redact
  done
  return 0
}

# gq: ejecuta gcloud (solo lectura). En dry-run solo imprime el comando.
gq() {
  if ((DRY_RUN)); then
    printf '+ gcloud %s\n' "$*" >&2
    return 0
  fi
  gcloud "$@" 2>/dev/null
}

has_item() { # has_item "a;b,c" b  -> 0 si b es un elemento
  printf '%s' "$1" | tr ';,' '\n' | grep -Fxq -- "$2"
}

# --- Argumentos --------------------------------------------------------------
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-ssh) SKIP_SSH=1 ;;
    --skip-scan) SKIP_SCAN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Opción desconocida: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$CLIENT" ]]; then
        echo "Solo se admite un slug." >&2
        exit 2
      fi
      CLIENT="$1"
      ;;
  esac
  shift
done

if [[ -z "$CLIENT" ]]; then
  usage >&2
  exit 2
fi
if ! [[ "$CLIENT" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]]; then
  echo "Slug inválido: use minúsculas, dígitos y guiones (ej: cliente-a)." >&2
  exit 2
fi

VM_NAME="orca-${CLIENT}"
SERVICE_ACCOUNT="orca-vm-${CLIENT}@${PROJECT_ID}.iam.gserviceaccount.com"
SECRET_TS_AUTHKEY="tailscale-authkey-${CLIENT}"
TS_HOSTNAME="orca-${CLIENT}"
TS_TAG="tag:orca-${CLIENT}"
SCHEDULE_NAME="orca-horario-${CLIENT}"
SNAPSHOT_POLICY="orca-snapshots-${CLIENT}"

if ! ((DRY_RUN)) && ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud no está instalado o no está en PATH." >&2
  exit 2
fi

echo "== Verificación de ${VM_NAME} (proyecto ${PROJECT_ID}, zona ${ZONE}) =="
((DRY_RUN)) && echo "(dry-run: se imprimen los comandos; no se ejecuta nada)"

# --- 1. Firewall -------------------------------------------------------------
fw_rules=$(gq compute firewall-rules list --project "$PROJECT_ID" \
  --filter="network~/${NETWORK}\$ AND direction=INGRESS AND disabled=false" \
  --format='value(name)' || true)
if ((DRY_RUN)); then
  record SKIP FW-01 "Solo existe la regla de ingreso ${FW_RULE_IAP} en ${NETWORK}"
elif [[ "$fw_rules" == "$FW_RULE_IAP" ]]; then
  record PASS FW-01 "Única regla de ingreso en ${NETWORK}: ${FW_RULE_IAP}"
elif [[ -z "$fw_rules" ]]; then
  record FAIL FW-01 "No existe ${FW_RULE_IAP} en ${NETWORK} (¿Fase 1 sin aplicar?)"
else
  record FAIL FW-01 "Hay reglas de ingreso adicionales en ${NETWORK}" "$(printf '%s' "$fw_rules" | tr '\n' ' ')"
fi

fw_src=$(gq compute firewall-rules describe "$FW_RULE_IAP" --project "$PROJECT_ID" --format='value(sourceRanges.list())' || true)
fw_allow=$(gq compute firewall-rules describe "$FW_RULE_IAP" --project "$PROJECT_ID" --format='value(allowed[].map().firewall_rule().list())' || true)
fw_tags=$(gq compute firewall-rules describe "$FW_RULE_IAP" --project "$PROJECT_ID" --format='value(targetTags.list())' || true)
if ((DRY_RUN)); then
  record SKIP FW-02 "${FW_RULE_IAP}: origen ${IAP_RANGE}, tcp:22, tag ${NETWORK_TAG}"
elif [[ "$fw_src" == "$IAP_RANGE" && "$fw_allow" == "tcp:22" && "$fw_tags" == "$NETWORK_TAG" ]]; then
  record PASS FW-02 "${FW_RULE_IAP}: origen ${IAP_RANGE}, tcp:22, tag ${NETWORK_TAG}"
else
  record FAIL FW-02 "${FW_RULE_IAP} no coincide con lo esperado" \
    "origen=${fw_src:-?} permite=${fw_allow:-?} tags=${fw_tags:-?}"
fi

open_any=$(gq compute firewall-rules list --project "$PROJECT_ID" \
  --filter="direction=INGRESS AND disabled=false AND sourceRanges:0.0.0.0/0" \
  --format='value(name,network.basename())' || true)
if ((DRY_RUN)); then
  record SKIP FW-03 "Ninguna regla de ingreso 0.0.0.0/0 en el proyecto"
elif [[ -z "$open_any" ]]; then
  record PASS FW-03 "Ninguna regla de ingreso desde 0.0.0.0/0 en el proyecto"
elif printf '%s\n' "$open_any" | grep -Fq "$NETWORK"; then
  record FAIL FW-03 "Regla de ingreso pública en ${NETWORK}" "$(printf '%s' "$open_any" | tr '\n' ';')"
else
  record WARN FW-03 "Reglas públicas en OTRAS redes (no afectan a ${NETWORK}; revisa/elimina default-allow-ssh)" \
    "$(printf '%s' "$open_any" | tr '\t\n' ' ;')"
fi

# --- 2. Estado de la VM ------------------------------------------------------
vm_status=$(gq compute instances describe "$VM_NAME" --zone "$ZONE" --project "$PROJECT_ID" --format='value(status)' || true)
if ((DRY_RUN)); then
  record SKIP VM-01 "La VM ${VM_NAME} existe y está RUNNING"
elif [[ "$vm_status" == "RUNNING" ]]; then
  record PASS VM-01 "La VM ${VM_NAME} está RUNNING"
elif [[ -z "$vm_status" ]]; then
  record FAIL VM-01 "La VM ${VM_NAME} no existe (o sin permisos)"
else
  record FAIL VM-01 "La VM está ${vm_status} (¿fuera de horario 08:00-21:00 lun-vie?). Enciéndela a mano y reintenta"
fi

desc_vm() { gq compute instances describe "$VM_NAME" --zone "$ZONE" --project "$PROJECT_ID" --format="$1" || true; }

if ((DRY_RUN)) || [[ -n "$vm_status" ]]; then
  vm_tags=$(desc_vm 'value(tags.items.list())')
  vm_label=$(desc_vm 'value(labels.cliente)')
  disk_src=$(desc_vm 'value(disks[0].source)')
  disk_name="${disk_src##*/}"
  disk_label=""
  if [[ -n "$disk_name" ]] || ((DRY_RUN)); then
    disk_label=$(gq compute disks describe "${disk_name:-DISCO}" --zone "$ZONE" --project "$PROJECT_ID" --format='value(labels.cliente)' || true)
  fi
  if ((DRY_RUN)); then
    record SKIP VM-02 "Tag de red ${NETWORK_TAG} y etiqueta cliente=${CLIENT} en VM y disco"
  elif has_item "$vm_tags" "$NETWORK_TAG" && [[ "$vm_label" == "$CLIENT" && "$disk_label" == "$CLIENT" ]]; then
    record PASS VM-02 "Tag ${NETWORK_TAG} y etiqueta cliente=${CLIENT} en VM y disco"
  else
    record FAIL VM-02 "Tag/etiquetas incorrectos" "tags=${vm_tags:-?} etiqueta_vm=${vm_label:-?} etiqueta_disco=${disk_label:-?}"
  fi

  vm_net=$(desc_vm 'value(networkInterfaces[0].network)')
  vm_subnet=$(desc_vm 'value(networkInterfaces[0].subnetwork)')
  vm_ip=$(desc_vm 'value(networkInterfaces[0].accessConfigs[0].natIP)')
  static_hit=""
  if [[ -n "$vm_ip" ]]; then
    static_hit=$(gq compute addresses list --project "$PROJECT_ID" --filter="address=${vm_ip}" --format='value(name)' || true)
  fi
  if ((DRY_RUN)); then
    record SKIP VM-03 "VM en ${NETWORK}/${SUBNET} con IP externa efímera (no reservada)"
  elif [[ "$vm_net" == */"$NETWORK" && "$vm_subnet" == */"$SUBNET" ]]; then
    if [[ -n "$static_hit" ]]; then
      record WARN VM-03 "La IP externa es una dirección RESERVADA (${static_hit}); la spec pide efímera"
    else
      record PASS VM-03 "VM en ${NETWORK}/${SUBNET}; IP externa $([[ -n "$vm_ip" ]] && echo efímera || echo 'ausente (¿Cloud NAT?)')"
    fi
  else
    record FAIL VM-03 "Red/subred inesperada" "red=${vm_net##*/} subred=${vm_subnet##*/}"
  fi

  vm_pol=$(desc_vm 'value(resourcePolicies.list())')
  disk_pol=$(gq compute disks describe "${disk_name:-DISCO}" --zone "$ZONE" --project "$PROJECT_ID" --format='value(resourcePolicies.list())' || true)
  if ((DRY_RUN)); then
    record SKIP POL-01 "Adjuntas: ${SCHEDULE_NAME} (VM) y ${SNAPSHOT_POLICY} (disco)"
  elif printf '%s' "$vm_pol" | grep -Fq "/${SCHEDULE_NAME}" && printf '%s' "$disk_pol" | grep -Fq "/${SNAPSHOT_POLICY}"; then
    record PASS POL-01 "Adjuntas: ${SCHEDULE_NAME} (VM) y ${SNAPSHOT_POLICY} (disco)"
  else
    record FAIL POL-01 "Políticas no adjuntas como se espera" \
      "VM=$(printf '%s' "$vm_pol" | tr ',' ' ' | sed 's#[^ ]*/##g')" \
      "disco=$(printf '%s' "$disk_pol" | tr ',' ' ' | sed 's#[^ ]*/##g')"
  fi

  sched=$(gq compute resource-policies describe "$SCHEDULE_NAME" --region "$REGION" --project "$PROJECT_ID" \
    --format='value(instanceSchedulePolicy.vmStartSchedule.schedule,instanceSchedulePolicy.vmStopSchedule.schedule,instanceSchedulePolicy.timeZone)' || true)
  snap=$(gq compute resource-policies describe "$SNAPSHOT_POLICY" --region "$REGION" --project "$PROJECT_ID" \
    --format='value(snapshotSchedulePolicy.retentionPolicy.maxRetentionDays,snapshotSchedulePolicy.schedule.dailySchedule.daysInCycle)' || true)
  sched_expected=$(printf '%s\t%s\t%s' "$SCHEDULE_START_CRON" "$SCHEDULE_STOP_CRON" "$SCHEDULE_TZ")
  if ((DRY_RUN)); then
    record SKIP POL-02 "Horario ${SCHEDULE_START_CRON} on / ${SCHEDULE_STOP_CRON} off (${SCHEDULE_TZ}); snapshots diarios, retención ${SNAPSHOT_RETENTION_DAYS} d"
  else
    if [[ "$sched" == "$sched_expected" ]]; then
      record PASS POL-02 "Horario ${SCHEDULE_START_CRON} on / ${SCHEDULE_STOP_CRON} off (${SCHEDULE_TZ})"
    else
      record FAIL POL-02 "Horario distinto del esperado o inexistente" "obtenido: $(printf '%s' "$sched" | tr '\t' '|')"
    fi
    if [[ "$snap" == "${SNAPSHOT_RETENTION_DAYS}"$'\t'1 ]]; then
      record PASS POL-03 "Snapshots programados con retención ${SNAPSHOT_RETENTION_DAYS} días"
    else
      record FAIL POL-03 "Política de snapshots ausente o con retención distinta de ${SNAPSHOT_RETENTION_DAYS} d" "obtenido: $(printf '%s' "$snap" | tr '\t' '|')"
    fi
  fi

  # --- 3. Metadata sin secretos, cuenta de servicio -------------------------
  meta_keys=$(desc_vm 'value(metadata.items[].key)')
  meta_vals=$(desc_vm 'value(metadata.items[].value)')
  if ((DRY_RUN)); then
    record SKIP META-01 "Metadata solo con client, orca-version, startup-script"
    record SKIP META-02 "Metadata y script sin patrones de secretos"
  else
    extra=""
    for k in $(printf '%s' "$meta_keys" | tr ';,' '  '); do
      case "$k" in client | orca-version | startup-script) ;; *) extra+="$k " ;; esac
    done
    if [[ -z "$extra" ]]; then
      record PASS META-01 "Metadata solo con client, orca-version, startup-script"
    elif [[ "$extra" =~ ^(enable-oslogin\ ?)+$ ]]; then
      record WARN META-01 "Metadata incluye ${extra}(permitido solo para OS Login; el contrato fija 3 claves)"
    else
      record FAIL META-01 "Claves de metadata fuera del contrato: ${extra}"
    fi
    secret_hits=$(printf '%s' "$meta_vals" | grep -Eic "$SECRET_REGEX" || true)
    if [[ "${secret_hits:-0}" == "0" ]]; then
      record PASS META-02 "Metadata y startup-script sin patrones de secretos"
    else
      record FAIL META-02 "${secret_hits} línea(s) de metadata coinciden con patrones de secretos (no se imprimen)"
    fi
    if [[ -n "$ORCA_VERSION" ]]; then
      meta_ver=$(desc_vm 'value(metadata.items.orca-version)')
      if [[ "$meta_ver" == "$ORCA_VERSION" ]]; then
        record PASS META-03 "orca-version en metadata = ORCA_VERSION (${ORCA_VERSION})"
      else
        record FAIL META-03 "orca-version en metadata (${meta_ver:-vacío}) ≠ ORCA_VERSION (${ORCA_VERSION})"
      fi
    else
      record SKIP META-03 "ORCA_VERSION no definida: no se compara con la versión del Mac"
    fi
  fi

  vm_sa=$(desc_vm 'value(serviceAccounts[0].email)')
  if ((DRY_RUN)); then
    record SKIP IAM-01 "La VM usa ${SERVICE_ACCOUNT}"
  elif [[ "$vm_sa" == "$SERVICE_ACCOUNT" ]]; then
    record PASS IAM-01 "La VM usa la cuenta de servicio dedicada"
  else
    record FAIL IAM-01 "Cuenta de servicio inesperada: ${vm_sa:-?}"
  fi
fi

# Secreto: solo se consulta existencia, IAM y número de versiones. NUNCA `versions access`.
secret_iam=$(gq secrets get-iam-policy "$SECRET_TS_AUTHKEY" --project "$PROJECT_ID" \
  --flatten='bindings[].members' --format='value(bindings.role,bindings.members)' || true)
if ((DRY_RUN)); then
  record SKIP IAM-02 "Solo ${SERVICE_ACCOUNT} es secretAccessor de ${SECRET_TS_AUTHKEY}"
elif [[ -z "$secret_iam" ]]; then
  record FAIL IAM-02 "No se pudo leer la IAM del secreto ${SECRET_TS_AUTHKEY} (¿no existe?)"
else
  accessors=$(printf '%s\n' "$secret_iam" | awk -F'\t' '$1=="roles/secretmanager.secretAccessor"{print $2}')
  if [[ "$accessors" == "serviceAccount:${SERVICE_ACCOUNT}" ]]; then
    record PASS IAM-02 "Solo la SA del cliente es secretAccessor de ${SECRET_TS_AUTHKEY}"
  else
    record FAIL IAM-02 "Accesores del secreto distintos de la SA del cliente" "$(printf '%s' "$accessors" | tr '\n' ' ')"
  fi
fi

proj_roles=$(gq projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
  --filter="bindings.members=serviceAccount:${SERVICE_ACCOUNT}" --format='value(bindings.role)' || true)
if ((DRY_RUN)); then
  record SKIP IAM-03 "La SA no tiene roles amplios a nivel de proyecto"
elif printf '%s\n' "$proj_roles" | grep -Eq 'secretmanager|owner|editor|viewer|compute\.(admin|instanceAdmin)|iam\.'; then
  record FAIL IAM-03 "La SA tiene roles amplios a nivel de proyecto" "$(printf '%s' "$proj_roles" | tr '\n' ' ')"
else
  record PASS IAM-03 "La SA no tiene roles de proyecto sobre Secret Manager/propietario/editor${proj_roles:+ (roles: $(printf '%s' "$proj_roles" | tr '\n' ' '))}"
fi

# --- 4. Escaneo externo a la IP efímera --------------------------------------
if ((SKIP_SCAN)); then
  record SKIP SCAN-01 "Escaneo externo omitido (--skip-scan)"
elif ((DRY_RUN)); then
  echo "+ nc -z -w 3 <IP_EFIMERA> {22,80,443,${ORCA_PORT}}   # y nmap -Pn -p 1-1024,${ORCA_PORT} si está instalado"
  record SKIP SCAN-01 "Puertos 22/80/443/${ORCA_PORT} cerrados o filtrados desde fuera de la VPC"
elif ! command -v nc >/dev/null 2>&1; then
  record SKIP SCAN-01 "nc no está instalado: no se puede escanear (no cuenta como PASS)"
elif [[ -z "${vm_ip:-}" ]]; then
  record SKIP SCAN-01 "La VM no tiene IP externa (apagada o con Cloud NAT): no hay nada que escanear"
else
  open_ports=""
  for p in 22 80 443 "$ORCA_PORT"; do
    if nc -z -w 3 "$vm_ip" "$p" >/dev/null 2>&1; then open_ports+="$p "; fi
  done
  nmap_note=""
  if command -v nmap >/dev/null 2>&1; then
    nmap_open=$(nmap -Pn -T4 -p 1-1024,"$ORCA_PORT" --open -oG - "$vm_ip" 2>/dev/null | grep -c '/open/' || true)
    [[ "${nmap_open:-0}" != "0" ]] && open_ports+="(nmap:abiertos) "
    nmap_note="nmap ejecutado (puertos 1-1024 y ${ORCA_PORT})"
  else
    nmap_note="nmap no instalado: solo se probó con nc"
  fi
  if [[ -z "$open_ports" ]]; then
    record PASS SCAN-01 "Sin puertos abiertos desde fuera de la VPC" "$nmap_note"
  else
    record FAIL SCAN-01 "Puertos abiertos al público: ${open_ports}" "$nmap_note"
  fi
fi

# --- 5. Tailscale desde este equipo (solo lectura) ---------------------------
TS_BIN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_BIN="tailscale"
elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi
if ((DRY_RUN)); then
  echo "+ tailscale status | grep ${TS_HOSTNAME};  nc -z -w 5 ${TS_HOSTNAME} ${ORCA_PORT}"
  record SKIP TS-01 "Desde este equipo, ${TS_HOSTNAME} aparece en la tailnet y ${ORCA_PORT} responde"
elif [[ -z "$TS_BIN" ]]; then
  record SKIP TS-01 "CLI de tailscale no encontrada en este equipo"
elif ! "$TS_BIN" status 2>/dev/null | grep -Fq "$TS_HOSTNAME"; then
  record FAIL TS-01 "${TS_HOSTNAME} no aparece en 'tailscale status' de este equipo (¿VM apagada, sin parear o ACL?)"
elif nc -z -w 5 "$TS_HOSTNAME" "$ORCA_PORT" >/dev/null 2>&1; then
  record PASS TS-01 "${TS_HOSTNAME} visible en la tailnet y ${ORCA_PORT} responde por Tailscale"
else
  record WARN TS-01 "${TS_HOSTNAME} visible pero ${ORCA_PORT} no responde (¿servicio detenido o ACL?)"
fi

# --- 6. Comprobaciones internas por IAP --------------------------------------
# Script remoto de solo lectura. Cada línea de salida: @@ID|ESTADO|descripción|detalle
remote_script() {
  cat <<'REMOTE'
#!/usr/bin/env bash
set -u
ORCA_USER="__ORCA_USER__"; ORCA_PORT="__ORCA_PORT__"; TS_HOSTNAME="__TS_HOSTNAME__"
TS_TAG="__TS_TAG__"; STARTUP_LOG="__STARTUP_LOG__"; SECRET_REGEX='__SECRET_REGEX__'
emit() { printf '@@%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}"; }
ouid=$(id -u "$ORCA_USER" 2>/dev/null || echo "")
as_orca() { sudo -n -u "$ORCA_USER" -H env XDG_RUNTIME_DIR="/run/user/${ouid}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${ouid}/bus" "$@"; }
ohome=$(getent passwd "$ORCA_USER" | cut -d: -f6)

# Tailscale (estado, tag, hostname) — sin imprimir IPs ni claves
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  js=$(sudo -n tailscale status --json 2>/dev/null || true)
  state=$(printf '%s' "$js" | jq -r '.BackendState // "?"')
  host=$(printf '%s' "$js" | jq -r '.Self.HostName // "?"')
  tags=$(printf '%s' "$js" | jq -r '(.Self.Tags // []) | join(",")')
  if [ "$state" = "Running" ] && [ "$host" = "$TS_HOSTNAME" ] && [ "$tags" = "$TS_TAG" ]; then
    emit TSI-01 PASS "Tailscale Running, hostname ${host}, tag ${tags}"
  else
    emit TSI-01 FAIL "Tailscale no coincide" "estado=${state} host=${host} tags=${tags:-ninguno}"
  fi
else
  emit TSI-01 FAIL "tailscale o jq no instalados en la VM"
fi

# Servicio de Orca
if [ -z "$ouid" ]; then
  emit SVC-01 FAIL "El usuario ${ORCA_USER} no existe"
else
  st=$(as_orca orca-ide serve service status 2>&1 | head -n 5 | tr '\n' ' ')
  if printf '%s' "$st" | grep -Eiq 'not running|stopped|inactive|failed|not installed'; then
    emit SVC-01 FAIL "orca-ide serve service status no reporta running" "$st"
  elif printf '%s' "$st" | grep -Eiq 'running|active'; then
    emit SVC-01 PASS "orca-ide serve service status = running" "$st"
  else
    emit SVC-01 FAIL "Salida de status no reconocida" "$st"
  fi
  unit=$(as_orca systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '/orca/{print $1" "$2}' | head -n 3 | tr '\n' ';')
  linger=$(loginctl show-user "$ORCA_USER" -p Linger --value 2>/dev/null || echo "?")
  if [ "$linger" = "yes" ] && printf '%s' "$unit" | grep -q 'enabled'; then
    emit SVC-02 PASS "Linger activo y unidad systemd de usuario habilitada (sobrevive a reinicio)" "$unit"
  else
    emit SVC-02 FAIL "Linger=${linger}; unidad: ${unit:-no encontrada}"
  fi
  emit SVC-03 INFO "Arranque de la VM (compara antes/después de 'sudo reboot')" "$(uptime -s 2>/dev/null)"
  bind=$(ss -H -ltn "sport = :${ORCA_PORT}" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')
  emit SVC-04 INFO "Socket del servidor en el puerto ${ORCA_PORT}" "${bind:-sin listener} (informativo; el firewall ya bloquea el acceso público)"
fi

# Sudo
if [ -n "$ouid" ]; then
  if as_orca sudo -n true >/dev/null 2>&1; then
    emit SUDO-01 FAIL "${ORCA_USER} PUEDE ejecutar sudo -n true"
  else
    emit SUDO-01 PASS "sudo -n true como ${ORCA_USER} falla (esperado)"
  fi
  grp=$(id -nG "$ORCA_USER" | tr ' ' '\n' | grep -Ex 'sudo|wheel|admin|google-sudoers|adm|docker|lxd' | tr '\n' ' ')
  if [ -n "$grp" ]; then
    emit SUDO-02 FAIL "${ORCA_USER} pertenece a grupos privilegiados" "$grp"
  else
    emit SUDO-02 PASS "${ORCA_USER} sin grupos sudo/admin/docker/lxd"
  fi
  sl=$(sudo -n -l -U "$ORCA_USER" 2>&1 | tail -n 2 | tr '\n' ' ')
  emit SUDO-03 INFO "sudo -l -U ${ORCA_USER}" "$sl"
fi

# Credenciales: solo nombres de archivo/variables, jamás valores
if [ -n "$ohome" ]; then
  keys=$(sudo -n find "$ohome/.ssh" -maxdepth 1 -type f 2>/dev/null | while read -r f; do
    sudo -n grep -lE 'BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; done | sed "s#$ohome/##" | tr '\n' ' ')
  if [ -n "$keys" ]; then
    emit CRED-01 WARN "Hay llaves SSH privadas en el home de ${ORCA_USER} (verifica que sean del cliente)" "$keys"
  else
    emit CRED-01 PASS "Sin llaves SSH privadas en ~${ORCA_USER}/.ssh"
  fi
  extra=$(for d in .aws .azure .kube .docker .config/gcloud .config/op .netrc .npmrc .pypirc; do
    sudo -n test -e "$ohome/$d" && printf '%s ' "$d"; done)
  if [ -n "$extra" ]; then
    emit CRED-02 WARN "Existen rutas con credenciales posibles (¿del cliente?)" "$extra"
  else
    emit CRED-02 PASS "Sin .aws/.azure/.kube/.docker/gcloud/op/.netrc/.npmrc/.pypirc"
  fi
  gh_state=$(sudo -n test -d "$ohome/.config/gh" && echo presente || echo ausente)
  cl_state=$(sudo -n test -d "$ohome/.claude" && echo presente || echo ausente)
  emit CRED-03 INFO "\$HOME/.config/gh de ${ORCA_USER}: ${gh_state}; .claude: ${cl_state} (deben ser cuentas del CLIENTE: revisar a mano con 'gh auth status' y 'orca-ide account list')"
  if [ -n "$ouid" ]; then
    names=$(for p in $(pgrep -u "$ORCA_USER" -f 'orca|claude|codex' 2>/dev/null | head -n 20); do
      sudo -n cat "/proc/$p/environ" 2>/dev/null | tr '\0' '\n' | cut -d= -f1; done |
      grep -Ei 'token|secret|passw|api_?key|auth|credential|^AWS_|^GH_|^GITHUB_|^ANTHROPIC|^OPENAI' | sort -u | tr '\n' ' ')
    if [ -n "$names" ]; then
      emit CRED-04 WARN "Variables de entorno con nombre sensible en procesos de ${ORCA_USER} (solo nombres)" "$names"
    else
      emit CRED-04 PASS "Sin variables de entorno de credenciales en procesos de ${ORCA_USER}"
    fi
  fi
fi

# Log de arranque sin secretos
if [ -r "$STARTUP_LOG" ]; then
  hits=$(grep -Eic "$SECRET_REGEX" "$STARTUP_LOG" 2>/dev/null || true)
  perm=$(stat -c '%a' "$STARTUP_LOG" 2>/dev/null)
  if [ "${hits:-0}" = "0" ]; then
    emit LOG-01 PASS "${STARTUP_LOG} sin patrones de secretos (permisos ${perm})"
  else
    emit LOG-01 FAIL "${STARTUP_LOG} contiene ${hits} línea(s) con patrones de secretos (no se imprimen)"
  fi
  steps=$(grep -Eic 'ok|done|listo|terminad' "$STARTUP_LOG" 2>/dev/null || true)
  emit LOG-02 INFO "Líneas de pasos completados en el log de arranque: ${steps}" "$(tail -n 3 "$STARTUP_LOG" | cut -c1-120 | tr '\n' ' ')"
else
  emit LOG-01 FAIL "No se puede leer ${STARTUP_LOG}"
fi

# Agente de Claude Code
if [ -n "$ouid" ]; then
  cv=$(as_orca bash -lc 'claude --version 2>&1 | head -n 1' 2>/dev/null)
  if [ -n "$cv" ] && ! printf '%s' "$cv" | grep -qi 'not found'; then
    emit AGT-01 PASS "Claude Code instalado para ${ORCA_USER}" "$cv"
  else
    emit AGT-01 FAIL "Claude Code no encontrado para ${ORCA_USER}"
  fi
  n=$(pgrep -u "$ORCA_USER" -fc 'claude' 2>/dev/null || echo 0)
  emit AGT-02 INFO "Procesos de claude en ejecución como ${ORCA_USER}: ${n} (la prueba de laptop cerrada es manual)"
  pk=$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep -i orca | head -n 2 | tr '\n' ';')
  emit ORC-01 INFO "Paquete de Orca instalado (compara con ORCA_VERSION y con el Mac)" "${pk:-no encontrado vía dpkg}"
fi
REMOTE
}

remote_payload() {
  remote_script | sed \
    -e "s|__ORCA_USER__|${ORCA_USER}|g" \
    -e "s|__ORCA_PORT__|${ORCA_PORT}|g" \
    -e "s|__TS_HOSTNAME__|${TS_HOSTNAME}|g" \
    -e "s|__TS_TAG__|${TS_TAG}|g" \
    -e "s|__STARTUP_LOG__|${STARTUP_LOG}|g" \
    -e "s#__SECRET_REGEX__#${SECRET_REGEX}#g"
}

if ((SKIP_SSH)); then
  record SKIP SSH-01 "Comprobaciones internas omitidas (--skip-ssh)"
elif ((DRY_RUN)); then
  echo "+ gcloud compute ssh ${ADMIN_USER}@${VM_NAME} --zone ${ZONE} --project ${PROJECT_ID} --tunnel-through-iap --quiet --command 'bash -s' < <script remoto de solo lectura>"
  record SKIP SSH-01 "Comprobaciones internas por IAP (Tailscale, servicio, sudo, credenciales, log, agente)"
elif [[ "$vm_status" != "RUNNING" ]]; then
  record SKIP SSH-01 "VM no RUNNING: no se pueden hacer las comprobaciones internas"
else
  ssh_err=$(mktemp)
  ssh_out=$(remote_payload | gcloud compute ssh "${ADMIN_USER}@${VM_NAME}" --zone "$ZONE" --project "$PROJECT_ID" \
    --tunnel-through-iap --quiet --command 'bash -s' 2>"$ssh_err" || true)
  if ! printf '%s\n' "$ssh_out" | grep -q '^@@'; then
    record FAIL SSH-01 "No se obtuvo salida por IAP (permiso IAP-secured Tunnel User, usuario ${ADMIN_USER}, regla de firewall o OS Login)" \
      "$(tail -n 3 "$ssh_err" | tr '\n' ' ')"
  else
    while IFS='|' read -r rid rstatus rdesc rdetail; do
      rid="${rid#@@}"
      rdesc=$(printf '%s' "$rdesc" | redact)
      case "$rstatus" in
        PASS | FAIL | WARN | INFO) record "$rstatus" "$rid" "$rdesc" "$rdetail" ;;
        *) ;;
      esac
    done < <(printf '%s\n' "$ssh_out" | grep '^@@')
  fi
  rm -f "$ssh_err"
fi

# --- Ítems manuales ----------------------------------------------------------
cat <<EOF

Ítems MANUALES (ver orca-gcp/docs/verificacion.md):
  MAN-01  ACL de Tailscale desde un dispositivo no autorizado (debe fallar)
  MAN-02  Mac: Settings → Remote Orca Servers = Connected y creación de un worktree
  MAN-03  Agente de Claude Code sigue vivo con la laptop cerrada
  MAN-04  'sudo reboot' y servicio running de nuevo (ejecuta este script antes y después)
  MAN-05  Cuentas gh/claude/codex de la VM son del cliente (no del Mac)
  MAN-06  Prueba crítica: orca-gcp/docs/comandos-mac-auth.md

== Resumen: PASS=${PASS_N} FAIL=${FAIL_N} WARN=${WARN_N} SKIP=${SKIP_N} ==
EOF

((FAIL_N == 0))
