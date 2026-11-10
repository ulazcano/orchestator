# Prueba crítica: comandos con autenticación que hoy corren en el Mac desde Conductor

Ítem final de la Fase 5 de la spec: identificar qué comandos con autenticación (CLIs con login, VPN, llavero,
MFA) se ejecutan hoy en el Mac del dueño desde Conductor y clasificarlos:

- **(a)** reemplazable por una credencial propia en la VM,
- **(b)** requiere login interactivo o MFA,
- **(c)** requiere algo que solo está en el Mac.

## Estado: BLOQUEADO por datos del dueño (no hay lecturas reales todavía)

Este workspace es una VM en la nube y **no tiene la herramienta `RunLocalCommand`** (se buscó con ToolSearch:
sin resultados), así que no puede leer el Mac. Todo lo que figura abajo como “candidato” es una **hipótesis por
tipo de herramienta**, no una observación. Lo que falta:

1. El dueño ejecuta el bloque de la sección 2 en su Mac (solo lectura, con tokens ocultos) y pega la salida en
   el chat. No se pega nada en el repo.
2. Con esa salida se rellena la tabla de la sección 4 con comandos reales y se confirman o corrigen las categorías.

> Regla: este repo es público. Nunca se commitean salidas crudas (correos, perfiles, nombres de clústeres,
> hosts). El resultado final aquí debe quedar anonimizado (“CLI X con login Y”).

## 1. Qué corre hoy en el Mac y de dónde sale

Hechos de la documentación de Conductor (https://conductor.build/docs/reference/shells,
https://conductor.build/docs/reference/scripts, https://conductor.build/docs/reference/files-to-copy):

| Origen | Dónde corre | Credenciales que hereda |
|--------|-------------|-------------------------|
| Agente (Claude Code/Codex) en workspace local | Mac, en un git worktree, con los permisos locales del usuario | Todo `$HOME`: `~/.config/gh`, `~/.aws`, `~/.kube`, llavero, `ssh-agent`, sesiones de CLIs |
| `scripts.setup`, `scripts.archive` y acciones `scripts.run.<id>` | Mac, `zsh` no interactivo **con el entorno del login shell capturado** | Variables exportadas en `~/.zshrc`/`.zprofile` (tokens en `export ...`), PATH, `AWS_PROFILE`, etc. |
| Files to copy (`.worktreeinclude`, `file_include_globs`, por defecto `.env*`) | Copia a cada workspace nuevo | Archivos `.env` con claves de API, DB y similares |
| Terminal del workspace | Mac, shell del usuario | Igual que el agente |
| Archivos de configuración | `~/.conductor/settings.toml`, `~/.conductor/settings.managed.toml`, `<repo>/.conductor/settings.toml` y `settings.local.toml`, `conductor.json` heredado | Muestran qué scripts y variables se ejecutan |

Consecuencia: la fuente de verdad de “qué comandos con auth corren” son (1) los scripts de Conductor de cada repo,
(2) el historial del shell y (3) el entorno heredado (`env`, `~/.zshrc`). Eso es lo que recoge la sección 2.

## 2. Bloque de recolección (el dueño lo pega en la terminal del Mac)

Solo lectura. No usa `security find-*` ni imprime tokens: oculta patrones de token, correos (deja el dominio) y
recorta el historial a los primeros 3 tokens de cada comando (para no mostrar argumentos con secretos). Cambia
`REPOS` por los repos de cliente que usas en Conductor.

```zsh
REPOS=(~/code/repo1 ~/code/repo2)   # <- ajusta: rutas de los repos en Conductor

redact() { perl -pe '
  s/(gh[pousr]_|github_pat_|sk-ant-|sk-|xox[abprs]-|AKIA|ASIA|ya29\.|eyJ|tskey-|glpat-|npm_)[A-Za-z0-9_.\-]+/<token>/g;
  s/((?:token|secret|passw(?:or)?d|api[_-]?key|authorization|bearer|auth)\s*[=:]\s*)\S+/$1<token>/gi;
  s/[\w.+\-]+@([\w\-]+\.[\w.\-]+)/<usuario>@$1/g;' ; }
sec() { printf '\n===== %s =====\n' "$1"; }
run() { sec "$*"; if command -v "$1" >/dev/null 2>&1; then "$@" 2>&1 | head -n 60 | redact; else echo "(no instalado)"; fi; }

run gcloud auth list
run gcloud config list
run gh auth status
run tailscale status
run aws configure list-profiles
run kubectl config get-contexts
sec "kubectl: comando de autenticación por usuario (exec plugins)"
command -v kubectl >/dev/null && kubectl config view -o jsonpath='{range .users[*]}{.name}{"\t"}{.user.exec.command}{"\n"}{end}' 2>&1 | redact
run docker context ls
sec "docker: credsStore/credHelpers (sin auths)"
[ -f ~/.docker/config.json ] && (command -v jq >/dev/null && jq '{credsStore, credHelpers, registries: (.auths // {} | keys)}' ~/.docker/config.json | redact || echo "(instala jq)")
run security list-keychains
run op account list
sec "ssh-agent (solo huellas) y ~/.ssh (solo nombres)"; ssh-add -l 2>&1 | awk '{print $1,$2,$4}'; ls ~/.ssh 2>&1
sec "ssh config: hosts, ProxyJump, ForwardAgent, IdentityAgent"
grep -Ei '^\s*(Host |ProxyJump|ForwardAgent|IdentityAgent|IdentityFile|CertificateFile|PKCS11)' ~/.ssh/config 2>/dev/null | redact
sec "VPN configuradas"; scutil --nc list 2>&1 | head -n 20 | redact
sec "sudo con Touch ID"; grep -l pam_tid /etc/pam.d/sudo* 2>/dev/null
sec "git credential helper"; git config --global --get-regexp '^(credential|url\.)' 2>/dev/null | redact
sec "npm/pip registries privados (solo URLs)"; npm config get registry 2>/dev/null | redact; grep -hE '^(index-url|extra-index-url)' ~/.pip/pip.conf ~/.config/pip/pip.conf 2>/dev/null | redact
sec "variables de entorno exportadas (SOLO NOMBRES) con pinta de credencial"
env | cut -d= -f1 | grep -Ei 'token|secret|passw|key|auth|^AWS_|^GH_|^GITHUB_|^GOOGLE_|^CLOUDSDK|^KUBE|^OP_|^NPM_|^ANTHROPIC|^OPENAI|^SSH_AUTH_SOCK' | sort

sec "historial del shell filtrado (comando + 2 primeros argumentos, con conteo)"
for h in ~/.zsh_history ~/.bash_history; do [ -f "$h" ] && cat "$h"; done \
 | sed -E 's/^: [0-9]+:[0-9]+;//' \
 | grep -Ei '(login|auth|sso|vpn|1password|(^|[ ;|])op( |$)|ssh )' \
 | awk '{print $1, $2, $3}' | redact | sort | uniq -c | sort -rn | head -n 60

sec "Conductor: ~/.conductor (solo nombres) y settings.toml de usuario"
ls -la ~/.conductor 2>&1 | head -n 30
for f in ~/.conductor/settings.toml ~/.conductor/settings.managed.toml; do [ -f "$f" ] && { echo "--- $f"; redact < "$f"; }; done
for r in "${REPOS[@]}"; do
  for f in .conductor/settings.toml .conductor/settings.local.toml conductor.json .worktreeinclude; do
    [ -f "$r/$f" ] && { sec "$r/$f"; redact < "$r/$f"; }
  done
  sec "$r: archivos .env* que Files to copy copiaría (SOLO NOMBRES)"; ls -1 "$r"/.env* 2>/dev/null
done
```

Si algún comando tarda o abre un prompt (p. ej. `op`, `tailscale`, `security`), cancélalo con Ctrl-C y anótalo:
un CLI que pide interacción para un simple listado es en sí mismo evidencia de categoría (b)/(c).

Alternativa si prefieres autorizar lectura remota: abrir una sesión en Conductor **local** (en el Mac) con permiso
explícito para estos comandos de lectura, y que ese agente rellene la sección 4. La regla de la spec se mantiene:
nunca imprimir valores de tokens.

## 3. Criterio de clasificación

| Pregunta | Sí → |
|----------|------|
| ¿La credencial se puede **emitir para la VM** de ese cliente (token fine-grained, cuenta de servicio, rol IAM de solo lectura, deploy key) y guardar con los permisos de `orca`? | **(a)** |
| ¿Hace falta una persona: login en navegador/SSO, código MFA, aprobación en el teléfono, CAPTCHA? ¿La sesión caduca en horas y no admite credencial de máquina? | **(b)** |
| ¿Depende de algo físico o del sistema operativo del Mac: Keychain de macOS, Touch ID/Secure Enclave, llave FIDO2/YubiKey, `ssh-agent` con llaves del Mac, cliente VPN corporativo, apps de escritorio (1Password), certificados de dispositivo? | **(c)** |

Un mismo comando puede caer en dos: se anota la categoría **más restrictiva** y se ve si se puede degradar
(p. ej. un (b) con SSO que ofrece “service principal” pasa a (a)).

## 4. Tabla de clasificación (candidatos por tipo de herramienta; a confirmar con la salida real)

La columna **Observado** se marca `sí/no/?` cuando el dueño pegue las salidas. Hasta entonces todo es hipótesis.

| Herramienta / comando | Categoría probable | Observado | Camino propuesto |
|-----------------------|--------------------|-----------|------------------|
| `gh` (clone/push/PR) con `gh auth login` | **(a)** | ? | A: token fine-grained limitado a repos del cliente, caducidad corta (spec Fase 3 ya lo prevé) |
| `git` por HTTPS con token en `~/.git-credentials` o `osxkeychain` | (a) si es token; **(c)** si el helper es el llavero | ? | A: `gh auth setup-git` en la VM; deploy key por repo |
| `git`/`ssh` con llave en `ssh-agent` del Mac | **(c)** (o (a) con deploy key) | ? | A: deploy key de solo lectura/escritura por repo del cliente. **No** reenviar el agente (ver riesgo) |
| `gcloud` con cuenta de usuario | **(b)** (login en navegador) → degradable a (a) | ? | A: cuenta de servicio del cliente con roles mínimos; la VM ya usa su SA por metadata server |
| `aws` perfiles estáticos (`~/.aws/credentials`) | **(a)** | ? | A: usuario IAM/rol dedicado del cliente, mínimo privilegio, rotación |
| `aws sso login` / perfiles SSO | **(b)** | ? | A con rol asumible de máquina si la cuenta lo permite; si no, login manual del dueño con `aws sso login --use-device-code` ejecutado en la VM (B-interactivo) |
| `kubectl` con token/cert en kubeconfig | **(a)** | ? | A: ServiceAccount/kubeconfig acotado a un namespace |
| `kubectl` con exec plugin (`gke-gcloud-auth-plugin`, `aws eks get-token`, `oidc-login`) | (a) si el plugin usa credencial de máquina; **(b)** si OIDC interactivo | ? | A con SA de la VM; si OIDC, ver (b) |
| `docker login` con `credsStore: osxkeychain` | **(c)** | ? | A: login en la VM con token de registro de solo lectura (`docker login --password-stdin` desde Secret Manager) |
| `npm`/`pip`/`cargo` con registro privado y token en `.npmrc` | **(a)** | ? | A: token de solo lectura del cliente en `~orca/.npmrc` |
| Archivos `.env*` copiados por Files to copy | **(a)** | ? | A: plantilla `.env.example` + valores de **desarrollo del cliente** cargados en la VM; nunca copiar el `.env` del Mac |
| `op` (1Password CLI) / secretos en el gestor | **(c)** y (b) (biometría/app) | ? | A: service account de 1Password con bóveda del cliente (token solo en la VM) o secretos en Secret Manager; si no, C |
| VPN corporativa del cliente (AnyConnect, WireGuard, GlobalProtect…) para llegar a DB/staging | **(c)** / (b) | ? | Ver caso VPN abajo |
| Acceso a recursos en la tailnet / Tailscale del Mac | (c) | ? | Cubierto por ACL con tag por cliente; la VM tiene su propia identidad Tailscale |
| `sudo` con Touch ID, `security` (Keychain), `open`/apps de escritorio | **(c)** | ? | No migrar: se ejecuta en el Mac fuera del agente |
| Claude Code / Codex (`orca-ide account add --agent claude|codex`) | **(b)** (login único interactivo) | ? | Login manual del dueño en la VM con la cuenta del cliente (spec Fase 3 paso 2); sin copiar `~/.claude` |

### Camino por caso

**(a) Credencial propia en la VM — camino A (preferido).**
Emitir una credencial *nueva, por cliente, de mínimo privilegio y con caducidad*, cargarla tú (el dueño) en la VM
o en Secret Manager; el agente solo la usa.
Riesgos: los agentes ejecutan comandos arbitrarios como `orca`, así que cualquier secreto legible por `orca`
puede exfiltrarse por inyección de prompts en un repo o dependencia. Mitigaciones: un cliente por VM (ya
decidido), tokens de solo lo necesario (repos concretos, solo lectura donde se pueda), caducidad corta y
rotación, sin credenciales de producción de escritura, nunca claves de la cuenta personal del dueño, y revisar
con `verify-client.sh` (CRED-01..04) que no haya llaves ni variables inesperadas. Prefiere credenciales emitidas
por el metadata server de GCP (sin archivo) cuando el servicio destino sea GCP.

**(b) Interactivo o MFA — camino A-interactivo / SSH worktrees.**
- *Una sola vez, en la VM:* el dueño entra por IAP (`gcloud compute ssh --tunnel-through-iap`) y hace el login
  en la sesión de `orca` (device code / `--no-launch-browser`); la sesión queda en la VM. Es el modelo de
  `orca-ide account add` y `gh auth login` de la spec. Riesgo: la sesión caduca; hay que repetir el login y cada
  caducidad interrumpe a un agente. Para tokens SSO de vida corta, acordar con el cliente una credencial de máquina.
- *SSH worktrees* (https://www.onorca.dev/docs/ssh): Orca puede crear el worktree en un host SSH y relayar
  passphrases y prompts *keyboard-interactive* (MFA) al usuario; la doc indica que las passphrases quedan en
  memoria durante la sesión de Orca y que FIDO2/Kerberos usan el OpenSSH del sistema. Es útil si el host con
  acceso ya existe (p. ej. un bastión del cliente). Riesgo: la doc dice que el host remoto debe tener ya
  “repo, tools y credenciales”, así que no resuelve credenciales por sí mismo; y **no documenta** reenvío de
  `ssh-agent`.
- Riesgo común: automatizar MFA (guardar el segundo factor en la VM) lo anula; no hacerlo.

**(c) Solo en el Mac — decidir caso a caso entre tres opciones:**
1. *No migrar el paso.* Se ejecuta a mano en el Mac, fuera del agente (p. ej. firmar con YubiKey, abrir apps).
   Sin riesgo nuevo; coste: fricción.
2. *Sustituir la dependencia* por una credencial de máquina (camino A): p. ej. el Keychain guarda un token de
   registro → emitir un token de solo lectura para la VM; llave en `ssh-agent` → deploy key. Es la opción preferida.
3. *Puente restringido por Tailscale (camino C), último recurso.* Un pequeño servicio en el Mac (o en un host
   dedicado) expuesto solo a `tag:orca-<cliente>` en un puerto fijo, que ejecuta **una lista cerrada** de
   comandos (no shell arbitrario), exige aprobación con Touch ID por solicitud, registra auditoría y devuelve
   salidas sin secretos. Riesgos: convierte al Mac en blanco alcanzable desde una VM donde corren agentes con
   ejecución arbitraria (movimiento lateral si hay inyección de prompts), el Mac debe estar encendido y
   despierto (contradice “sigue vivo con la laptop cerrada”), y rompe el principio “nada del Mac en la VM”.
   Si se hace: ACL Tailscale solo de la VM hacia ese puerto, allowlist estricta, rate limit, sin acceso a
   Keychain por API, y revisión por cliente. **No recomendado salvo necesidad demostrada.**

**Caso VPN del cliente.** Si hoy el agente alcanza DB/servicios internos por una VPN del Mac, la VM debe:
(i) unirse a esa red con su propia identidad (cliente VPN de máquina/WireGuard con un peer dedicado, credencial
en Secret Manager), o (ii) llegar por un bastión/SSH worktree que ya esté dentro. Si la VPN exige MFA
interactivo o un cliente de escritorio, es (b)/(c) y requiere acordar con el cliente un acceso de máquina.
Riesgo: dar a la VM acceso de red a la red del cliente amplía la superficie; limitar por IP/puerto y por
horario (la VM ya se apaga a las 21:00).

### Riesgos transversales

- **No usar** `ForwardAgent yes` hacia la VM ni copiar `~/.ssh`, `~/.config/gh`, `~/.claude`, `~/.aws`,
  `~/.kube`, `.env` del Mac: el agente de la VM ejecuta código arbitrario.
- **Mac y VM deben quedar con la misma versión de Orca**; la doc solo advierte de incompatibilidad de protocolo
  sin dar números de versión (ver incertidumbres en `verificacion.md`).
- **Scripts de Conductor del Mac:** al migrar un repo a Orca, los `setup`/`run` que usaban el entorno del login
  shell del Mac (variables exportadas) dejan de tener ese entorno en la VM. Hay que inventariar las variables
  que consumen y proveerlas como credenciales de la VM (categoría (a)) o eliminarlas.

## 5. Datos que faltan para cerrar esta prueba

1. Salida del bloque de la sección 2 (con tokens ocultos) pegada en el chat por el dueño, o permiso para que una
   sesión local de Conductor la recoja.
2. Lista de repos de cliente que usas en Conductor y cuáles tienen `scripts.setup`/`run` con autenticación.
3. Qué clientes exigen VPN/MFA/SSO (para saber si el piloto `cliente-a` cubre los casos (b) y (c) o solo (a)).
4. Confirmar si algún flujo depende de que el Mac esté encendido (puente, túnel, sesión de navegador).

Cuando existan, esta tabla pasa de “candidatos” a “observados” y se actualiza el ítem 9.1 de
[`verificacion.md`](./verificacion.md).
