#!/usr/bin/env bash
# startup-in-container.sh - se ejecuta DENTRO de un contenedor ubuntu:24.04 como root.
# Valida vm-startup.sh: usuarios, sudo, idempotencia, fallos aislados, checksum y manejo de la
# auth key (con gcloud/tailscale falsos). Usa red real para apt/GitHub/NodeSource/claude.ai.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT=/opt/orca-gcp/scripts/vm-startup.sh
export STARTUP_LOG=/var/log/orca-startup.log
export ORCA_CLIENT=cliente-a
export ORCA_VERSION="${ORCA_VERSION:-1.4.255}"
export ORCA_SKIP_GCP=1 ORCA_SKIP_TAILSCALE=1 ORCA_SKIP_SERVICE=1
[[ "${ORCA_TEST_SKIP_CLAUDE:-0}" == "1" ]] && export ORCA_SKIP_CLAUDE=1
export DEBIAN_FRONTEND=noninteractive

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
has_line() { grep -qE "$1" "$STARTUP_LOG"; }

echo "== 1. Primera ejecución =="
bash "$SCRIPT" >/tmp/run1.out 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "vm-startup.sh termina con 0" || { fail "vm-startup.sh terminó con $rc" "$(tail -25 /tmp/run1.out)"; }
for step in base-packages users linger node-lts gh tailscale-install "orca-install-${ORCA_VERSION}" "orca-service-6768" "claude-code"; do
  if [[ "$step" == claude-code && "${ORCA_SKIP_CLAUDE:-0}" == 1 ]]; then continue; fi
  has_line " (OK|SKIP) ${step}" && ok "log: paso ${step} marcado" || fail "log: falta marca de ${step}" "$(cat "$STARTUP_LOG")"
done
has_line " OK startup$" && ok "log: startup completo" || fail "log: sin OK startup"

echo "== 2. Usuarios y sudo =="
id orca >/dev/null 2>&1 && ok "usuario orca existe" || fail "usuario orca no existe"
id orca-admin >/dev/null 2>&1 && ok "usuario orca-admin existe" || fail "usuario orca-admin no existe"
[[ -d /home/orca/projects && "$(stat -c %U /home/orca/projects)" == orca ]] && ok "~orca/projects creado y de orca" || fail "~orca/projects"
if id -nG orca | tr ' ' '\n' | grep -qxE 'sudo|adm|admin|wheel|google-sudoers|docker|lxd'; then fail "orca pertenece a un grupo privilegiado: $(id -nG orca)"; else ok "orca sin grupos privilegiados ($(id -nG orca))"; fi
runuser -u orca -- sudo -n true >/tmp/sudo-orca.out 2>&1 && fail "orca PUDO ejecutar sudo" "$(cat /tmp/sudo-orca.out)" || ok "orca no puede hacer sudo (sudo -n true falla)"
runuser -u orca -- sudo -n id >/dev/null 2>&1 && fail "orca pudo 'sudo id'" || ok "orca no puede 'sudo id'"
sudo -l -U orca 2>&1 | grep -qE 'NOPASSWD: ALL|\(ALL(:ALL)?\) ALL$' && fail "sudo -l -U orca lista permisos" "$(sudo -l -U orca 2>&1)" || ok "sudo -l -U orca sin permisos ($(sudo -l -U orca 2>&1 | tail -1 | sed 's/^ *//'))"
# Simula al guest agent de GCE: si añadiera orca a google-sudoers con NOPASSWD, el archivo zz-orca-nosudo debe anularlo.
groupadd -f google-sudoers
printf '%%google-sudoers ALL=(ALL:ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/google-sudoers; chmod 440 /etc/sudoers.d/google-sudoers
usermod -aG google-sudoers orca
runuser -u orca -- sudo -n true >/dev/null 2>&1 && fail "orca hizo sudo vía google-sudoers (el override zz-orca-nosudo no funciona)" || ok "aun en google-sudoers, orca no puede sudo (override zz-orca-nosudo)"
gpasswd -d orca google-sudoers >/dev/null; rm -f /etc/sudoers.d/google-sudoers; groupdel google-sudoers 2>/dev/null
sudo -l -U orca-admin 2>&1 | grep -q 'NOPASSWD: ALL' && ok "orca-admin tiene sudo" || fail "orca-admin sin sudo" "$(sudo -l -U orca-admin 2>&1)"
[[ "$(passwd -S orca | awk '{print $2}')" == L ]] && ok "orca con contraseña bloqueada" || fail "orca sin contraseña bloqueada"
[[ "$(passwd -S orca-admin | awk '{print $2}')" == L ]] && ok "orca-admin con contraseña bloqueada" || fail "orca-admin sin contraseña bloqueada"
visudo -c >/dev/null 2>&1 && ok "sudoers válido (visudo -c)" || fail "sudoers inválido"

echo "== 3. Herramientas instaladas =="
for c in git gh curl jq make gcc node npm tailscale orca-ide; do
  command -v "$c" >/dev/null 2>&1 && ok "$c: $("$c" --version 2>/dev/null | head -1)" || fail "$c no está instalado"
done
[[ "$(dpkg -s orca-ide 2>/dev/null | awk '/^Version:/ {print $2}')" == "$ORCA_VERSION"* ]] && ok "orca-ide instalado en la versión fijada ${ORCA_VERSION}" || fail "versión de orca-ide" "$(dpkg -s orca-ide 2>&1 | head -5)"
apt-mark showhold | grep -qx orca-ide && ok "orca-ide retenido (apt-mark hold): sin auto-update" || fail "orca-ide sin hold" "$(apt-mark showhold)"
if [[ "${ORCA_SKIP_CLAUDE:-0}" != 1 ]]; then
  [[ -x /home/orca/.local/bin/claude ]] && ok "Claude Code instalado para orca: $(runuser -u orca -- /home/orca/.local/bin/claude --version 2>&1 | head -1)" || fail "Claude Code no instalado para orca"
  [[ "$(stat -c %U /home/orca/.local/bin/claude 2>/dev/null)" == orca ]] && ok "Claude Code pertenece a orca (no a root)" || fail "dueño de claude"
fi
grep -q "sha512 verificado" /tmp/run1.out && ok "checksum sha512 verificado contra latest-linux.yml" || fail "no se verificó el checksum" "$(grep -i sha512 /tmp/run1.out)"

unit_out="$(runuser -u orca -- orca-ide serve service install --port 6768 --dry-run 2>&1)"
grep -q -- '--supervise' <<<"$unit_out" && grep -q -- '6768' <<<"$unit_out" && ok "orca-ide serve service install --port 6768 --dry-run genera una unidad con --supervise y el puerto" || fail "dry-run del servicio" "$unit_out"
echo "       (unidad generada, informativo):"; printf '%s\n' "$unit_out" | sed 's/^/       | /'
grep -q 'orca-serve.service' <<<"$unit_out" && ok "la unidad se llamará orca-serve.service" || fail "nombre de unidad distinto de orca-serve.service"

echo "== 4. Idempotencia (segunda ejecución) =="
snap() { { md5sum /etc/passwd /etc/group /etc/shadow /etc/sudoers.d/* ; dpkg -l | md5sum; find /home/orca -printf '%p %s %u %m\n' | sort | md5sum; } 2>/dev/null; }
before="$(snap)"; ok_lines_before="$(grep -c ' OK ' "$STARTUP_LOG")"
bash "$SCRIPT" >/tmp/run2.out 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "segunda ejecución termina con 0" || fail "segunda ejecución rc=$rc" "$(tail -20 /tmp/run2.out)"
after="$(snap)"
[[ "$before" == "$after" ]] && ok "sin cambios en passwd/group/shadow/sudoers/paquetes/home" || fail "la segunda ejecución cambió el sistema" "$(diff <(echo "$before") <(echo "$after"))"
# En la 2ª ejecución no debe haber START de pasos de instalación; solo SKIP.
second="$(awk '/ START startup$/ {n++} n==2' "$STARTUP_LOG")"
if grep -qE ' START (base-packages|users|node-lts|gh|tailscale-install|orca-install|claude-code)' <<<"$second"; then fail "pasos reejecutados en la 2ª vuelta" "$second"; else ok "la 2ª ejecución salta todos los pasos ya hechos"; fi
[[ "$(grep -c ' SKIP ' <<<"$second")" -ge 6 ]] && ok "la 2ª ejecución registra SKIP por paso ($(grep -c ' SKIP ' <<<"$second") SKIP)" || fail "pocos SKIP" "$second"
[[ "$(grep -c ' OK ' "$STARTUP_LOG")" -eq $((ok_lines_before + 1)) ]] && ok "solo se añadió el OK final de startup" || fail "OK duplicados" "$(cat "$STARTUP_LOG")"

echo "== 5. Fallo aislado (versión de Orca inexistente) =="
export STARTUP_LOG=/tmp/orca-startup-fail.log
ORCA_VERSION=0.0.1 bash "$SCRIPT" >/tmp/run3.out 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "versión inexistente: termina con error ($rc)" || fail "debió fallar con ORCA_VERSION=0.0.1"
grep -qE ' FAIL orca-install-0.0.1' "$STARTUP_LOG" && ok "el log marca FAIL en orca-install-0.0.1" || fail "sin FAIL en el log" "$(cat "$STARTUP_LOG")"
if [[ "${ORCA_SKIP_CLAUDE:-0}" != 1 ]]; then grep -qE ' (OK|SKIP) claude-code' "$STARTUP_LOG" && ok "los pasos siguientes siguen corriendo tras un fallo" || fail "se detuvo tras el fallo"; fi
for bad in "Cliente" ""; do
  ORCA_CLIENT="$bad" bash "$SCRIPT" >/dev/null 2>&1 && fail "client inválido '$bad' aceptado" || ok "client inválido '$bad' rechazado"
done
export STARTUP_LOG=/var/log/orca-startup.log

echo "== 6. Checksum: descarga corrupta =="
mkdir -p /tmp/fakebin
REAL_CURL="$(command -v curl)"
cat >/tmp/fakebin/curl <<EOS
#!/usr/bin/env bash
# Sirve un .deb corrupto; el resto pasa al curl real.
out=""; args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do [[ "\${args[i]}" == -o ]] && out="\${args[i+1]}"; done
if [[ "\$*" == *.deb* ]]; then echo "contenido corrupto" >"\$out"; exit 0; fi
exec $REAL_CURL "\$@"
EOS
chmod +x /tmp/fakebin/curl
out="$(PATH=/tmp/fakebin:$PATH bash -c 'source '"$SCRIPT"'; step_orca_install' 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no coincide" <<<"$out" && ok "sha512 incorrecto: aborta sin instalar" || fail "checksum corrupto no detectado" "$out"
# latest-linux.yml no descargable: NO se instala sin verificar (falla cerrada)
cat >/tmp/fakebin/curl <<EOS
#!/usr/bin/env bash
if [[ "\$*" == *latest-linux.yml* ]]; then exit 22; fi
exec $REAL_CURL "\$@"
EOS
out="$(PATH=/tmp/fakebin:$PATH bash -c 'source '"$SCRIPT"'; step_orca_install' 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q "no se instala sin verificar" <<<"$out" && ok "sin latest-linux.yml: falla cerrada (no instala sin verificar)" || fail "checksum falla abierta" "$out"
# parseo de latest-linux.yml
printf 'hola\n' >/tmp/f.bin; exp="$(openssl dgst -sha512 -binary /tmp/f.bin | base64 -w0)"
printf 'version: 1\nfiles:\n  - url: otro.deb\n    sha512: AAAA\n  - url: f.bin\n    sha512: %s\n    size: 5\n' "$exp" >/tmp/l.yml
got="$(bash -c 'source '"$SCRIPT"'; published_sha512 /tmp/l.yml f.bin')"
[[ "$got" == "$exp" ]] && ok "published_sha512 extrae el hash del archivo correcto" || fail "published_sha512" "got=$got"

echo "== 7. Auth key: nunca a disco, log ni argv (gcloud/tailscale falsos) =="
FAKE_KEY="tskey-auth""-FAKEFAKEFAKE0123456789"   # falsa; partida para no parecer un secreto real
mkdir -p /tmp/fk; rm -f /tmp/fk/*
cat >/tmp/fk/gcloud <<EOS
#!/usr/bin/env bash
if [[ "\$*" == *"secrets versions access latest --secret=tailscale-authkey-cliente-a"* ]]; then
  [[ -f /tmp/fk/no-secret ]] && { echo "NOT_FOUND" >&2; exit 1; }
  printf '%s' "$FAKE_KEY"; exit 0
fi
exit 0
EOS
cat >/tmp/fk/tailscale <<'EOS'
#!/usr/bin/env bash
# Falso: registra argv y lo leído de --auth-key=file:... (solo longitud + coincidencia), nunca el valor.
case "$1" in
  status) if [[ -f /tmp/fk/up ]]; then echo '{"BackendState":"Running"}'; else echo '{"BackendState":"NeedsLogin"}'; fi ;;
  up)
    echo "$*" >/tmp/fk/argv
    for a in "$@"; do case "$a" in --auth-key=file:*) f="${a#--auth-key=file:}"; read -r k <"$f"; [[ "$k" == *FAKEFAKEFAKE0123456789 ]] && echo match >/tmp/fk/read; esac; done
    touch /tmp/fk/up ;;
esac
EOS
chmod +x /tmp/fk/gcloud /tmp/fk/tailscale
export STARTUP_LOG=/tmp/orca-startup-ts.log; rm -f "$STARTUP_LOG"
PATH=/tmp/fk:$PATH bash -c 'source '"$SCRIPT"'; CLIENT=cliente-a; run_step tailscale-up step_tailscale_up tailscale_is_up' >/tmp/ts.out 2>&1; rc=$?
[[ $rc -eq 0 && -f /tmp/fk/up ]] && grep -q ' OK tailscale-up' "$STARTUP_LOG" && ok "tailscale-up: lee el secreto y ejecuta 'tailscale up'" || fail "tailscale-up" "$(cat /tmp/ts.out; cat "$STARTUP_LOG")"
[[ "$(cat /tmp/fk/read 2>/dev/null)" == match ]] && ok "tailscale recibió la key íntegra por el descriptor (file:/dev/fd/3)" || fail "tailscale no pudo leer la key por file:"
grep -q -- '--hostname=orca-cliente-a' /tmp/fk/argv && grep -q -- '--advertise-tags=tag:orca-cliente-a' /tmp/fk/argv && ok "hostname y tag correctos en 'tailscale up'" || fail "argumentos de tailscale up" "$(cat /tmp/fk/argv)"
grep -q "FAKEFAKE" /tmp/fk/argv && fail "la key aparece en el argv de tailscale up" || ok "la key NO aparece en argv"
grep -rq "FAKEFAKE" /var/log "$STARTUP_LOG" /tmp/ts.out 2>/dev/null && fail "la key aparece en logs/salida" || ok "la key NO aparece en el log ni en la salida"
leak="$(grep -rIl "FAKEFAKE" /tmp /var /root /home /etc 2>/dev/null | grep -v '^/tmp/fk/\(gcloud\|tailscale\)$' | grep -v '^/tmp/startup-in-container' | head)"
[[ -z "$leak" ]] && ok "la key NO está en ningún archivo (barrido de /tmp /var /root /home /etc)" || fail "la key quedó en disco" "$leak"
# idempotencia: ya está up -> SKIP sin llamar al secreto
rm -f /tmp/fk/argv; PATH=/tmp/fk:$PATH bash -c 'source '"$SCRIPT"'; CLIENT=cliente-a; run_step tailscale-up step_tailscale_up tailscale_is_up' >/dev/null 2>&1
[[ ! -f /tmp/fk/argv ]] && grep -q ' SKIP tailscale-up' "$STARTUP_LOG" && ok "con Tailscale ya conectado: SKIP, no vuelve a ejecutar 'tailscale up'" || fail "tailscale-up no es idempotente"
# secreto sin versión: falla con instrucciones, sin colgarse
rm -f /tmp/fk/up; touch /tmp/fk/no-secret; : >"$STARTUP_LOG"
out="$(ORCA_TS_WAIT_SECS=0 PATH=/tmp/fk:$PATH bash -c 'source '"$SCRIPT"'; CLIENT=cliente-a; run_step tailscale-up step_tailscale_up tailscale_is_up' 2>&1)"
grep -q ' FAIL tailscale-up' "$STARTUP_LOG" && grep -q 'secrets versions add' <<<"$out" && ok "sin valor en el secreto: FAIL con instrucciones (no se cuelga)" || fail "manejo de secreto vacío" "$out"
export STARTUP_LOG=/var/log/orca-startup.log

echo "== 7b. Cambio de versión con el paquete en hold =="
OLD_VER=1.4.254
ORCA_VERSION=$OLD_VER bash "$SCRIPT" >/tmp/run4.out 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "ORCA_VERSION=$OLD_VER sobre una instalación en hold: termina con 0" || fail "cambio de versión rc=$rc" "$(grep -iE 'held|error|E:' /tmp/run4.out | head)"
[[ "$(dpkg -s orca-ide 2>/dev/null | awk '/^Version:/ {print $2}')" == "$OLD_VER"* ]] && ok "orca-ide quedó en $OLD_VER" || fail "versión tras el cambio" "$(dpkg -s orca-ide | head -4)"
apt-mark showhold | grep -qx orca-ide && ok "el paquete vuelve a quedar en hold" || fail "sin hold tras el cambio de versión"

echo "== 8. Experimento: ¿acepta el tailscale real '--auth-key=file:/dev/fd/3'? (key falsa) =="
if command -v tailscaled >/dev/null; then
  ( tailscaled --tun=userspace-networking --state=mem: --socket=/tmp/ts.sock >/tmp/tsd.log 2>&1 & )
  sleep 4
  exp_out="$(timeout 40 tailscale --socket=/tmp/ts.sock up --auth-key=file:/dev/fd/3 --hostname=orca-test --advertise-tags=tag:orca-test 3< <(printf '%s' "$FAKE_KEY") 2>&1)"; exp_rc=$?
  echo "  rc=$exp_rc salida: $(printf '%s' "$exp_out" | tr '\n' ' ' | head -c 300)"
  if grep -qiE 'no such file|cannot open|failed to read|file:' <<<"$exp_out" && ! grep -qiE 'invalid key|auth key|key.*(not valid|invalid|expired)' <<<"$exp_out"; then fail "tailscale no pudo leer file:/dev/fd/3"; else ok "el mensaje de tailscale no indica fallo al leer el archivo (el rechazo, si hay, viene del servidor)"; fi
  pkill tailscaled 2>/dev/null
else
  echo "  (tailscaled no instalado; experimento omitido)"
fi

echo
echo "Resultado contenedor: ${PASS} ok, ${FAIL} fallos"
[[ $FAIL -eq 0 ]]
