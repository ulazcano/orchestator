#!/usr/bin/env bash
# run-tests.sh - pruebas de los scripts de orca-gcp. No toca GCP (gcloud real nunca se invoca).
#   ./run-tests.sh            sintaxis, shellcheck, dry-run vs. esperado, pruebas con stub de gcloud
#   ./run-tests.sh --update   regenera tests/expected/*.txt desde la salida actual
#   ./run-tests.sh --container  además corre la prueba de vm-startup.sh en un contenedor ubuntu:24.04
# shellcheck disable=SC2015  # idioma "cond && ok || fail": ok() siempre devuelve 0, así que fail solo corre si cond falla
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
EXPECTED="${TESTS_DIR}/expected"
UPDATE=0; CONTAINER=0
for a in "$@"; do
  case "$a" in --update) UPDATE=1 ;; --container) CONTAINER=1 ;; *) echo "flag desconocido: $a"; exit 2 ;; esac
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() { # check "descripción" comando...
  local d="$1"; shift
  local out; if out="$("$@" 2>&1)"; then ok "$d"; else fail "$d" "$out"; fi
}
contains()    { grep -qF -- "$2" <<<"$1"; }
not_contains(){ ! grep -qF -- "$2" <<<"$1"; }
norm() { sed "s#${ROOT}#<REPO>/orca-gcp#g"; }

export ORCA_VERSION="1.4.255"
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
export FAKE_GCLOUD_LOG="$LOG"
# bootstrap-project.sh (workspace 0) puede no existir aún: las pruebas fijan su ruta.
export BOOTSTRAP_SCRIPT="${TESTS_DIR}/bin/no-existe-bootstrap-project.sh"
FAKE=(env "GCLOUD=${TESTS_DIR}/bin/gcloud")

reset_log() { : >"$LOG"; }
logged()    { grep -qF -- "$1" "$LOG"; }

echo "== Sintaxis y shellcheck =="
for f in "${SCRIPTS}"/*.sh "${TESTS_DIR}"/*.sh "${TESTS_DIR}/bin/gcloud"; do
  check "bash -n $(basename "$f")" bash -n "$f"
done
if command -v shellcheck >/dev/null; then
  for f in "${SCRIPTS}"/*.sh "${TESTS_DIR}"/*.sh "${TESTS_DIR}/bin/gcloud"; do
    check "shellcheck $(basename "$f")" shellcheck -x "$f"
  done
else
  fail "shellcheck no está instalado"
fi

echo "== Dry-run contra salida esperada =="
mkdir -p "$EXPECTED"
cc_out="$("${SCRIPTS}/create-client.sh" cliente-a --dry-run 2>&1 | norm)"
dc_out="$("${SCRIPTS}/destroy-client.sh" cliente-a --dry-run 2>&1 | norm)"
dk_out="$("${SCRIPTS}/destroy-client.sh" cliente-a --dry-run --keep-secret --delete-snapshots 2>&1 | norm)"
if [[ $UPDATE -eq 1 ]]; then
  printf '%s\n' "$cc_out" >"${EXPECTED}/create-client.cliente-a.dry-run.txt"
  printf '%s\n' "$dc_out" >"${EXPECTED}/destroy-client.cliente-a.dry-run.txt"
  printf '%s\n' "$dk_out" >"${EXPECTED}/destroy-client.cliente-a.dry-run.keep-secret.txt"
  echo "  (esperados regenerados)"
fi
for pair in "create-client.cliente-a.dry-run:$cc_out" "destroy-client.cliente-a.dry-run:$dc_out" "destroy-client.cliente-a.dry-run.keep-secret:$dk_out"; do
  name="${pair%%:*}"; got="${pair#*:}"
  if diff <(printf '%s\n' "$got") "${EXPECTED}/${name}.txt" >/dev/null 2>&1; then ok "salida == expected/${name}.txt"
  else fail "salida != expected/${name}.txt" "$(diff <(printf '%s\n' "$got") "${EXPECTED}/${name}.txt" 2>&1 | head -20)"; fi
done

echo "== Contenido de create-client (dry-run) =="
contains "$cc_out" "--machine-type=n4-standard-8"        && ok "n4-standard-8 por defecto" || fail "machine-type por defecto"
contains "$cc_out" "--boot-disk-size=200GB"              && ok "200 GB por defecto"        || fail "disco por defecto"
contains "$cc_out" "--boot-disk-type=hyperdisk-balanced" && ok "hyperdisk-balanced"        || fail "tipo de disco"
contains "$cc_out" "--tags=orca"                         && ok "tag de red orca"           || fail "tag de red"
contains "$cc_out" "--labels=cliente=cliente-a"          && ok "etiqueta cliente en VM"    || fail "etiqueta VM"
contains "$cc_out" "--update-labels=cliente=cliente-a"   && ok "etiqueta cliente en disco" || fail "etiqueta disco"
contains "$cc_out" "--metadata=client=cliente-a,orca-version=1.4.255" && ok "metadata solo client y orca-version" || fail "metadata"
contains "$cc_out" "--metadata-from-file=startup-script=" && ok "startup-script desde archivo" || fail "startup-script"
not_contains "$cc_out" "--no-address"                    && ok "IP externa efímera (sin --no-address)" || fail "IP"
not_contains "$cc_out" "tskey-"                          && ok "sin auth keys en la salida" || fail "auth key en la salida"
contains "$cc_out" "gcloud secrets versions add tailscale-authkey-cliente-a --project=bove-orca --data-file=-" \
  && ok "imprime la instrucción para cargar la key (a mano)" || fail "instrucción de carga de la key"
[[ "$(grep -c '\[dry-run\] gcloud secrets versions' <<<"$cc_out")" == 0 ]] && ok "no hay 'versions add' ejecutable" || fail "versions add ejecutable"
contains "$cc_out" "bootstrap-project.sh" && contains "$cc_out" "client-sa cliente-a" && ok "llamada a bootstrap-project.sh client-sa cliente-a presente" || fail "llamada a bootstrap-project.sh"

echo "== Validaciones y ayuda =="
for s in "Cliente" "cliente_a" "-a" "a-" "1abc" "abcdefghijklmnopqrstuvwxyz" ""; do
  out="$("${SCRIPTS}/create-client.sh" "$s" --dry-run 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] && ok "slug inválido rechazado: '${s}'" || fail "slug inválido aceptado: '${s}'" "$out"
done
for s in cliente-a a abc-123 empresa-x-2; do
  out="$("${SCRIPTS}/create-client.sh" "$s" --dry-run 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && ok "slug válido aceptado: '${s}'" || fail "slug válido rechazado: '${s}'" "$out"
done
out="$(env -u ORCA_VERSION "${SCRIPTS}/create-client.sh" cliente-a --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && contains "$out" "ORCA_VERSION" && ok "sin ORCA_VERSION falla con mensaje claro" || fail "ORCA_VERSION no exigida" "$out"
out="$(env -u ORCA_VERSION "${SCRIPTS}/create-client.sh" --help 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "create-client --help funciona sin ORCA_VERSION" || fail "--help" "$out"
out="$("${SCRIPTS}/destroy-client.sh" --help 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$out" "--keep-secret" && ok "destroy-client --help" || fail "destroy --help" "$out"
out="$("${SCRIPTS}/create-client.sh" cliente-a --dry-run --foo 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "flag desconocido rechazado" || fail "flag desconocido aceptado"
out="$("${SCRIPTS}/create-client.sh" cliente-a n4-standard-8 10 --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "disco < 50 GB rechazado" || fail "disk-gb inválido aceptado"
out="$("${SCRIPTS}/create-client.sh" cliente-a n4-standard-8 0200 --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "disk-gb con cero inicial rechazado" || fail "disk-gb '0200' aceptado"
out="$(ORCA_VERSION=1.4.255-rc.1 "${SCRIPTS}/create-client.sh" cliente-a --dry-run 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "ORCA_VERSION con sufijo rc rechazada (vm-startup.sh solo acepta X.Y.Z)" || fail "ORCA_VERSION con sufijo aceptada"
out="$("${SCRIPTS}/create-client.sh" cliente-a e2-standard-4 120 --dry-run 2>&1)"
contains "$out" "--machine-type=e2-standard-4" && contains "$out" "--boot-disk-size=120GB" && ok "machine-type y disk-gb posicionales" || fail "argumentos posicionales"

echo "== create-client con stub de gcloud (modo real, sin GCP) =="
reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS=vm "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$out" "ya existe" && ! logged "instances create" && ! logged "secrets create" \
  && ok "VM existente: lo dice, sale con 0 y no la recrea ni crea secretos" || fail "idempotencia con VM existente" "$out"
logged "disks update orca-cliente-a" && ! logged "add-resource-policies" \
  && ok "VM existente sin políticas: solo reasegura la etiqueta del disco" || fail "reconciliación sin políticas" "$out"

reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS=vm,sched,snappol "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! logged "instances create" && logged "instances add-resource-policies orca-cliente-a" && logged "disks add-resource-policies orca-cliente-a" \
  && ok "VM existente + políticas nuevas: se adjuntan al reejecutar (completa ejecuciones a medias)" || fail "reconciliación con políticas" "$out"

reset_log
out="$("${FAKE[@]}" GCLOUD=/no/existe/gcloud "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && contains "$out" "No encuentro" && ok "gcloud ausente: aborta (no lo confunde con 'recurso inexistente')" || fail "gcloud ausente" "$out"
out="$(echo cliente-a | "${FAKE[@]}" GCLOUD=/no/existe/gcloud "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! contains "$out" "Nada que hacer" && ok "destroy con gcloud ausente: aborta, no dice 'Nada que hacer'" || fail "destroy con gcloud ausente" "$out"
reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_FAIL="projects describe" "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && contains "$out" "No puedo acceder al proyecto" && ! logged "instances create" && ok "proyecto inaccesible: aborta antes de crear nada" || fail "preflight de proyecto" "$out"

reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS=sa "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && logged "secrets create tailscale-authkey-cliente-a" && logged "instances create orca-cliente-a" \
  && logged "disks update orca-cliente-a" && ! logged "add-resource-policies" \
  && ok "VM nueva: crea secreto, VM y etiqueta disco; sin políticas si no existen" || fail "creación con stub" "$out"
! logged "versions add" && ok "nunca ejecuta 'secrets versions add'" || fail "ejecutó versions add"

reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS=sa,secret,secret-version,sched,snappol "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! logged "secrets create" && logged "instances add-resource-policies orca-cliente-a" \
  && logged "disks add-resource-policies orca-cliente-a" && contains "$out" "ya tiene una versión activa" \
  && ok "secreto existente no se recrea; políticas existentes se adjuntan" || fail "secreto/políticas existentes" "$out"

reset_log
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS= "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! logged "instances create" && ok "sin bootstrap-project.sh ni cuenta de servicio: aborta antes de crear la VM" \
  || fail "debió abortar sin cuenta de servicio" "$out"

reset_log
cat >"${TESTS_DIR}/bin/.denied" <<'EOS'
#!/usr/bin/env bash
echo "ERROR: (gcloud) PERMISSION_DENIED: The caller does not have permission" >&2; exit 1
EOS
chmod +x "${TESTS_DIR}/bin/.denied"
out="$(env "GCLOUD=${TESTS_DIR}/bin/.denied" "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
rm -f "${TESTS_DIR}/bin/.denied"
[[ $rc -ne 0 ]] && contains "$out" "PERMISSION_DENIED" && ok "error de permisos se muestra tal cual y aborta (sin reintentos)" || fail "manejo de error real" "$out"

reset_log
cat >"${TESTS_DIR}/bin/.fake-bootstrap" <<'EOS'
#!/usr/bin/env bash
echo "bootstrap $*" >>"${FAKE_GCLOUD_LOG:?}"
EOS
chmod +x "${TESTS_DIR}/bin/.fake-bootstrap"
out="$("${FAKE[@]}" FAKE_GCLOUD_EXISTS= BOOTSTRAP_SCRIPT="${TESTS_DIR}/bin/.fake-bootstrap" "${SCRIPTS}/create-client.sh" cliente-a 2>&1)"; rc=$?
rm -f "${TESTS_DIR}/bin/.fake-bootstrap"
[[ $rc -eq 0 ]] && logged "bootstrap client-sa cliente-a" && logged "instances create orca-cliente-a" \
  && ok "con bootstrap-project.sh presente: lo invoca (client-sa cliente-a) y crea la VM" || fail "invocación de bootstrap" "$out"

echo "== destroy-client con stub de gcloud =="
ALL=vm,disk,secret,sa,sched,snappol
reset_log
out="$(echo "otro-slug" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! logged " delete " && contains "$out" "Confirmación incorrecta" && ok "confirmación incorrecta: no borra nada" || fail "confirmación incorrecta" "$out"

reset_log
out="$(echo "" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ! logged " delete " && ok "confirmación vacía/EOF: no borra nada" || fail "confirmación vacía" "$out"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && logged "instances delete orca-cliente-a" && logged "secrets delete tailscale-authkey-cliente-a" \
  && logged "service-accounts delete orca-vm-cliente-a@bove-orca.iam.gserviceaccount.com" \
  && logged "resource-policies delete orca-horario-cliente-a" && logged "resource-policies delete orca-snapshots-cliente-a" \
  && ok "confirmación correcta: borra VM, secreto, SA y políticas" || fail "borrado completo" "$out"
! logged "snapshots delete" && ok "snapshots se conservan por defecto" || fail "borró snapshots sin pedirlo"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL "${SCRIPTS}/destroy-client.sh" cliente-a --keep-secret 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! logged "secrets delete" && logged "secrets remove-iam-policy-binding" && ok "--keep-secret conserva el secreto y revoca el acceso de la SA" || fail "--keep-secret" "$out"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL FAKE_GCLOUD_FAIL="remove-iam-policy-binding" "${SCRIPTS}/destroy-client.sh" cliente-a --keep-secret 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && logged "service-accounts delete" && contains "$out" "se continúa" && ok "--keep-secret: si falla quitar el binding, igual borra la cuenta de servicio" || fail "--keep-secret con binding inexistente" "$out"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=$ALL,snapshots "${SCRIPTS}/destroy-client.sh" cliente-a --delete-snapshots 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && logged "snapshots delete orca-cliente-a-snap-1" && ok "--delete-snapshots borra los snapshots" || fail "--delete-snapshots" "$out"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS= "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! logged " delete " && contains "$out" "Nada que hacer" && ok "sin recursos: no hace nada" || fail "sin recursos" "$out"

reset_log
out="$(echo "cliente-a" | "${FAKE[@]}" FAKE_GCLOUD_EXISTS=secret,sa "${SCRIPTS}/destroy-client.sh" cliente-a 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ! logged "instances delete" && logged "secrets delete" && not_contains "$out" "- VM " \
  && ok "solo lista y borra lo que existe" || fail "borrado parcial" "$out"

echo "== Higiene de secretos =="
if grep -rnE 'tskey-(auth|api|client)-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}' "$ROOT" --include='*' -I >/dev/null 2>&1; then
  fail "hay patrones parecidos a secretos en orca-gcp/" "$(grep -rnE 'tskey-(auth|api|client)-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}' "$ROOT" -I | head)"
else ok "sin patrones de secretos en orca-gcp/"; fi

if [[ $CONTAINER -eq 1 ]]; then
  echo "== vm-startup.sh en contenedor ubuntu:24.04 =="
  if "${TESTS_DIR}/run-startup-container.sh"; then ok "prueba de contenedor"; else fail "prueba de contenedor (ver salida arriba)"; fi
fi

echo
echo "Resultado: ${PASS} ok, ${FAIL} fallos"
[[ $FAIL -eq 0 ]]
