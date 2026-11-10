#!/usr/bin/env bash
# pair-client.sh - genera UN link de pareo de Orca para un compañero, desde el Mac del dueño.
#
# Uso: pair-client.sh <slug> [--mobile] [--dry-run] [--help]
#
# Qué hace (por SSH vía IAP, como usuario orca en la VM orca-<slug>):
#   1. Detiene el servicio orca-serve.service (durante el pareo el servidor no atiende a nadie más).
#   2. Arranca una vez `orca-ide serve --port 6768 --pairing-address <IP-Tailscale>` como unidad
#      transitoria (orca-pairing.service), con la salida en un archivo con permisos 600.
#   3. Imprime el link de pareo EN TU TERMINAL (y en ningún otro sitio). Trátalo como contraseña:
#      envíalo por un canal cifrado solo a la persona que se va a parear. Un link = un cliente.
#   4. Espera a que pulses Enter (cuando el compañero vea "Connected"), detiene el pareo, borra el
#      archivo y vuelve a levantar el servicio normal.
# Requisitos: gcloud autenticado con permiso de IAP en el proyecto. No usa secretos propios.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-bove-orca}"
ZONE="${ZONE:-us-central1-a}"
ORCA_PORT="6768"
ORCA_USER="orca"
ADMIN_USER="orca-admin"
PAIR_FILE="/home/${ORCA_USER}/.orca-pairing.txt"
DRY_RUN=0; MOBILE=0; CLIENT=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --mobile) MOBILE=1 ;;
    -*) usage >&2; die "opción desconocida: $a" ;;
    *) [[ -z "$CLIENT" ]] || die "solo se admite un slug"; CLIENT="$a" ;;
  esac
done
[[ -n "$CLIENT" ]] || { usage >&2; die "falta <slug>"; }
[[ "$CLIENT" =~ ^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$ ]] || die "slug inválido '$CLIENT'"
VM_NAME="orca-${CLIENT}"
MOBILE_FLAG=""; [[ $MOBILE -eq 1 ]] && MOBILE_FLAG="--mobile-pairing"

ssh_vm() { # ssh_vm: ejecuta en la VM el script que llega por stdin, como orca (con sudo desde orca-admin)
  gcloud compute ssh "${ADMIN_USER}@${VM_NAME}" --project="$PROJECT_ID" --zone="$ZONE" \
    --tunnel-through-iap --quiet --ssh-flag='-o ConnectTimeout=30' \
    --command="sudo -u ${ORCA_USER} -i bash -s" 2> >(grep -v -i -E 'numpy|tcp_upload_bandwidth|^WARNING:|^$' >&2)
}

echo "== Pareo de un cliente nuevo con ${VM_NAME} (proyecto ${PROJECT_ID}) =="
if [[ $DRY_RUN -eq 1 ]]; then
  cat <<DRY
[dry-run] gcloud compute ssh ${ADMIN_USER}@${VM_NAME} --tunnel-through-iap --command 'sudo -u ${ORCA_USER} -i bash -s' <<'REMOTO'
  systemctl --user stop orca-serve.service
  systemd-run --user --unit=orca-pairing --collect -p StandardOutput=append:${PAIR_FILE} -p StandardError=append:${PAIR_FILE} \\
    /usr/bin/orca-ide serve --port ${ORCA_PORT} --pairing-address <IP-Tailscale> ${MOBILE_FLAG}
  (espera la línea "Pairing URL" y la imprime)
REMOTO
[dry-run] (Enter) -> systemctl --user stop orca-pairing.service; shred ${PAIR_FILE}; systemctl --user start orca-serve.service
DRY
  exit 0
fi

echo "-- Deteniendo el servicio y arrancando el servidor de pareo..."
link_out=$(ssh_vm <<REMOTE
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
TS_IP="\$(tailscale ip -4 2>/dev/null | head -1)"
[[ -n "\$TS_IP" ]] || { echo "ERROR: la VM no tiene IP de Tailscale (¿tailscale up?)" >&2; exit 1; }
systemctl --user stop orca-pairing.service 2>/dev/null || true
systemctl --user reset-failed orca-pairing.service 2>/dev/null || true
systemctl --user stop orca-serve.service
sleep 2
rm -f "${PAIR_FILE}"; install -m 600 /dev/null "${PAIR_FILE}"
systemd-run --user --quiet --unit=orca-pairing --collect \
  -p StandardOutput=append:${PAIR_FILE} -p StandardError=append:${PAIR_FILE} \
  /usr/bin/orca-ide serve --port ${ORCA_PORT} --pairing-address "\$TS_IP" ${MOBILE_FLAG}
for i in \$(seq 1 24); do
  sleep 5
  if grep -q -E "Pairing URL|pairing" "${PAIR_FILE}" && grep -q "Pairing URL" "${PAIR_FILE}"; then break; fi
done
echo "TS_IP=\$TS_IP"
grep -E "^Pairing URL|^Mobile pairing|^Web client URL" "${PAIR_FILE}" || { echo "ERROR: no apareció el link; salida:" >&2; sed -E 's#(orca://|https?://)[^ ]+#<link>#g' "${PAIR_FILE}" >&2; exit 1; }
REMOTE
)
echo
echo "$link_out" | grep -E '^TS_IP=' | sed 's/^/   /'
echo "=================================================================="
echo "$link_out" | grep -E '^(Pairing URL|Mobile pairing)' | sed 's/^/   /'
echo "=================================================================="
echo "Envía SOLO ese link, por un canal cifrado, a la persona que se va a parear."
echo "Ella lo pega en Orca → Settings → Remote Orca Servers → Add server."
echo
read -r -p "Cuando vea 'Connected', pulsa Enter para cerrar el pareo y restaurar el servicio... " _

echo "-- Restaurando el servicio normal..."
ssh_vm <<REMOTE
set -euo pipefail
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
systemctl --user stop orca-pairing.service 2>/dev/null || true
sleep 2
shred -u "${PAIR_FILE}" 2>/dev/null || rm -f "${PAIR_FILE}"
systemctl --user start orca-serve.service
for i in \$(seq 1 18); do sleep 5; ss -ltnH "( sport = :${ORCA_PORT} )" | grep -q . && break; done
echo "servicio: \$(systemctl --user is-active orca-serve.service); puerto ${ORCA_PORT}: \$(ss -ltnH "( sport = :${ORCA_PORT} )" | grep -q . && echo escuchando || echo NO escucha)"
echo "clientes conectados ahora: \$(ss -tnH state established "( sport = :${ORCA_PORT} )" | wc -l)"
REMOTE
echo "Listo. El cliente nuevo debe reconectarse solo al servicio (Settings → Remote Orca Servers → Connected)."
