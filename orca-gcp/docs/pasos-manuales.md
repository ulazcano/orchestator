# Pasos manuales (Fase 3): lo que hace el dueño, en orden

Reemplaza `<slug>` por el slug del cliente (ej. `cliente-a`). Estos pasos son **tuyos**: los agentes no inician sesión por ti, no generan auth keys ni pegan el link de pareo (spec, reglas 3 y 4).

**Regla de oro:** nada de lo que sigue debe pegarse en un chat, issue, commit ni log: la auth key de Tailscale, el token de GitHub, los códigos de login de Claude/Codex y el **link de pareo de Orca** dan acceso directo.

**Fuentes verificadas** (consultadas el 2026-11-09; Orca está en beta, vuelve a revisarlas si algo no coincide):
[Remote servers](https://www.onorca.dev/docs/remote-servers) · [Install](https://www.onorca.dev/docs/install) ·
[Tailscale auth keys](https://tailscale.com/kb/1085/auth-keys) · [Tailscale grants](https://tailscale.com/kb/1337/grants)

> ⚠️ Diferencias con la spec/plan, señaladas donde ocurren (la doc manda):
> 1. La doc de Orca escribe `orca ...`; en Linux la CLI se llama **`orca-ide`** ([Install](https://www.onorca.dev/docs/install): "The Linux CLI is named `orca-ide` so it does not conflict with the GNOME Orca screen reader."). Uso `orca-ide`.
> 2. **No existen `stop`/`start` del servicio en `orca-ide`.** La doc solo lista `serve service install`, `serve service status` y `serve service uninstall`. "Detener el servicio" se hace con `systemctl --user` (paso 5), y el nombre de la unidad **no está documentado**.
> 3. `orca-ide account add --agent claude|codex` sí está en [Remote servers](https://www.onorca.dev/docs/remote-servers) (sección *Accounts and skills on a headless host*), pero el flujo de login (URL/código) no está descrito. Tampoco se documenta que el servicio no imprima el link de pareo: lo da por hecho la spec.

---

## 0. Prerrequisitos

- Facturación y APIs listas (workspace 0) y la VM creada: `orca-gcp/scripts/create-client.sh <slug>` (workspace 1). Eso crea también el secreto vacío `tailscale-authkey-<slug>`.
- Tailscale instalado y con sesión en tu Mac, en el **mismo tailnet** que usará la VM ([Remote servers → Prerequisites](https://www.onorca.dev/docs/remote-servers)).
- Orca instalado en el Mac **con la misma versión** que `ORCA_VERSION` de la VM. Si el servidor aparece como incompatible, "Update Orca on both computers" (doc).
- Tu usuario de Google con el rol `roles/iap.tunnelResourceAccessor` (para `--tunnel-through-iap`).

## 1. Tailscale: ACL, auth key y carga en Secret Manager

### 1.1 Definir el tag y la ACL (una vez por cliente)

En la consola de administración de Tailscale → **Access controls**, define el tag y una regla que **solo tu Mac** pueda alcanzar el puerto de Orca de esa VM. Ejemplo mínimo (sustituye `<slug>`, `<tu-email>` y el tag de tu Mac):

```json
{
  "tagOwners": {
    "tag:orca-<slug>": ["<tu-email>"],
    "tag:mac-dueno":   ["<tu-email>"]
  },
  "grants": [
    {
      "src": ["tag:mac-dueno"],
      "dst": ["tag:orca-<slug>"],
      "ip":  ["tcp:6768"]
    }
  ]
}
```

- Tailscale es *deny by default*: lo no listado queda bloqueado, y la VM (tag `orca-<slug>`) no puede iniciar conexiones hacia tu Mac ni hacia otras VM. Si tu política actual tiene la regla "permitir todo" (`src:*, dst:*`), **quítala o acótala**; si no, la VM sí vería tu red.
- `tag:mac-dueno` se asigna a tu Mac en **Machines → ⋯ → Edit ACL tags**. Alternativa más simple: `"src": ["<tu-email>"]` (todos tus dispositivos, incluido tu teléfono).
- ⚠️ La doc de grants no documenta explícitamente la sintaxis `"tcp:6768"` en `ip`; los ejemplos usan `"ip": ["*"]`. Si el editor la rechaza, usa `"ip": ["*"]` hacia el tag y valida con *Preview rules*.

### 1.2 Generar la auth key (solo tú, en el navegador)

Consola de Tailscale → **Settings → Keys → Generate auth key**:

| Opción | Valor | Motivo |
|---|---|---|
| Reusable | **apagado** (de un solo uso) | si se filtra, ya está consumida |
| Ephemeral | **apagado** | la VM se apaga cada noche; una clave efímera borraría el dispositivo al quedar offline |
| Pre-approved | encendido si tu tailnet exige aprobación de dispositivos | |
| Tags | `tag:orca-<slug>` | debe coincidir con `--advertise-tags` del startup script |
| Expiración | **1 día** (rango permitido: 1–90) | solo se usa en el primer arranque |

Los dispositivos con tag **no** expiran su node key por defecto, y expirar la auth key no desconecta una VM ya registrada ([doc](https://tailscale.com/kb/1085/auth-keys)).

### 1.3 Cargarla en Secret Manager por stdin

Sin que la clave quede en el historial ni en pantalla:

```bash
read -rsp 'Tailscale auth key: ' TS_KEY; echo
printf '%s' "$TS_KEY" | gcloud secrets versions add "tailscale-authkey-<slug>" --project=bove-orca --data-file=-
unset TS_KEY
```

### 1.4 Si la VM ya arrancó sin la clave, reejecutar el startup script

Si `create-client.sh` creó la VM antes de que existiera la versión del secreto, el `tailscale up` del primer arranque habrá fallado. Tras cargar la clave, reejecuta el startup (idempotente) por IAP:

```bash
gcloud compute ssh "orca-<slug>" --zone us-central1-a --tunnel-through-iap --project=bove-orca \
  --command 'sudo google_metadata_script_runner startup'
```

Luego comprueba `Tailscale` en el log (sin secretos): `sudo tail -n 30 /var/log/orca-startup.log`.
*TODO (workspace 1):* confirmar en su README si el startup reintenta solo o si hay que reiniciar la VM; ajustar este paso.

En tu Mac, `tailscale status` debe listar `orca-<slug>` con su tag. Anota su IP `100.x.y.z` (también: `tailscale ip -4 orca-<slug>` en el Mac, o `sudo tailscale ip -4` en la VM).

## 2. Entrar a la VM por IAP

```bash
gcloud compute ssh "orca-<slug>" --zone us-central1-a --tunnel-through-iap --project=bove-orca
```

No hay IP pública entrante ni puerto 22 abierto a internet: solo el rango IAP `35.235.240.0/20`.
*TODO (workspace 1):* si `create-client.sh` fija un usuario/clave distinto (`admin` con OS Login o metadatos), indicar aquí el comando exacto (p. ej. `admin@orca-<slug>`).

Cambia al usuario sin sudo, que es quien corre el servidor de Orca y los agentes:

```bash
sudo -iu orca
export XDG_RUNTIME_DIR="/run/user/$(id -u)"   # necesario para systemctl --user en esta sesión
```

Todo lo de los pasos 3 a 7 se ejecuta como **`orca`**, salvo donde se indique.

## 3. Cuentas de los agentes (credenciales del cliente)

Instala/autentica los agentes **en la VM**; el login de tu Mac no se traslada ([doc](https://www.onorca.dev/docs/remote-servers): "a laptop login doesn't carry over"). Usa **la cuenta del cliente**, no la tuya.

```bash
orca-ide account add --agent claude
orca-ide account add --agent codex      # solo si el cliente usa Codex
orca-ide account list
```

El flujo interactivo (abrir una URL en tu navegador y pegar un código) **no está descrito en la doc**: sigue las instrucciones en pantalla. No pegues el código ni la URL de login en ningún chat.

## 4. GitHub (`gh`) con token fine-grained

1. En GitHub (con la cuenta/organización del cliente) → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**:
   - *Resource owner*: la organización o cuenta del cliente.
   - *Repository access*: **Only select repositories** → solo los repos de ese cliente.
   - *Permissions*: `Contents: Read and write`, `Pull requests: Read and write`, `Metadata: Read` (y `Issues`/`Workflows` solo si hacen falta).
   - *Expiration*: corta (30–90 días) y anótala para renovar.
2. En la VM:

```bash
gh auth login        # GitHub.com → HTTPS → "Paste an authentication token" (se escribe oculto)
gh auth setup-git    # git usa el token de gh para clonar/pushear
gh auth status
```

## 5. Parear el servidor con tu Mac

El servicio de Orca (`orca-ide serve service`) **no imprime el link de pareo**; hay que correr `serve` una vez en primer plano.

**5.1 Detener el servicio** (como `orca`; ⚠️ diferencia con la spec: `orca-ide` no tiene `stop`):

```bash
orca-ide serve service status
systemctl --user list-units --type=service | grep -i orca    # descubre el nombre real de la unidad
systemctl --user stop <unidad-encontrada>
```

Si no hallas la unidad: la doc documenta `orca-ide serve service uninstall` (detiene el servicio y quita la unidad, pero **deja vivos el daemon de terminales y sus sesiones**) y luego `orca-ide serve service install --port 6768` en el paso 5.4.

**5.2 Servidor en primer plano, una vez** (usa la IP Tailscale de la VM; nunca `127.0.0.1` ni un comodín):

```bash
orca-ide serve --port 6768 --pairing-address <IP-Tailscale>
```

Imprime un **link de pareo**. Es un secreto: "the pairing URL grants access to this Orca runtime" (doc). No lo pegues en chats ni lo guardes.

**5.3 Agregarlo en tu Mac** (Orca → **Settings → Remote Orca Servers → Add Server**): escribe un nombre (`orca-<slug>`), pega el link, pulsa **Add Server** y luego **Connect** si aparece *Disconnected*. Debe pasar a **Connected**.

Después vuelve a la VM, **Ctrl-C** al `serve` y borra la pantalla (`clear`).

**5.4 Reiniciar el servicio:**

```bash
systemctl --user start <unidad-encontrada>
orca-ide serve service status        # debe indicar que corre
```

(Si hiciste `uninstall`: `orca-ide serve service install --port 6768`.)

Comprueba en el Mac que el servidor sigue **Connected**. La doc no aclara si el token de un `serve` manual persiste para el servicio; si queda *Disconnected*, repite 5.1–5.4 (y revisa/revoca el acceso en **Shared Server Access**).

Agregar el servidor **no enruta proyectos** hacia él: para usarlo por defecto, en el Mac ve a **Advanced → Active Server** ([doc](https://www.onorca.dev/docs/remote-servers)).

Para **revocar** un Mac o teléfono: *Shared Server Access* → botón de papelera (cada cliente pareado tiene su token revocable).

## 6. Opcional: pareo móvil

Mismo procedimiento (detener servicio, correr `serve`, reiniciar) pero con `--mobile-pairing`, que genera un QR/link con alcance móvil:

```bash
orca-ide serve --port 6768 --pairing-address <IP-Tailscale> --mobile-pairing
```

El teléfono necesita Tailscale en el mismo tailnet, y tu ACL (paso 1.1) debe permitirle alcanzar el tag de la VM (añade su tag/usuario en `src`).

## 7. Clonar los repos y agregarlos como proyectos

Como `orca`, en la VM:

```bash
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/<org-del-cliente>/<repo>.git
```

Luego, en tu Mac, con el servidor remoto como *Active Server*, agrega cada repo como proyecto apuntando a `/home/orca/projects/<repo>`. ⚠️ Las dos páginas de la doc consultadas no detallan el menú exacto para añadir proyectos remotos: si la UI difiere, sigue la UI e infórmalo.

## 8. Verificación rápida

- [ ] `tailscale status` (Mac) muestra `orca-<slug>` con su tag.
- [ ] El servidor figura **Connected** en *Settings → Remote Orca Servers*.
- [ ] `orca-ide serve service status` = running (en la VM); reinicia la VM y vuelve a comprobar.
- [ ] `orca-ide account list` y `gh auth status` muestran solo credenciales del cliente.
- [ ] `sudo -n true` como `orca` falla (sin sudo).

La verificación completa (Fase 5) está en `orca-gcp/docs/verificacion.md` (workspace 3).
