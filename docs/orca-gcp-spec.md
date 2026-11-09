# Objetivo: automatizar el despliegue de Orca (servidor remoto) en GCP, una VM por cliente

## 1. Contexto

Conductor Cloud se apaga el 20/11/2026 (solo lectura desde el 13/11). Migro a **Orca** (MIT, stablyai/orca) en modo **Remote Orca Server**, con **una VM de GCP por cliente** (cada una con sus repos, credenciales y costo separados), accedida desde mi Mac por **Tailscale**.

Estado actual:
- Proyecto GCP: `bove-orca`. La API `compute.googleapis.com` falló al habilitarse porque el proyecto **no tenía facturación vinculada**. Verifica el estado antes de asumir nada.
- Cuentas de facturación disponibles: `<BILLING_ACCOUNT_2>` ("Mi cuenta de facturación 2") y `<BILLING_ACCOUNT_1>` ("Mi cuenta de facturación"). **Yo elijo cuál vincular; no la elijas tú.**
- Prueba inicial: `orca-cliente-a` en `us-central1-a`, `n4-standard-8`, Ubuntu 24.04, disco Hyperdisk Balanced de 200 GB.

## 2. Reglas de trabajo (obligatorias)

1. **Pide confirmación en el chat antes de cada acción que cree o cambie recursos con costo** (VMs, discos, snapshots, secretos, políticas, reglas de firewall). Antes de ejecutar, muestra el comando exacto.
2. **Un solo cliente piloto (`cliente-a`)** hasta que yo valide el flujo completo. No crees VMs de otros clientes.
3. **Nunca escribas ni imprimas secretos** (tokens, auth keys de Tailscale, links de pareo de Orca, API keys) en logs, archivos del repo, metadata de la VM ni en el chat. Los secretos van en Secret Manager o los ingreso yo directamente.
4. **No hagas por mí:** vincular facturación, iniciar sesión en Claude/Codex/GitHub, generar auth keys de Tailscale, ni pegar el link de pareo en mi Orca. Detente, dime el comando o paso y espera mi confirmación.
5. **Nada expuesto a internet:** sin reglas de ingreso públicas. El acceso es solo Tailscale y SSH por IAP.
6. **Verifica en la documentación oficial** antes de usar cualquier flag o URL: https://www.onorca.dev/docs/remote-servers y https://www.onorca.dev/docs/install. Los remote servers están en **beta**; si un comando difiere de este documento, manda la doc y avísame.
7. Si algo falla, muestra el error real y propone la causa más probable. No reintentes en bucle.

## 3. Arquitectura objetivo

```
Mi Mac (Orca desktop, cliente) ──Tailscale──► VM orca-<cliente> (orca-ide serve, servicio systemd de usuario)
                                              ├─ usuario `orca` SIN sudo
                                              ├─ Claude Code / Codex / git / gh instalados en la VM
                                              ├─ credenciales propias del cliente (nunca las de mi Mac)
                                              └─ repos en ~orca/projects
```

Decisiones ya tomadas:
- Dos usuarios: un admin con sudo (acceso solo por IAP) y `orca` sin sudo, porque los agentes ejecutan comandos arbitrarios.
- Tailscale con ACL por tag (`tag:orca-<cliente>`), visible solo desde mi Mac.
- Etiqueta `cliente=<slug>` en VM y disco para ver costos en facturación.
- En Linux la CLI se llama **`orca-ide`** (no `orca`).
- Orca se instala desde el `.deb` de GitHub Releases, con la **misma versión que mi Mac**. No uses auto-update; la versión va fijada por variable.
- No clonar la VM con machine image (se copiaría identidad de Tailscale y grants de Orca). Cada cliente se crea desde el script.

## 4. Fases

### Fase 0: Diagnóstico (solo lectura)
- `gcloud config list`, `gcloud billing projects describe bove-orca`, `gcloud services list --enabled`.
- Confirma qué versión de Orca tengo en mi Mac (pregúntame) y cuál es la última estable en GitHub Releases.
- Reporta el estado y qué falta de mi parte. Sin cambios.

### Fase 1: Base del proyecto (tras mi confirmación)
- Con la facturación ya vinculada por mí: habilitar `compute`, `iap`, `secretmanager`.
- Red: usa una VPC dedicada `orca-vpc` (o elimina `default-allow-ssh` público de la red default). Regla de ingreso **solo** para `35.235.240.0/20` en `tcp:22` (IAP) hacia el tag `orca`. Sin otras reglas de ingreso.
- VM con IP externa efímera (necesita salida a internet). Alternativa a evaluar con costo: sin IP externa + Cloud NAT.
- Cuenta de servicio dedicada para las VMs con permisos mínimos (leer solo el secreto de ese cliente en Secret Manager).

### Fase 2: Script de aprovisionamiento por cliente
Entrega `scripts/create-client.sh <slug> [machine-type] [disk-gb]` que:
1. Crea la VM (`n4-standard-8` y 200 GB por defecto, zona `us-central1-a`, etiquetas `cliente=<slug>`, tag `orca`) con un **startup script** idempotente.
2. Crea el secreto `tailscale-authkey-<slug>` solo si no existe, y me indica cómo cargarlo yo (el valor no pasa por ti).
3. Adjunta la política de horario (ver Fase 4).

El startup script (`scripts/vm-startup.sh`) debe, de forma idempotente:
- Instalar `git`, `gh`, `curl`, `jq`, `build-essential`, Node LTS.
- Crear el usuario `orca` sin sudo y ejecutar `loginctl enable-linger orca`.
- Instalar Tailscale y hacer `tailscale up --authkey=<desde Secret Manager> --hostname=orca-<slug> --advertise-tags=tag:orca-<slug>`.
- Instalar Orca (`.deb` de la versión fijada por variable `ORCA_VERSION`) y verificar checksum si GitHub lo publica.
- Instalar Claude Code como usuario `orca`.
- Registrar el servicio: `orca-ide serve service install --port 6768` (como `orca`), y dejarlo habilitado.
- Registrar en un log local qué pasos terminaron, sin secretos.

### Fase 3: Pasos manuales guiados (yo los hago, tú me guías)
Genera un archivo `docs/pasos-manuales.md` con la lista exacta, en orden:
1. Generar la auth key de Tailscale (con tag y expiración corta) y cargarla en Secret Manager.
2. Entrar por `gcloud compute ssh --tunnel-through-iap` y, como usuario `orca`: `orca-ide account add --agent claude` (y `codex` si aplica), `gh auth login` con un token fine-grained limitado a los repos de ese cliente.
3. Parear: detener el servicio, correr `orca-ide serve --port 6768 --pairing-address <IP-Tailscale>` una vez, copiar el link en **Settings → Remote Orca Servers → Add Server** de mi Mac, Ctrl-C, y volver a iniciar el servicio (el servicio no imprime el link).
4. Opcional: `--mobile-pairing` para el teléfono.
5. Clonar los repos del cliente en `~/projects` y agregarlos como proyectos en Orca.

### Fase 4: Costos y respaldo
- `instance-schedule` con encendido 08:00 y apagado 21:00 lun-vie, zona `America/Santiago` (parametrizable por cliente).
- Snapshot schedule diario del disco con retención de 7 días.
- Opcional (pregúntame antes): script de auto-apagado por inactividad que revise sesiones de Orca, procesos de agente y conexiones Tailscale activas durante N minutos y ejecute `shutdown`.
- Un presupuesto en la cuenta de facturación con alerta al 50/80/100 % del monto que yo defina.

### Fase 5: Verificación (checklist que debes ejecutar y reportar)
- [ ] La VM no tiene puertos abiertos al público (revisa reglas y escanea desde fuera si es posible).
- [ ] `tailscale status` muestra la VM con su tag; la ACL limita el acceso a mi Mac.
- [ ] `orca-ide serve service status` = running y sobrevive a un reinicio de la VM.
- [ ] Desde mi Mac: el servidor aparece **Connected** y puedo crear un worktree en un repo de prueba.
- [ ] Un agente de Claude Code corre en la VM y sigue vivo al cerrar mi laptop.
- [ ] El usuario `orca` no puede ejecutar `sudo`.
- [ ] Las credenciales de la VM son del cliente y no hay nada de mi Mac.
- [ ] **Prueba crítica:** identifica qué comandos con autenticación se ejecutan hoy en mi Mac desde Conductor (CLIs con login, VPN, llavero, MFA) y clasifícalos: (a) reemplazables por credencial en la VM, (b) requieren login interactivo o MFA, (c) requieren algo que solo está en mi Mac. Propón un camino por caso (credenciales en la VM, SSH worktrees, o puente restringido por Tailscale) y los riesgos de cada uno.

## 5. Entregables

```
orca-gcp/
├─ README.md                  # resumen, arquitectura, cómo crear un cliente nuevo
├─ scripts/create-client.sh
├─ scripts/vm-startup.sh
├─ scripts/destroy-client.sh  # pide confirmación explícita; muestra qué borrará
├─ docs/pasos-manuales.md
├─ docs/verificacion.md       # checklist con resultados de la Fase 5
└─ docs/costos.md             # estimación por cliente: 24/7, horario y auto-apagado
```

Todos los scripts: `set -euo pipefail`, variables al inicio, idempotentes, modo `--dry-run`, sin secretos incrustados.

## 6. Criterios de aceptación

- Crear un cliente nuevo requiere un solo comando más los pasos manuales de la Fase 3.
- Ningún secreto aparece en el repo, en los logs ni en la metadata de la VM.
- La VM piloto pasa todo el checklist de la Fase 5.
- Dejas por escrito las incertidumbres abiertas (beta de Orca, compatibilidad de versión Mac-VM, comandos locales con autenticación) y qué dato falta para resolverlas.

## 7. Qué hacer primero

Empieza por la **Fase 0** y muéstrame el diagnóstico. No ejecutes nada de las fases siguientes sin mi confirmación.

> Nota: los IDs de cuentas de facturación se reemplazaron por placeholders porque este repositorio es público. El dueño los conoce y los indica en el chat cuando corresponda.
