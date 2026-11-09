# Plan de trabajo: Orca remoto en GCP (una VM por cliente)

Especificación completa: [`docs/orca-gcp-spec.md`](./orca-gcp-spec.md). **Léela antes de hacer nada.**
Las reglas de la sección 2 de la spec son obligatorias para todos los workspaces.

## División en workspaces de Conductor

| # | Workspace | Fases | Archivos que posee (nadie más los toca) |
|---|-----------|-------|------------------------------------------|
| 0 | Diagnóstico y base GCP | 0, 1 | `orca-gcp/docs/diagnostico.md`, `orca-gcp/scripts/bootstrap-project.sh` |
| 1 | Scripts de aprovisionamiento | 2 | `orca-gcp/scripts/create-client.sh`, `orca-gcp/scripts/vm-startup.sh`, `orca-gcp/scripts/destroy-client.sh`, `orca-gcp/scripts/lib.sh`, `orca-gcp/docs/orca-notas-doc.md`, `orca-gcp/tests/` |
| 2 | Docs, costos y horario | 3, 4 | `orca-gcp/README.md`, `orca-gcp/docs/pasos-manuales.md`, `orca-gcp/docs/costos.md`, `orca-gcp/scripts/schedule-client.sh` |
| 3 | Verificación y prueba crítica | 5 | `orca-gcp/docs/verificacion.md`, `orca-gcp/docs/comandos-mac-auth.md`, `orca-gcp/scripts/verify-client.sh` |

Cada workspace trabaja en su rama `ulazcano/orca-gcp-<n>-<tema>` y abre un PR contra `main`
(`gh pr create --base main`). PRs pequeños y frecuentes; no esperar a terminar toda la fase.
Si necesitas algo que posee otro workspace, deja un TODO en tu PR y descríbelo en el mensaje final; no lo edites.

## Contratos compartidos (nombres fijos, no inventar otros)

```bash
PROJECT_ID="bove-orca"
REGION="us-central1"
ZONE="us-central1-a"
NETWORK="orca-vpc"
SUBNET="orca-subnet"            # 10.10.0.0/24
NETWORK_TAG="orca"              # tag de red para la regla IAP
IAP_RANGE="35.235.240.0/20"
FW_RULE_IAP="orca-allow-iap-ssh"
VM_NAME="orca-${CLIENT}"        # CLIENT = slug del cliente, ej: cliente-a
LABEL="cliente=${CLIENT}"       # en VM y disco
SERVICE_ACCOUNT="orca-vm-${CLIENT}@${PROJECT_ID}.iam.gserviceaccount.com"
SECRET_TS_AUTHKEY="tailscale-authkey-${CLIENT}"
TS_HOSTNAME="orca-${CLIENT}"
TS_TAG="tag:orca-${CLIENT}"
MACHINE_TYPE="n4-standard-8"    # default
DISK_GB="200"                   # default, hyperdisk-balanced
IMAGE_FAMILY="ubuntu-2404-lts-amd64"; IMAGE_PROJECT="ubuntu-os-cloud"
ORCA_VERSION="${ORCA_VERSION:?}" # fijada por variable, misma que el Mac; sin auto-update
ORCA_PORT="6768"
ORCA_USER="orca"                # sin sudo
ADMIN_USER="admin"              # con sudo, solo IAP
SCHEDULE_NAME="orca-horario-${CLIENT}"   # 08:00 on / 21:00 off, lun-vie, America/Santiago
SNAPSHOT_POLICY="orca-snapshots-${CLIENT}" # diario, retención 7 días
STARTUP_LOG="/var/log/orca-startup.log"  # sin secretos
```

Convenciones de scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, variables al inicio,
idempotentes, `--dry-run` que imprime los comandos `gcloud` sin ejecutarlos, `--help`,
cero secretos incrustados o impresos. `shellcheck` limpio.

Metadata de la VM: solo `client`, `orca-version`, `startup-script`. **Nunca** la authkey.
La VM lee el secreto con `gcloud secrets versions access latest --secret="$SECRET_TS_AUTHKEY"`
usando su cuenta de servicio (rol `roles/secretmanager.secretAccessor` solo sobre ese secreto).

## Dependencias entre workspaces

- 1, 2 y 3 pueden empezar ya (todo es escribible y probable en seco sin GCP).
- 0 es interactivo con el dueño (facturación, `gcloud auth`). Nada de 1-3 ejecuta `gcloud` real
  hasta que 0 reporte que el proyecto tiene facturación y APIs habilitadas.
- 3 ejecuta el checklist real solo cuando exista la VM piloto `orca-cliente-a` creada con el script de 1.

## Estado

Actualiza esta sección en tu PR con una línea por hito (fecha, workspace, qué quedó listo).

- 2026-11-09 · setup · Repo inicializado con spec y plan.
- 2026-11-09 · ws2 · Docs, costos y horario: `schedule-client.sh` (probado con `--dry-run`, shellcheck limpio), `pasos-manuales.md`, `costos.md` y `README.md` listos en PR. Pendiente del dueño: confirmar auto-apagado por inactividad (solo propuesto) y elegir cuenta de facturación/monto del presupuesto. TODO ws1: disco con `provisioned-iops=3000,provisioned-throughput=140` (ahorra ≈ $18/mes) e invocar `schedule-client.sh` desde `create-client.sh`.
