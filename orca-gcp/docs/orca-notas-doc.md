# Notas: comandos de Orca verificados contra la documentación oficial

Verificado el 2026-11-09 contra:

- https://www.onorca.dev/docs/remote-servers
- https://www.onorca.dev/docs/install
- Release `v1.4.255` de `stablyai/orca` (assets y `latest-linux.yml`)
- `--help` del binario `orca-ide` 1.4.255 instalado desde el `.deb` en un contenedor `ubuntu:24.04`

Los remote servers están en **beta**: todo esto puede cambiar. Cuando la doc y la spec
(`docs/orca-gcp-spec.md`) difieren, el script sigue la doc.

## Diferencias spec vs. doc

| # | Tema | Spec | Doc oficial / observado | Qué hace el script |
|---|------|------|-------------------------|--------------------|
| 1 | Nombre de la CLI | `orca-ide` en Linux | La página *remote-servers* escribe todos los comandos como `orca ...` y nunca menciona `orca-ide`. La página *install* dice: "The Linux CLI is named `orca-ide` so it does not conflict with the GNOME Orca screen reader." | Usa `orca-ide` (coincide con spec e install). Todo comando de la doc con `orca` se traduce a `orca-ide`. |
| 2 | Servicio | `orca-ide serve service install --port 6768` | Doc: `orca serve service install --port 6768`, `... status`, `... uninstall`. Escribe una unidad **systemd de usuario** que ejecuta `orca serve --supervise --no-pairing`. Coincide. | Igual que la spec, ejecutado como `orca` con `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` de su sesión de usuario. |
| 3 | Lingering | `loginctl enable-linger orca` | Doc: el servicio se detiene al cerrar sesión salvo que haya lingering; `install` lo avisa. Coincide. | `loginctl enable-linger orca` **antes** de registrar el servicio, más `systemctl start user@<uid>.service` para tener el bus de usuario sin sesión. |
| 4 | Nombre del `.deb` | "el .deb de GitHub Releases" | La doc de install **no da el nombre** del `.deb` (solo enlaza a Releases). Observado en `v1.4.255`: `orca-ide_<versión>_amd64.deb` (y `_arm64.deb`), tag `v<versión>`. | URL `https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide_${ORCA_VERSION}_<arch>.deb`. Si el patrón cambia, el paso falla con 404 (no instala nada) — ver incertidumbres. |
| 5 | Checksums | "verificar checksum si lo publican" | La doc **no menciona checksums**. Cada release publica `latest-linux.yml` (formato electron-updater) con `sha512` en base64 del `.deb`. La API de GitHub además expone un `digest` sha256 por asset. | Verifica el sha512 contra `latest-linux.yml` de **la misma release**: si no se puede descargar el yml o el hash no coincide, aborta sin instalar (falla cerrada); solo si el yml existe pero no lista el `.deb` avisa y continúa. Nota: el yml y el `.deb` vienen del mismo origen, así que detecta corrupción pero no un release comprometido. |
| 6 | Auto-update | "No uses auto-update" | Doc install: el AppImage se actualiza solo; el `.deb`/`.rpm` "report available updates and give you the package-manager command". | Instala el `.deb` y hace `apt-mark hold` del paquete (`orca-ide`) para que ningún `apt upgrade` lo cambie. Al cambiar `orca-version` el script hace `unhold` → instala → `hold` (probado 1.4.255 → 1.4.254). |
| 7 | Pareo con el servicio activo | Fase 3, paso 3: detener el servicio, correr `orca-ide serve --port 6768 --pairing-address <IP-Tailscale>`, copiar el link, Ctrl-C, reiniciar el servicio. | La doc de *remote-servers* dice lo mismo ("Pair clients from the desktop app, or run `orca serve` in a terminal while the service is stopped"). Pero el `--help` de **1.4.255** documenta `orca pair [--address <host>] [--mobile] [--rotate]`: "Pair ... with the Orca already running here, without restarting it", y `service install` dice "Pair clients with `orca pair` while it runs". **`orca pair` no aparece en la doc web.** | El script no empareja (lo hace el dueño). Para `pasos-manuales.md` (workspace 2): preferir `orca-ide pair --address <IP-Tailscale>` con el servicio corriendo; dejar el método de la doc como respaldo. Verificar en la VM real. |
| 8 | Interfaz en la que escucha | No especificado | `serve` y `service install` aceptan `--bind <ip>` y `--allow-public \| --refuse-public`. `pair` indica que "the first network pairing makes a loopback-only Orca listen on every interface". `serve` solo acepta clientes de localhost, LAN y Tailscale (100.64/10) salvo `--allow-public`. | Se instala **sin** `--bind`/`--refuse-public` (tal como pide la spec). La VM no tiene ingreso público (firewall: solo IAP/22), pero ver incertidumbres: conviene decidir `--refuse-public` o `--bind <IP-Tailscale>`. |
| 9 | Puerto por defecto | `--port 6768` | Doc: no indica puerto por defecto. `--help` 1.4.255: "Without it, serve uses 6768 and moves to another port when 6768 is taken". | Se pasa `--port 6768` explícito (con `--port`, `serve` falla si está ocupado, que es lo deseado). |
| 10 | Cuentas del agente | `orca-ide account add --agent claude` | Doc: `orca account add --agent claude\|codex`. `--help` 1.4.255 añade `opencode` y `devin`, y `--label`. | Fuera del alcance de los scripts (lo hace el dueño); relevante para `pasos-manuales.md`. |
| 11 | Servicio sin systemd | — | Observado: `orca-ide serve service install --port 6768` sin bus de usuario falla con "`systemctl --user daemon-reload` failed: Failed to connect to bus" (y retorna 0). | El script crea el bus (linger + `user@<uid>.service`) y luego comprueba con `orca-ide serve service status`. |

## Otras verificaciones (no son de Orca)

- **Tailscale**: `tailscale up --auth-key=file:<ruta>` está documentado (https://tailscale.com/kb/1241/tailscale-up). Se usa
  `file:/dev/fd/3` con un pipe anónimo para que la key no pase por argv ni por disco. Probado con el
  `tailscaled` real (1.104.5, modo `userspace-networking`) y una key falsa: Tailscale leyó el descriptor y el
  control server respondió `invalid key: API key does not exist` (el rechazo viene del servidor, no de la lectura).
  Los flags no se persisten: se pasan `--hostname` y `--advertise-tags` en cada ejecución.
  Repositorio apt oficial para `noble` (`pkgs.tailscale.com/stable/ubuntu/noble.*`), en vez de `curl | sh`.
- **Claude Code**: instalador oficial `https://claude.ai/install.sh`, descargado a un archivo y ejecutado como `orca`
  (queda en `~orca/.local/bin/claude`). Se actualiza solo (comportamiento del instalador nativo).
- **Node LTS**: NodeSource `setup_lts.x` (en la prueba de hoy instaló Node 26.x; "LTS" es lo que NodeSource marque como tal).
- **gh**: repositorio apt oficial `cli.github.com`.

## Incertidumbres abiertas (necesitan la VM real o al dueño)

1. **Beta**: flags y rutas pueden cambiar entre versiones; la versión queda fijada por `ORCA_VERSION` y el paquete en hold.
2. **Mac ↔ VM**: la compatibilidad entre versiones de cliente y servidor no está documentada. `ORCA_VERSION` debe ser la
   del Mac; si el Mac se actualiza, hay que recrear/actualizar la VM con la misma versión.
3. **Patrón del nombre del `.deb`** (`orca-ide_<v>_amd64.deb`): inferido de las releases, no documentado.
4. **Interfaz de escucha del servicio**: sin `--bind`, no está claro en qué interfaz escucha antes/después del primer pareo.
   Propuesta (decisión del dueño): `service install --port 6768 --refuse-public` o `--bind <IP Tailscale>`.
   No se aplicó para no desviarse de la spec.
5. **Unidad systemd de usuario**: `orca-ide serve service install --port 6768 --dry-run` (probado en 1.4.255) indica que escribirá
   `~orca/.config/systemd/user/orca-serve.service` con `ExecStart=/usr/bin/orca-ide serve --supervise --no-pairing --port 6768`,
   `Restart=on-failure` y `WantedBy=default.target`. Lo que no se pudo ver (el sandbox no corre systemd) es si `install` además
   la habilita/arranca; el script habilita cualquier unidad cuyo nombre contenga "orca", lo cual es un no-op si ya lo está.
6. **Registro del servicio y `enable-linger` no se probaron end-to-end** (necesitan systemd real); la validación está en el
   checklist de Fase 5 con la VM piloto (workspace 3).
7. **`orca-ide` en VM sin pantalla**: el runtime por defecto es `orcad` (Node); la doc indica que, si no puede servir, cae
   al servidor de la app de escritorio. En Linux headless no se verificó cuál se usa. `ORCA_SERVE_RUNTIME=orcad` lo fuerza.
8. **Imagen de la VM**: no se pudo comprobar que `gcloud` venga preinstalado en `ubuntu-2404-lts-amd64`; el script lo instala
   desde el repo apt de Google Cloud si falta (paso `tailscale-up`).
9. **Scopes de la VM**: se usa `cloud-platform` porque Secret Manager lo exige; el límite real lo pone IAM
   (la cuenta de servicio solo debe tener `secretAccessor` sobre su secreto — responsabilidad de `bootstrap-project.sh`).
10. **SSH como `orca-admin`**: sin OS Login, `gcloud compute ssh orca-admin@orca-<slug> --tunnel-through-iap` agrega una llave a la
    metadata (el contrato de metadata permite solo `client`, `orca-version`, `startup-script`; las llaves SSH las agrega gcloud).
    Si el proyecto fuerza OS Login, `admin` no se usa y el acceso es con la identidad Google (rol `roles/compute.osAdminLogin`).
    Nunca entrar como `orca` por gcloud: el agente de invitado de GCE lo agregaría a `google-sudoers` (el script lo neutraliza con
    `/etc/sudoers.d/zz-orca-nosudo`, pero es mejor no depender de eso).

11. **Unidad systemd y corte duro (observado en la VM piloto, 2026-11-10):** `orca-ide serve service install` crea
    `~/.config/systemd/user/orca-serve.service` (`orca-ide serve --supervise --no-pairing --port 6768`, `Restart=on-failure`)
    y escribe varios archivos en `~/.config/orca`. Un `gcloud compute instances reset` 45 s después dejó todos esos archivos
    en **0 bytes** (ext4 no había vaciado los datos): la unidad vacía aparece como *masked* y `serve` falla con
    `agent_session_ownership_unknown`. El supervisor se rinde tras 6 fallos en 15 min. Reinicia solo con `sudo reboot`
    o `gcloud compute instances stop/start`; el startup ahora verifica en cada arranque que el servicio esté activo y
    escuchando, y lo repara borrando únicamente archivos vacíos.
12. **Arranque de `serve` en headless:** imprime `using Electron serve: orcad did not answer its native preflight` y errores
    de D-Bus de Chromium; son inofensivos. El servidor queda `Bound endpoint: ws://0.0.0.0:6768`.

