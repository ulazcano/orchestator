# Guía para el equipo (macOS): conectarse al servidor remoto de Orca `orca-cliente-a`

Versión de esta guía: 2026-11-10 · Servidor: `orca-cliente-a` (VM de GCP, Orca **1.4.251**, Linux) · Acceso: solo por Tailscale.

Esta guía parte de cero: un Mac sin Orca ni Tailscale. Al terminar vas a trabajar con Orca en tu Mac, pero los repos, los worktrees y los agentes (Claude Code) corren en la VM, con las credenciales que ya están allí. No necesitas cuenta de Google Cloud ni acceso SSH.

> Si eres el **dueño del servidor**, antes de entregar esta guía haz la sección **0** del final ("Para el dueño").

---

## Resumen de lo que vas a hacer

| Paso | Qué | Tiempo |
|---|---|---|
| 1 | Aceptar la invitación a Tailscale e instalarlo | 5 min |
| 2 | Comprobar que llegas a la VM por Tailscale | 1 min |
| 3 | Instalar Orca **1.4.251** (misma versión que el servidor) | 5 min |
| 4 | Agregar el servidor con el link de pareo que te manda el dueño | 2 min |
| 5 | Poner el servidor como *Active Server* y abrir un proyecto | 2 min |

Requisitos: macOS 13.4 o superior, cuenta de correo de la empresa, y el **link de pareo** que te enviará el dueño (es personal y de un solo uso: no lo compartas).

---

## 1. Tailscale

Tailscale es la red privada por la que tu Mac llega a la VM. Sin Tailscale no hay conexión: la VM no tiene ningún puerto abierto a internet.

1. Revisa tu correo: tendrás una invitación de Tailscale a la red (tailnet) de la empresa. Ábrela y acepta con tu cuenta de la empresa (botón **Sign in with Google**, o el proveedor que use tu organización).
2. Descarga Tailscale para macOS desde <https://tailscale.com/download/mac> (versión de la App Store o la "Standalone"; cualquiera sirve).
3. Instálalo, ábrelo y pulsa **Log in**. Inicia sesión con **la misma cuenta** con la que aceptaste la invitación.
4. En la barra de menú verás el icono de Tailscale. Comprueba que está **Connected** y que muestra tu cuenta.
5. Si tu organización exige aprobar dispositivos, el dueño verá tu Mac en la consola de Tailscale y lo aprobará. Hasta entonces no verás la VM.

Verificación: abre **Terminal** y ejecuta

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
```

Debe aparecer una línea con `orca-cliente-a`. Si no está, revisa que tu sesión de Tailscale sea con la cuenta de la empresa y avisa al dueño (puede faltar tu usuario en la ACL).

## 2. Comprobar que llegas a la VM

En Terminal:

```bash
nc -vz 100.80.185.107 6768
```

Esperado: `Connection to 100.80.185.107 port 6768 [tcp/*] succeeded!`.
Si dice `Operation timed out` o `Connection refused`:

- Tailscale no está conectado, o estás con otra cuenta → paso 1.
- La VM está apagada: se enciende sola de **08:00 a 21:00 (hora de Chile), lunes a viernes**. Fuera de ese horario pide al dueño que la encienda.
- Tu usuario no está en la ACL → avisa al dueño.

## 3. Instalar Orca 1.4.251

El servidor corre Orca **1.4.251**. Instala exactamente esa versión para evitar el error "incompatible protocol version".

1. Averigua tu chip: menú Apple → **Acerca de este Mac**. "Apple M1/M2/M3/M4" = Apple Silicon; "Intel" = Intel.
2. Descarga el instalador de esa versión (no el "latest"):
   - Apple Silicon: <https://github.com/stablyai/orca/releases/download/v1.4.251/orca-macos-arm64.dmg>
   - Intel: <https://github.com/stablyai/orca/releases/download/v1.4.251/orca-macos-x64.dmg>
3. (Recomendado) Verifica la descarga en Terminal:

   ```bash
   shasum -a 256 ~/Downloads/orca-macos-arm64.dmg   # o orca-macos-x64.dmg
   ```

   Debe coincidir con:
   - `orca-macos-arm64.dmg` → `2588fb3eea34eb0d328b9a5cd3be5ab5b36aafb02622d01308e2cb3535d8e0fe`
   - `orca-macos-x64.dmg` → `6d9b6a0ce76a11887cec53183cdf66300f51d41a58a52d5cca279a2d7fc50d65`
4. Abre el `.dmg` y arrastra **Orca** a **Applications**. Expulsa el disco.
5. Abre Orca desde Applications. Si macOS pregunta si confías en una app descargada de internet, pulsa **Abrir**.
6. Comprueba la versión: menú **Orca → About Orca** debe decir **1.4.251**.
7. Si en el primer arranque Orca te pide configurar agentes o iniciar sesión en Claude en tu Mac, puedes **omitirlo**: los agentes corren en el servidor con sus propias cuentas. Si te pregunta por una carpeta de proyectos local, acepta la que propone; no la usarás.

Sobre las actualizaciones: Orca se actualiza solo al canal estable. Si un día el servidor aparece como **incompatible**, no intentes arreglarlo tú: avisa al dueño, que actualiza el servidor a la versión nueva (ver "Política de versiones" más abajo).

## 4. Agregar el servidor remoto

Pide al dueño tu **link de pareo**. Lo recibirás por un canal cifrado (gestor de contraseñas compartido o mensaje directo). Es personal: da acceso directo al servidor, caduca al usarse y el dueño puede revocarlo.

1. En Orca abre **Settings** (⌘,) → **Remote Orca Servers**.
2. Pulsa **Add server**.
3. Nombre: `orca-cliente-a`. Pega el link de pareo completo. Pulsa **Add Server**.
4. La fila debe pasar a **Connected** en pocos segundos (verás `Linux · orca-cliente-a... · 100.80.185.107:6768 · v1.4.251`). Si queda **Disconnected**, pulsa **Connect**.
5. Avisa al dueño que ya estás conectado, para que cierre el modo de pareo del servidor.

Si el link no funciona: cada link sirve una sola vez y el dueño lo genera en el momento, así que pídele uno nuevo mientras estás delante de Orca.

## 5. Trabajar en el servidor

1. En **Settings → Remote Orca Servers**, en **New projects open on** elige `orca-cliente-a` (en versiones anteriores está en **Advanced → Active Server**). Así los proyectos y terminales nuevos se crean en la VM y no en tu Mac.
2. Para abrir un repo que ya está en la VM: **Add project** (o **Open project**) y busca la ruta en el servidor, por ejemplo `/home/orca/projects/<repo>`. Verás las rutas del servidor, no las de tu Mac.
3. Para crear un repo nuevo: **Create a new project**, nombre, y la ruta que proponga bajo `/home/orca/...`.
4. Crea un worktree y lanza un agente como siempre. El agente corre en la VM: puedes cerrar la tapa del Mac y al volver sigue donde iba.
5. Las terminales que abras desde Orca también están en la VM (usuario `orca`, sin permisos de administrador).

Ten en cuenta:

- **Las credenciales son del servidor, no tuyas.** Los commits salen con la identidad de git configurada en la VM y los agentes usan la cuenta de Claude del servidor. Si necesitas tu propia identidad en los commits, pídeselo al dueño.
- **Horario.** La VM se apaga a las 21:00 y se enciende a las 08:00 (hora de Chile, lunes a viernes). Un agente en curso a las 21:00 se corta.
- **Un solo servidor para el equipo.** Todos ven los mismos proyectos y worktrees; usa nombres de rama con tu usuario para no pisarte con otros.

## Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| El servidor no aparece en `tailscale status` | No estás en el tailnet de la empresa, o no estás en la ACL | Revisa la cuenta de Tailscale; avisa al dueño |
| `nc` da timeout | VM apagada o sin ACL | Horario; dueño |
| **Disconnected** tras estar conectado | Tailscale se desconectó o la VM se reinició | Comprueba Tailscale; pulsa **Connect** |
| "incompatible protocol version" | Tu Orca se actualizó y el servidor no | Avisa al dueño; no intentes bajar de versión |
| El link de pareo no sirve | Ya se usó, o el dueño generó otro después | Pide un link nuevo |
| El agente pide iniciar sesión | Expiró la sesión de Claude en el servidor | Dueño: `orca-ide account add --agent claude` en la VM |

## Política de versiones (léelo una vez)

- El servidor está fijado en **1.4.251** y no se actualiza solo.
- Orca de escritorio **sí** se actualiza solo y no hay opción documentada para desactivarlo. Hoy ambos lados toleran versiones cercanas (el dueño usa 1.4.251 y la última estable es 1.4.255).
- Cuando una actualización del escritorio deje de ser compatible, el dueño sube el servidor cambiando `ORCA_VERSION` en la VM y re-ejecutando el startup (unos 15 minutos de corte). Hasta entonces, no hace falta que nadie instale nada a mano.

---

## 0. Para el dueño: antes de entregar esta guía

Hazlo una vez por persona, en este orden.

1. **Invitar a Tailscale.** Consola <https://login.tailscale.com/admin/users> → **Invite users** → correo de la persona. Plan: el gratuito admite 3 usuarios; para más, Personal Plus o Starter.
2. **ACL.** En <https://login.tailscale.com/admin/acls/file> reemplaza la regla individual por un grupo y agrega ahí a cada persona:

   ```jsonc
   {
     "groups": {
       "group:orca-cliente-a": ["ulises@bove.cl", "persona1@bove.cl", "persona2@bove.cl"],
     },
     "tagOwners": {
       "tag:orca-cliente-a": ["autogroup:admin"],
     },
     "grants": [
       {"src": ["autogroup:member"], "dst": ["autogroup:member"], "ip": ["*"]},
       {"src": ["group:orca-cliente-a"], "dst": ["tag:orca-cliente-a"], "ip": ["tcp:6768"]},
     ],
     "ssh": [
       {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"]},
     ],
     "tests": [
       {"src": "persona1@bove.cl", "accept": ["tag:orca-cliente-a:6768"], "deny": ["tag:orca-cliente-a:22"]},
     ],
   }
   ```

   Si el tailnet exige aprobación de dispositivos: <https://login.tailscale.com/admin/machines> → aprobar el Mac nuevo.
3. **Generar el link de pareo** cuando la persona esté en el paso 4, desde tu Mac (con `gcloud` autenticado):

   ```bash
   orca-gcp/scripts/pair-client.sh cliente-a
   ```

   El script detiene el servicio, arranca el servidor de pareo, te imprime el link **solo en tu terminal**, espera a que pulses Enter cuando la persona vea **Connected**, y restaura el servicio. Durante ese minuto nadie más puede usar el servidor. Un link = una persona; si generas otro, el anterior sin usar deja de valer. Envíalo por un canal cifrado y bórralo después.
4. **Revocar** a alguien: en la VM, desde cualquier Orca pareado, **Settings → Remote Orca Servers → Shared Server Access** → papelera junto a su grant. Y quítalo del grupo en la ACL.
5. **Identidad de git.** Hoy la VM firma commits como una sola identidad (`git config --global` del usuario `orca`). Si hace falta distinguir autores, la opción simple es que cada persona use su propio nombre en el commit (`git commit --author=...`) o que acordéis un correo de equipo.
