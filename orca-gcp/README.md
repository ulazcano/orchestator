# orca-gcp: Orca remoto en GCP, una VM por cliente

Automatiza el despliegue de [Orca](https://www.onorca.dev) en modo **Remote Orca Server** sobre una VM de GCP por cliente (repos, credenciales y costos separados), accedida desde el Mac del dueño por **Tailscale**. Contexto y reglas: [`docs/orca-gcp-spec.md`](../docs/orca-gcp-spec.md) y [`docs/PLAN.md`](../docs/PLAN.md).

Principios: sin puertos públicos (solo Tailscale + SSH por IAP), sin secretos en el repo/logs/metadata, un usuario `orca` **sin sudo** para los agentes, versión de Orca fijada e igual a la del Mac.

## Arquitectura

```
Mi Mac (Orca desktop, cliente) ──Tailscale──► VM orca-<cliente> (orca-ide serve, servicio systemd de usuario)
                                              ├─ usuario `orca` SIN sudo
                                              ├─ Claude Code / Codex / git / gh instalados en la VM
                                              ├─ credenciales propias del cliente (nunca las de mi Mac)
                                              └─ repos en ~orca/projects
```

Detalles fijos (contratos del plan): proyecto `bove-orca`, `us-central1-a`, red `orca-vpc`/`orca-subnet`, `n4-standard-8` + disco Hyperdisk Balanced 200 GB, Ubuntu 24.04, etiqueta `cliente=<slug>` en VM y disco, tag de red `orca`, SSH solo desde `35.235.240.0/20` (IAP), puerto de Orca `6768` (sin regla de firewall que lo exponga: solo se alcanza por Tailscale), secreto `tailscale-authkey-<slug>`, tag Tailscale `tag:orca-<slug>`.

## Contenido

| Ruta | Qué es | Workspace |
|---|---|---|
| `scripts/bootstrap-project.sh` | Base del proyecto (APIs, red, firewall IAP) | 0 |
| `scripts/create-client.sh` · `vm-startup.sh` · `destroy-client.sh` · `lib.sh` | Crear / destruir un cliente | 1 |
| `scripts/schedule-client.sh` | Horario on/off, snapshots y presupuesto | 2 |
| `scripts/verify-client.sh` · `docs/verificacion.md` | Checklist de la Fase 5 | 3 |
| [`docs/pasos-manuales.md`](docs/pasos-manuales.md) | Lo que hace el dueño (Tailscale, logins, pareo) | 2 |
| [`docs/costos.md`](docs/costos.md) | Estimación mensual y diseño de auto-apagado | 2 |

> Los scripts de los workspaces 0, 1 y 3 se integran en sus propios PRs; esta tabla puede adelantarse a la rama `main`.

## Crear un cliente nuevo (un comando + pasos manuales)

Prerrequisito único por proyecto: `bootstrap-project.sh` ya ejecutado (facturación vinculada por el dueño, APIs, VPC, regla IAP).

```bash
# 1. Un comando: VM + secreto + horario/snapshots (+ presupuesto opcional)
export ORCA_VERSION=<la misma versión que tu Mac>
orca-gcp/scripts/create-client.sh <slug> --dry-run      # revisar primero
orca-gcp/scripts/create-client.sh <slug>
```

`create-client.sh` (workspace 1) crea la VM y el secreto vacío y debe terminar llamando a `schedule-client.sh <slug>` para adjuntar horario y snapshots. *(TODO workspace 1: invocarlo; hasta entonces, ejecútalo a mano como abajo.)*

```bash
# Horario 08:00-21:00 lun-vie (America/Santiago) + snapshots diarios 7 días [+ presupuesto]
orca-gcp/scripts/schedule-client.sh <slug> --dry-run
BILLING_ACCOUNT_ID=<id-que-eliges-tu> orca-gcp/scripts/schedule-client.sh <slug> --budget-amount 150
#   opciones: --on HH:MM --off HH:MM --tz <zona> --budget-amount N --snapshot-time HH:00 --yes
```

Después, los **pasos manuales** de [`docs/pasos-manuales.md`](docs/pasos-manuales.md), en orden: (1) auth key de Tailscale con tag y ACL → Secret Manager; (2) SSH por IAP; (3) logins de Claude/Codex; (4) `gh auth login` con token fine-grained; (5) pareo (`orca-ide serve --port 6768 --pairing-address <IP-Tailscale>`) y alta en *Settings → Remote Orca Servers → Add Server*; (6) opcional móvil; (7) clonar repos en `~/projects`.

### Prerrequisito de IAM para el horario

El `instance-schedule` enciende y apaga la VM con el **Compute Engine Service Agent** del proyecto, que debe tener `roles/compute.instanceAdmin.v1` ([doc](https://docs.cloud.google.com/compute/docs/instances/schedule-instance-start-stop)). Una vez por proyecto, con un usuario con permisos de IAM (no lo ejecuta ningún agente sin tu confirmación):

```bash
PROJECT_NUMBER="$(gcloud projects describe bove-orca --format='value(projectNumber)')"
gcloud projects add-iam-policy-binding bove-orca \
  --member="serviceAccount:service-${PROJECT_NUMBER}@compute-system.iam.gserviceaccount.com" \
  --role="roles/compute.instanceAdmin.v1"
```

La doc de Google no da el correo del agente de servicio ni este comando; el formato `service-<número>@compute-system.iam.gserviceaccount.com` es el del Compute Engine Service Agent: confírmalo en IAM (marcando "Incluir concesiones de roles proporcionadas por Google"). Quien ejecuta `schedule-client.sh` necesita `roles/compute.instanceAdmin.v1`, y para el presupuesto un rol de Billing (p. ej. *Billing Account Administrator* o *Billing Account Costs Manager*) y la API `billingbudgets.googleapis.com` habilitada.

Notas del horario (doc de Google): puede retrasarse hasta 15 min; no hay garantía de capacidad al encender; una VM encendida/apagada a mano mantiene ese estado hasta la próxima operación; el horario no sabe de feriados; el cambio de hora (DST) puede mover una operación. Los presupuestos **avisan, no cortan** el gasto, y envían correo a los administradores de la cuenta de facturación.

## Destruir un cliente

```bash
orca-gcp/scripts/destroy-client.sh <slug> --dry-run     # muestra qué se borrará
orca-gcp/scripts/destroy-client.sh <slug>               # pide confirmación explícita
```

*(Script del workspace 1; verifica sus flags con `--help`.)* Debe borrar VM, disco, secreto, cuenta de servicio y las políticas `orca-horario-<slug>` y `orca-snapshots-<slug>`. Tareas a mano que ningún script de GCP cubre: borrar el dispositivo `orca-<slug>` en Tailscale (Machines), quitar `tag:orca-<slug>` de la ACL, **revocar el token fine-grained de GitHub** y cerrar la sesión de Claude/Codex del cliente, quitar el servidor en *Settings → Remote Orca Servers* del Mac, y eliminar el presupuesto `orca-presupuesto-<slug>`. Las políticas de recursos deben desasociarse (`remove-resource-policies`) antes de borrarse.

## Costos

Ver [`docs/costos.md`](docs/costos.md): ≈ $289/mes 24/7, ≈ $125 con horario 08–21 lun–vie y ≈ $69 con auto-apagado por inactividad (disco optimizado a 3.000 IOPS / 140 MiB/s; el disco por defecto suma ≈ $18). El diseño del auto-apagado está **propuesto, sin implementar**, a la espera de confirmación del dueño.

## Incertidumbres abiertas

1. **Orca remote servers está en beta.** Los flags y el comportamiento pueden cambiar. Estado verificado el 2026-11-09 contra [remote-servers](https://www.onorca.dev/docs/remote-servers) e [install](https://www.onorca.dev/docs/install). Diferencias con la spec: la CLI de Linux es `orca-ide` (la doc de remote servers dice `orca`); `orca-ide serve service` solo tiene `install`/`status`/`uninstall` (no `stop`/`start`); el nombre de la unidad systemd y el flujo interactivo de `account add` no están documentados; no hay comando de instalación del `.deb` en la doc (solo enlace a GitHub Releases).
2. **Compatibilidad de versión Mac–VM.** La doc pide actualizar ambos si el servidor reporta "incompatible protocol version", pero no define reglas de compatibilidad entre versiones. Dato que falta: la versión exacta de Orca en tu Mac. Con `.deb`, Orca avisa de actualizaciones pero no las instala solo; hay que mantener `ORCA_VERSION` sincronizada con el Mac en cada actualización.
3. **Persistencia del pareo.** La doc no dice si el acceso otorgado por un `serve` manual sobrevive cuando vuelve a correr el servicio systemd (pasos 5.1–5.4). Se confirma en la prueba del piloto.
4. **Estado de sesiones de Orca para el auto-apagado.** No hay API documentada para saber si hay sesiones activas; el diseño propuesto depende de procesos y conexiones (ver `docs/costos.md`).
5. **Cómo se añaden proyectos remotos en la UI** y qué hace *Advanced → Active Server* con proyectos existentes: las dos páginas de doc no lo detallan.
6. **Precio de `n4-standard-8`** tomado de agregadores (la página oficial de GCP no entrega las tablas sin JavaScript). Confírmalo con la calculadora de precios antes de fijar presupuestos.
7. **Sintaxis `tcp:6768` en los grants de Tailscale** no figura en los ejemplos de la doc; validar con *Preview rules*.
8. **Comandos locales con autenticación del Mac** (CLIs con login, VPN, llavero, MFA) usados hoy desde Conductor: son materia de la prueba crítica (workspace 3). Dato que falta: lista de esos comandos.

## Incorporar al equipo (clientes de Orca en Mac y Windows)

- [`docs/guia-equipo-mac.md`](docs/guia-equipo-mac.md): guía de cero a conectado para macOS, con la sección "Para el dueño" (invitación a Tailscale, ACL por grupo, link de pareo, revocación).
- [`docs/guia-equipo-windows.md`](docs/guia-equipo-windows.md): lo mismo para Windows.
- `scripts/pair-client.sh <slug> [--mobile]`: el dueño genera un link de pareo por persona desde su Mac (detiene el servicio, arranca `serve` con pareo, imprime el link solo en su terminal, y restaura el servicio al pulsar Enter).
