# Guía para el equipo (Windows): conectarse al servidor remoto de Orca `orca-cliente-a`

Versión de esta guía: 2026-11-10 · Servidor: `orca-cliente-a` (VM de GCP, Orca **1.4.251**, Linux) · Acceso: solo por Tailscale.

Parte de cero: un PC con Windows sin Orca ni Tailscale. Al terminar trabajas con Orca en tu PC, pero los repos, worktrees y agentes corren en la VM con las credenciales que ya están allí. No necesitas cuenta de Google Cloud ni SSH. Windows funciona como **cliente** de Orca; lo único que no existe en Windows es correr tu propio servidor (y no lo necesitas).

> El **dueño del servidor** debe hacer antes la sección "Para el dueño" de la guía de macOS (`guia-equipo-mac.md`, sección 0): invitación a Tailscale, ACL y link de pareo. Es idéntica para Windows.

---

## Resumen

| Paso | Qué | Tiempo |
|---|---|---|
| 1 | Aceptar la invitación a Tailscale e instalarlo | 5 min |
| 2 | Comprobar que llegas a la VM | 1 min |
| 3 | Instalar Orca **1.4.251** | 5 min |
| 4 | Agregar el servidor con tu link de pareo | 2 min |
| 5 | Ponerlo como servidor activo y abrir un proyecto | 2 min |

Requisitos: Windows 10 u 11 de 64 bits, cuenta de correo de la empresa, y el **link de pareo** que te manda el dueño (personal, de un solo uso).

---

## 1. Tailscale

1. Acepta la invitación de Tailscale que llegó a tu correo, con tu cuenta de la empresa (**Sign in with Google** o el proveedor de tu organización).
2. Descarga Tailscale para Windows: <https://tailscale.com/download/windows>. Ejecuta el instalador (`tailscale-setup-*.exe`) y acepta los valores por defecto. Si Windows pide permiso de administrador, acéptalo: instala un adaptador de red virtual.
3. Abre Tailscale desde el menú Inicio o el icono de la bandeja (junto al reloj) → **Log in**. Usa **la misma cuenta** que en la invitación. Se abre el navegador; al terminar, el icono de la bandeja muestra **Connected**.
4. Si tu organización exige aprobar dispositivos, el dueño aprobará tu PC en la consola de Tailscale. Hasta entonces no verás la VM.

Verificación: abre **PowerShell** (Inicio → escribe "PowerShell") y ejecuta

```powershell
tailscale status
```

Debe aparecer `orca-cliente-a`. Si `tailscale` no se reconoce como comando, cierra y vuelve a abrir PowerShell (el instalador agrega la ruta), o usa `& "C:\Program Files\Tailscale\tailscale.exe" status`.

## 2. Comprobar que llegas a la VM

En PowerShell:

```powershell
Test-NetConnection 100.80.185.107 -Port 6768
```

Esperado: `TcpTestSucceeded : True`. Si es `False`:

- Tailscale no está conectado o estás con otra cuenta → paso 1.
- La VM está apagada: está pensada para estar encendida 24/7. Avisa al dueño para que la encienda.
- Tu usuario no está en la ACL → avisa al dueño.

## 3. Instalar Orca 1.4.251

El servidor corre Orca **1.4.251**. Instala exactamente esa versión.

1. Descarga el instalador de esa versión (no el "latest"):
   <https://github.com/stablyai/orca/releases/download/v1.4.251/orca-windows-setup.exe>
2. (Recomendado) Verifica la descarga en PowerShell:

   ```powershell
   Get-FileHash "$env:USERPROFILE\Downloads\orca-windows-setup.exe" -Algorithm SHA256
   ```

   El hash debe ser `E1BF85ADDF3B9E16D32C3D3985334C188082C7472B88E14C1137C470A06DBB1A`.
3. Ejecuta `orca-windows-setup.exe`. Si aparece el aviso de **SmartScreen** ("Windows protegió su PC"), pulsa **Más información → Ejecutar de todas formas**. Sigue el asistente con los valores por defecto.
4. Abre Orca desde el menú Inicio. Comprueba la versión en **Help → About Orca** (o **Settings → General → Updates**): debe decir **1.4.251**.
5. Si el primer arranque pide configurar agentes o iniciar sesión en Claude en tu PC, **omítelo**: los agentes corren en el servidor. Si pregunta por una carpeta local de proyectos, acepta la propuesta; no la usarás.

Sobre actualizaciones: Orca se actualiza solo al canal estable. Si un día el servidor aparece como **incompatible**, avisa al dueño; no intentes bajar de versión.

## 4. Agregar el servidor remoto

Pide al dueño tu **link de pareo** (te llega por un canal cifrado; es personal y de un solo uso).

1. En Orca: **Settings** (Ctrl+,) → **Remote Orca Servers** → **Add server**.
2. Nombre `orca-cliente-a`, pega el link completo, **Add Server**.
3. La fila debe mostrar **Connected** (`Linux · orca-cliente-a... · 100.80.185.107:6768 · v1.4.251`). Si queda **Disconnected**, pulsa **Connect**.
4. Avisa al dueño para que cierre el modo de pareo.

Si el link no funciona, pide uno nuevo mientras estás delante de Orca: cada link vale una vez.

## 5. Trabajar en el servidor

1. En **Settings → Remote Orca Servers → New projects open on** elige `orca-cliente-a` (en versiones anteriores: **Advanced → Active Server**).
2. Abrir un repo ya existente en la VM: **Add project** y la ruta del servidor, por ejemplo `/home/orca/projects/<repo>`. Son rutas Linux del servidor, no de tu PC: no busques en `C:\`.
3. Repo nuevo: **Create a new project** y la ruta que proponga bajo `/home/orca/...`.
4. Crea un worktree y lanza un agente. Corre en la VM: puedes apagar o suspender el PC y al volver sigue.
5. Las terminales que abras desde Orca son terminales Linux (`bash`) en la VM como usuario `orca`, sin permisos de administrador. Los comandos son los de Linux, no PowerShell.

Ten en cuenta lo mismo que en macOS: las credenciales (git, Claude) son las del servidor, todo el equipo comparte los mismos proyectos.

## Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `tailscale status` no muestra el servidor | No estás en el tailnet o en la ACL | Revisa la cuenta; avisa al dueño |
| `TcpTestSucceeded : False` | VM apagada o sin ACL | Avisar al dueño |
| **Disconnected** | Tailscale se cayó o la VM se reinició | Icono de Tailscale → Connected; en Orca, **Connect** |
| "incompatible protocol version" | Tu Orca se actualizó y el servidor no | Avisa al dueño |
| El link de pareo no sirve | Ya usado o reemplazado | Pide uno nuevo |
| Un antivirus o firewall corporativo bloquea Tailscale | Políticas del PC | Pide a TI permitir `tailscale.exe` y el adaptador "Tailscale" |

## Política de versiones

Igual que en macOS: el servidor está fijado en **1.4.251**; el escritorio se actualiza solo y no hay opción documentada para impedirlo. Cuando deje de ser compatible, el dueño actualiza el servidor (cambia `ORCA_VERSION` y re-ejecuta el startup). Nadie instala nada a mano.
