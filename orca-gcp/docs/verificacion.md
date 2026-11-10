# Verificación de la Fase 5 — checklist de `orca-cliente-a`

Checklist de la spec (sección 4, Fase 5) con el comando exacto, el resultado esperado y una columna
**Resultado real** que se llena en la Parte B, con la salida literal y **sin secretos**.

- Automatizable: `orca-gcp/scripts/verify-client.sh cliente-a` (solo lectura; `--dry-run` para ver los comandos).
- Variables usadas abajo: `PROJECT_ID=bove-orca`, `ZONE=us-central1-a`, `VM=orca-cliente-a`.
- Este repo es público. Antes de pegar una salida, tapa IPs (públicas y 100.x), correos, nombres de cuenta
  y cualquier token. El script ya enmascara IPs y correos; revisa igual.
- Estado: `PENDIENTE` hasta que el dueño confirme que `orca-cliente-a` existe y pasó los pasos manuales.

> Última ejecución: _(sin ejecutar)_ · Versión de Orca en la VM: _(vacío)_ · Versión en el Mac: _(vacío)_

## Resumen

| ID | Ítem de la spec | Cómo | Esperado | Resultado real | Estado |
|----|-----------------|------|----------|----------------|--------|
| 1.1 | Sin reglas de ingreso públicas en `orca-vpc` | script `FW-01`, `FW-03` | solo `orca-allow-iap-ssh` | | PENDIENTE |
| 1.2 | La regla IAP es mínima | script `FW-02` | `35.235.240.0/20`, `tcp:22`, tag `orca` | | PENDIENTE |
| 1.3 | Escaneo externo a la IP efímera | script `SCAN-01` + manual | ningún puerto abierto | | PENDIENTE |
| 2.1 | `tailscale status` con tag en la VM | script `TSI-01` | `Running`, `orca-cliente-a`, `tag:orca-cliente-a` | | PENDIENTE |
| 2.2 | VM visible y alcanzable desde el Mac | script `TS-01` (si corre en el Mac) | `6768` responde por Tailscale | | PENDIENTE |
| 2.3 | ACL: dispositivo no autorizado no accede | manual | conexión rechazada/timeout | | PENDIENTE |
| 3.1 | `orca-ide serve service status` = running | script `SVC-01` | running | | PENDIENTE |
| 3.2 | Servicio habilitado + linger | script `SVC-02` | linger `yes`, unidad `enabled` | | PENDIENTE |
| 3.3 | Sobrevive a `sudo reboot` | manual + script antes/después | running; arranque (`SVC-03`) cambia | | PENDIENTE |
| 4.1 | Mac: servidor **Connected** | manual | `Connected` | | PENDIENTE |
| 4.2 | Mac: crear worktree en repo de prueba | manual | worktree visible en la VM | | PENDIENTE |
| 5.1 | Claude Code instalado para `orca` | script `AGT-01` | versión impresa | | PENDIENTE |
| 5.2 | Agente vivo con la laptop cerrada | manual | proceso sigue y avanza | | PENDIENTE |
| 6.1 | `sudo -n true` como `orca` falla | script `SUDO-01..03` | exit ≠ 0, sin grupos privilegiados | | PENDIENTE |
| 7.1 | Sin credenciales del Mac en la VM | script `CRED-01..04` + manual | solo cuentas del cliente | | PENDIENTE |
| 8.1 | Metadata sin secretos, SA mínima | script `META-*`, `IAM-*`, `LOG-01` | 3 claves; sin patrones | | PENDIENTE |
| 8.2 | Horario y snapshots adjuntos | script `POL-01..03` | 08:00/21:00 lun-vie; retención 7 d | | PENDIENTE |
| 9.1 | Prueba crítica (comandos con auth del Mac) | [`comandos-mac-auth.md`](./comandos-mac-auth.md) | clasificación (a)/(b)/(c) | | PENDIENTE |

Convención de Estado: `PASS`, `FAIL`, `PENDIENTE`, `N/A (motivo)`.

---

## 1. Firewall: nada expuesto a internet

### 1.1 Reglas de ingreso de la VPC

```bash
gcloud compute firewall-rules list --project bove-orca \
  --filter="network~/orca-vpc\$ AND direction=INGRESS AND disabled=false" \
  --format="table(name,sourceRanges.list(),allowed[].map().firewall_rule().list(),targetTags.list())"
# Cualquier regla pública en cualquier red del proyecto:
gcloud compute firewall-rules list --project bove-orca \
  --filter="direction=INGRESS AND disabled=false AND sourceRanges:0.0.0.0/0" \
  --format="table(name,network.basename())"
```

**Esperado:** la primera lista solo `orca-allow-iap-ssh`. La segunda, vacía o solo reglas de otras redes
(p. ej. `default`), que no afectan a `orca-vpc`; si existe `default-allow-ssh` público, avisar al dueño.

**Resultado real:**

```text

```

### 1.2 La regla IAP es mínima

```bash
gcloud compute firewall-rules describe orca-allow-iap-ssh --project bove-orca \
  --format="yaml(direction,sourceRanges,allowed,targetTags,disabled,network)"
```

**Esperado:** `direction: INGRESS`, `sourceRanges: [35.235.240.0/20]`, `allowed: tcp:22`,
`targetTags: [orca]`, red `orca-vpc`.

**Resultado real:**

```text

```

### 1.3 Escaneo externo a la IP efímera

Ejecutar **desde fuera de la VPC** (el Mac con una red normal, o un celular con datos, no desde una VM del
proyecto). La VM debe estar encendida.

```bash
IP=$(gcloud compute instances describe orca-cliente-a --zone us-central1-a --project bove-orca \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
for p in 22 80 443 6768; do nc -z -w 3 "$IP" "$p" && echo "ABIERTO $p" || echo "cerrado/filtrado $p"; done
nmap -Pn -T4 -p 1-1024,6768 --open "$IP"        # si nmap está instalado (brew install nmap)
```

**Esperado:** los cuatro `cerrado/filtrado`; `nmap` sin puertos abiertos (puede mostrar “All ports filtered”).
Nota: no se imprime la IP en este documento; tapar en la salida pegada.

**Resultado real:**

```text

```

---

## 2. Tailscale: tag y ACL

### 2.1 Estado en la VM, con tag

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
  --command 'sudo tailscale status --json | jq "{estado: .BackendState, host: .Self.HostName, tags: .Self.Tags}"'
```

**Esperado:** `{"estado":"Running","host":"orca-cliente-a","tags":["tag:orca-cliente-a"]}`.

**Resultado real:**

```text

```

### 2.2 Desde el Mac: visible y alcanzable

```bash
tailscale status | grep orca-cliente-a
tailscale ping -c 3 orca-cliente-a
nc -z -w 5 orca-cliente-a 6768 && echo "6768 responde por Tailscale"
```

**Esperado:** aparece la VM, hay respuesta de ping y el puerto responde.

**Resultado real:**

```text

```

### 2.3 Prueba de ACL desde un dispositivo no autorizado

Usar un dispositivo de la tailnet que **no** sea el Mac del dueño ni esté en la regla (otro nodo con otro tag,
un celular con otro usuario, o un nodo de prueba efímero que cree el dueño).

```bash
# En el dispositivo no autorizado:
tailscale status | grep orca-cliente-a || echo "no ve a orca-cliente-a"
tailscale ping -c 3 orca-cliente-a
nc -z -w 5 orca-cliente-a 6768 && echo "ACCESO (mal)" || echo "bloqueado (bien)"
```

Verificación estática equivalente en la política de la tailnet (Admin console → Access controls → `tests`),
sin necesitar un segundo dispositivo:

```jsonc
"tests": [
  {"src": "<usuario-o-tag-del-Mac>", "accept": ["tag:orca-cliente-a:6768"]},
  {"src": "tag:orca-otro-cliente",   "deny":   ["tag:orca-cliente-a:6768"]}
]
```

**Esperado:** el dispositivo no autorizado no ve la VM y el puerto no conecta; los `tests` de la política pasan.
(El dueño ejecuta esto en su admin console; no se escribe nada de la política en este repo.)

**Resultado real:**

```text

```

---

## 3. Servicio de Orca

### 3.1 y 3.2 Estado, habilitación y linger

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap --command '
  U=$(id -u orca)
  sudo -u orca -H env XDG_RUNTIME_DIR=/run/user/$U orca-ide serve service status
  sudo -u orca -H env XDG_RUNTIME_DIR=/run/user/$U systemctl --user list-unit-files --type=service | grep -i orca
  loginctl show-user orca -p Linger
  uptime -s'
```

**Esperado:** `status` indica running; la unidad figura `enabled`; `Linger=yes`.
Según la doc (https://www.onorca.dev/docs/remote-servers) en Linux el servicio se detiene al cerrar sesión
si no hay *lingering*. La doc **no documenta** `service start/stop`; solo `install`, `status`, `uninstall`.

**Resultado real:**

```text

```

### 3.3 Sobrevive a un reinicio

```bash
# 1) Antes: anotar la hora de arranque y el estado (comando de 3.1)
# 2) Reiniciar (admin con sudo):
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap --command 'sudo reboot'
# 3) Esperar ~2 min y repetir el comando de 3.1, o:
./orca-gcp/scripts/verify-client.sh cliente-a        # SVC-01, SVC-02 y SVC-03 (hora de arranque nueva)
tailscale status | grep orca-cliente-a                # la VM vuelve a la tailnet sola
```

**Esperado:** tras el reinicio `status` = running sin intervención, `uptime -s` posterior a la hora anterior y
la VM reaparece en Tailscale. (El `reboot` hace caer la sesión ssh: es normal.)

**Resultado real (antes / después):**

```text

```

---

## 4. Desde el Mac (manual)

### 4.1 Servidor Connected

Paso a paso (según https://www.onorca.dev/docs/remote-servers): en Orca del Mac,
**Settings → Remote Orca Servers**; si la fila dice **Disconnected**, pulsar **Connect**. El pareo previo
(`--pairing-address`) lo hizo el dueño en `pasos-manuales.md`.

```bash
# Evidencia complementaria desde la VM (el servicio no imprime el link de pareo):
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
  --command 'sudo ss -tnp state established "( sport = :6768 )" | wc -l'
```

**Esperado:** la fila muestra **Connected** (captura o texto de la UI, sin el link de pareo); la VM ve ≥ 1
conexión establecida al puerto 6768.

**Resultado real:**

```text

```

### 4.2 Crear un worktree en un repo de prueba

En Orca, abrir un proyecto del servidor remoto (repo de prueba del cliente en `~orca/projects`) y crear un
workspace/worktree nuevo desde la UI. La doc no describe el flujo de worktrees; se verifica el efecto en la VM:

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
  --command 'sudo -u orca -H git -C /home/orca/projects/<repo-de-prueba> worktree list'
```

**Esperado:** aparece el worktree nuevo, propiedad de `orca`. Un mismo worktree no debería existir en el Mac
(vive en el servidor).

**Resultado real:**

```text

```

---

## 5. Agente de Claude Code

### 5.1 Instalado y con cuenta del cliente

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
  --command 'sudo -u orca -H bash -lc "claude --version; orca-ide account list"'
```

**Esperado:** versión de Claude Code y la cuenta del **cliente** (revisar a mano que no sea una cuenta del dueño;
no pegar correos).

**Resultado real:**

```text

```

### 5.2 Sigue vivo con la laptop cerrada

1. En Orca (Mac, conectado a la VM) abrir una terminal de agente y lanzar `claude` con una tarea larga que deje
   evidencia periódica, p. ej. “cada minuto agrega la hora a `/home/orca/projects/prueba/heartbeat.txt` durante
   30 minutos”. Hacerlo dentro del horario 08:00-21:00 (si no, el apagado programado mata la prueba).
2. Anotar la hora y el PID:
   ```bash
   gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
     --command 'pgrep -u orca -af claude; date -u'
   ```
3. **Cerrar la laptop** (suspender) ≥ 10 min. Con la laptop cerrada, desde otro dispositivo o desde el mismo Mac
   al despertar, repetir el paso 2 y `tail -n 5 heartbeat.txt`.
4. Reabrir Orca: la sesión debe seguir ahí con el historial.

**Esperado:** mismo PID, `heartbeat.txt` con entradas **durante** el periodo con el Mac suspendido, y la sesión
recuperable al reconectar. Si el PID cambió o no hubo entradas, la sesión dependía del Mac: FAIL.
(La doc indica que `uninstall` deja vivo el daemon de terminal y sus sesiones, lo que sugiere que las sesiones
viven en el servidor; hay que confirmarlo con esta prueba.)

**Resultado real:**

```text

```

---

## 6. `orca` no puede usar sudo

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap --command '
  sudo -n -u orca -H sudo -n true; echo "exit=$?"
  id -nG orca
  sudo -n -l -U orca'
```

**Esperado:** `sudo: a password is required` (o similar) y `exit=1`; `id -nG` sin `sudo`, `wheel`, `admin`,
`google-sudoers`, `docker`, `lxd`; `sudo -l -U orca` dice “not allowed to run sudo”. También probarlo desde una
sesión de agente en Orca: `sudo -n true` debe fallar.

**Resultado real:**

```text

```

---

## 7. Sin credenciales del Mac en la VM

Se revisan **nombres**, nunca valores.

```bash
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap --command '
  H=/home/orca
  echo "--- gh:";      sudo -u orca -H gh auth status 2>&1 | sed -E "s/(Token: ).*/\1<oculto>/"
  echo "--- ~/.claude:"; sudo ls -la $H/.claude 2>&1 | head -20
  echo "--- ssh:";      sudo ls -la $H/.ssh 2>&1; sudo find $H/.ssh -type f -exec grep -lE "BEGIN [A-Z ]*PRIVATE KEY" {} + 2>/dev/null
  echo "--- otras rutas:"; for d in .aws .azure .kube .docker .config/gcloud .config/op .netrc .npmrc .pypirc; do sudo test -e $H/$d && echo "existe $d"; done
  echo "--- git:";      sudo -u orca -H git config --global --get-regexp "^user\." | sed -E "s/@.*/@<oculto>/"
  echo "--- env (solo nombres):"
  for p in $(pgrep -u orca -f "orca|claude|codex"); do sudo cat /proc/$p/environ | tr "\0" "\n" | cut -d= -f1; done | sort -u | grep -Ei "token|secret|passw|key|auth|^AWS_|^GH_|^GITHUB_|ANTHROPIC|OPENAI"
  echo "--- authorized_keys de orca:"; sudo wc -l $H/.ssh/authorized_keys 2>&1'
```

**Esperado:**
- `gh auth status`: cuenta del **cliente** con token fine-grained limitado a sus repos (revisar scopes en GitHub del
  cliente; no el usuario personal del dueño).
- `~/.claude`: sesión de la cuenta del cliente. Para confirmar que no es la del dueño, que el dueño compare el
  correo en `claude` → `/status` dentro de la VM (sin pegarlo aquí).
- Sin llaves SSH privadas; sin `authorized_keys` (o solo llaves del cliente); sin `.aws`, `.kube`, `.docker`,
  `gcloud`, `op`, `.netrc`, `.npmrc`; sin variables de entorno de credenciales.
- Comparación con el Mac (lo hace el dueño): `ls ~/.config/gh ~/.claude ~/.ssh` en el Mac **no** debe tener
  equivalentes copiados a la VM; huella de las llaves públicas del Mac: `ssh-add -l` (solo huellas) frente a
  cualquier llave en la VM (`ssh-keygen -lf`).
- Si la VM usa `ssh-agent forwarding` (`ForwardAgent yes` en `~/.ssh/config` del Mac), eso expondría llaves del
  Mac a la VM mientras dura la sesión: `grep -i ForwardAgent ~/.ssh/config` debe estar vacío o en `no`.

**Resultado real:**

```text

```

---

## 8. Metadata, cuenta de servicio, horario y snapshots

```bash
# 8.1 Metadata sin secretos (se muestran solo claves y longitud, nunca valores)
gcloud compute instances describe orca-cliente-a --zone us-central1-a --project bove-orca \
  --format="value(metadata.items[].key)"
gcloud compute instances describe orca-cliente-a --zone us-central1-a --project bove-orca \
  --format="value(metadata.items[].value)" | grep -Eic 'tskey-|ghp_|github_pat_|sk-ant-|PRIVATE KEY'
# Secreto: existencia e IAM, NUNCA `versions access`
gcloud secrets get-iam-policy tailscale-authkey-cliente-a --project bove-orca \
  --flatten="bindings[].members" --format="value(bindings.role,bindings.members)"
gcloud projects get-iam-policy bove-orca --flatten="bindings[].members" \
  --filter="bindings.members=serviceAccount:orca-vm-cliente-a@bove-orca.iam.gserviceaccount.com" \
  --format="value(bindings.role)"
# Log de arranque sin secretos
gcloud compute ssh orca-admin@orca-cliente-a --zone us-central1-a --project bove-orca --tunnel-through-iap \
  --command 'sudo grep -Eic "tskey-|ghp_|github_pat_|sk-ant-|pairing" /var/log/orca-startup.log; sudo tail -n 10 /var/log/orca-startup.log'

# 8.2 Horario y snapshots
gcloud compute resource-policies describe orca-horario-cliente-a --region us-central1 --project bove-orca \
  --format="yaml(instanceSchedulePolicy)"
gcloud compute resource-policies describe orca-snapshots-cliente-a --region us-central1 --project bove-orca \
  --format="yaml(snapshotSchedulePolicy)"
```

**Esperado:** claves `client`, `orca-version`, `startup-script` (nada más; un `enable-oslogin` se reporta como
WARN); conteo de patrones `0`; solo la SA del cliente es `secretAccessor` de su secreto y no tiene roles de
proyecto sobre Secret Manager; log sin patrones; horario `0 8 * * 1-5` / `0 21 * * 1-5` en `America/Santiago`;
snapshots diarios con retención 7 días.

**Resultado real:**

```text

```

---

## 9. Prueba crítica

Ver [`comandos-mac-auth.md`](./comandos-mac-auth.md): clasificación de los comandos con autenticación que hoy
corren en el Mac desde Conductor y camino propuesto por caso.

**Resultado real:** _(completado en ese documento)_

---

## Incertidumbres abiertas que afectan a este checklist

1. **Beta de Orca:** la doc no publica el formato exacto de `service status`, ni `service start/stop`, ni dónde
   escribe logs el servicio; el script usa coincidencias flexibles (`running|active`) que puede ser necesario
   ajustar tras ver la salida real.
2. **Puerto por defecto:** la doc no lo indica; se usa `6768` por la spec (`--port 6768`).
3. **Compatibilidad Mac–VM:** la doc solo dice “actualiza ambos si la fila reporta una versión de protocolo
   incompatible”. Hay que registrar la versión de ambos lados (arriba) y confirmar que la fila no muestre
   incompatibilidad. El `.deb` no publica checksum en la página de instalación.
4. **`gcloud compute ssh` por IAP** crea una llave local y la registra (OS Login o metadata `ssh-keys`). Si no se
   usa OS Login, aparecería `ssh-keys` en la metadata de la VM/proyecto y `META-01` lo marcaría como FAIL.
   TODO para quien posea la base GCP (workspace 0) y los scripts de creación (workspace 1): decidir
   `enable-oslogin=TRUE` a nivel de proyecto y dar al dueño `roles/iap.tunnelResourceAccessor` y
   `roles/compute.osAdminLogin`.
5. **Formato del link de pareo:** se buscan patrones genéricos (`pairing`, `orca://`) en logs; ajustar al formato real.
