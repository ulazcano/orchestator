# Diagnóstico Fase 0 (solo lectura)

Fecha: 2026-11-09 · Workspace 0 · No se hizo ningún cambio en GCP.
Este repo es público: no se incluyen IDs de facturación ni números de proyecto.

## 1. Estado real de GCP (`bove-orca`)

| Chequeo | Resultado |
|---------|-----------|
| Cuenta autenticada | cuenta del dueño (`gcloud auth login --no-launch-browser` en el sandbox) |
| Rol del dueño en el proyecto | `roles/owner` |
| `gcloud config` | **No hay proyecto por defecto** (`core/project` vacío). Todo comando debe llevar `--project` o usar `PROJECT_ID`. |
| Padre del proyecto / estado | organización · `ACTIVE` |
| Políticas de organización (legacy `org-policies list`) | 0 ítems |
| Facturación | **`billingEnabled: true`**: el dueño ya vinculó una cuenta. Esta fase no elige ni muestra cuál. |
| APIs habilitadas | BigQuery (varias), Dataform, Dataplex, Datastore, Cloud Storage, Logging, Monitoring, Trace, Telemetry, Service Management/Usage, Cloud SQL (component). |
| `compute.googleapis.com` | **No habilitada** (falló antes por falta de facturación; ahora debería funcionar). |
| `iap.googleapis.com` | **No habilitada** |
| `secretmanager.googleapis.com` | **No habilitada** |
| Redes / reglas de firewall | **No consultables**: Compute está deshabilitada. No hay VPC ni reglas todavía. |

Los comandos usados fueron: `gcloud config list`, `gcloud billing projects describe bove-orca`,
`gcloud services list --enabled --project bove-orca`, `gcloud compute networks list`,
`gcloud compute firewall-rules list`, `gcloud projects describe` y
`gcloud projects get-iam-policy` (filtrado al dueño). Los dos últimos de `compute` devolvieron
`SERVICE_DISABLED`, como se esperaba. Se respondió **N** a la oferta de habilitar la API.

## 2. Orca: versiones y artefactos

- **Mac del dueño:** v1.4.251.
- **Última estable en GitHub Releases (stablyai/orca):** v1.4.255 (2026-11-09, `prerelease: false`).
  Publican una release casi diaria (1.4.248 → 1.4.255 en 6 días).
- **Linux amd64:** sí publican `.deb` (`orca-ide_<ver>_amd64.deb`), además de `.rpm` (x86_64/aarch64),
  `.deb` arm64 y AppImage. El `.deb` de 1.4.251 existe, así que se puede fijar la misma versión del Mac.
- **Checksums:** no hay archivo `.sha256` suelto. Hay dos fuentes verificables:
  1. `latest-linux.yml` de cada release incluye `sha512` (base64) del `.deb`.
  2. La API de GitHub expone `digest: sha256:...` por asset (ej. 1.4.255 amd64.deb →
     `6df53f4f...4add5a`, 191 836 440 bytes).
  Ambas vienen del mismo release, así que protegen contra descargas corruptas, no contra un release
  comprometido. Para eso conviene fijar el sha256 por versión en el repo (decisión del workspace 1).
- **Auto-update:** el `.deb` solo avisa de actualizaciones; no se autoactualiza (compatible con la regla
  de versión fijada).

### Discrepancias con la spec (doc oficial, beta)

| Tema | Spec | Doc oficial |
|------|------|-------------|
| Nombre de la CLI en Linux | `orca-ide` | `/docs/install` dice `orca-ide`, pero `/docs/remote-servers` documenta todos los comandos como `orca serve ...` y `orca account add ...`. Probablemente es el mismo binario; **verificar en la VM piloto** (`command -v orca orca-ide`). |
| Puerto 6768 | "por defecto" implícito | La doc **no da puerto por defecto**; 6768 es solo un ejemplo. Siempre pasar `--port 6768`. |
| Servicio | `orca-ide serve service install --port 6768` | Coincide (con `orca serve`), instala unidad systemd de usuario y pide `loginctl enable-linger`. Usa `--no-pairing` internamente. |
| Pareo | `--pairing-address <IP-Tailscale>` | Coincide. No usar `127.0.0.1` ni wildcard. |
| `--supervise` | no mencionado | Existe; innecesario con systemd. |
| Alternativa de pareo | no mencionada | Desde la app de escritorio del servidor ("Advertise this app as a server"); no aplica a VM headless. |

Los remote servers están marcados **beta** en la doc.

## 3. Qué falta de parte del dueño

1. **Confirmar explícitamente** que arranque la Fase 1 (habilitar APIs, VPC, firewall, cuentas de servicio).
   Se ejecutará primero en `--dry-run` y solo se aplica lo que confirme.
2. Decidir la versión a fijar: **1.4.251** (igual que su Mac) o actualizar el Mac a la última.
3. Decidir el presupuesto y los umbrales (Fase 4; no la hace este workspace).
4. Generar él mismo la auth key de Tailscale y las ACL por tag (Fase 3).
5. Al terminar, ejecutar `gcloud auth revoke` en el sandbox (las credenciales quedan guardadas en `~/.config/gcloud`).

## 4. Riesgos y puntos abiertos

1. **Al habilitar Compute se crea la red `default`** (salvo que una política de organización lo impida;
   no hay ninguna visible) con reglas de ingreso públicas (`default-allow-ssh`, `default-allow-rdp`,
   `default-allow-icmp`, `default-allow-internal`). Las VMs irán en `orca-vpc`, así que no les afectan, pero
   incumplen el espíritu de la regla 5 de la spec. Propuesta: tras habilitar Compute, borrar esas reglas
   y la red `default` (acción separada, con confirmación).
2. **Sin proyecto por defecto en gcloud:** un comando sin `--project` fallaría o, peor, iría a otro proyecto.
   Los scripts deben pasar `--project "$PROJECT_ID"` siempre.
3. **Deriva de versión Mac ↔ VM:** el Mac está 4 releases atrás y salen versiones a diario. No se sabe si
   el protocolo de remote server tolera diferencias de versión (beta). Dato que falta: nota de
   compatibilidad de Orca o prueba cruzada en la VM piloto.
4. **Nombre de la CLI (`orca` vs `orca-ide`)** sin confirmar; el startup script debería detectar cuál existe.
5. **Cuotas y disponibilidad de `n4-standard-8` + Hyperdisk Balanced en `us-central1-a`:** no verificable
   hasta habilitar Compute (`gcloud compute regions describe us-central1`, `machine-types list`).
   Hyperdisk Balanced cobra IOPS/throughput aprovisionados además de GB; revisar en `costos.md`.
6. **Dueño con `roles/owner` operando desde un sandbox:** credenciales de alto privilegio en una máquina
   temporal. Mitigación: revocar al terminar y, para el trabajo diario, una cuenta con roles mínimos.
7. **SSH por IAP:** requiere `roles/iap.tunnelResourceAccessor` (el owner ya lo tiene). Si se usa OS Login,
   `roles/compute.osAdminLogin` para el usuario `admin`. Decisión pendiente del workspace 1.
8. **Tailscale no necesita ingreso:** solo salida (UDP 41641 / HTTPS vía DERP). Por eso la única regla de
   ingreso será IAP SSH.
9. **IP externa efímera** (necesaria para salida a internet) implica una IP pública en cada VM, aunque sin
   reglas de ingreso. Alternativa sin IP externa + Cloud NAT: ver `scripts/bootstrap-project.sh` (Fase 1).
10. **Repo público:** no incluir IDs de facturación, números de proyecto ni nombres de tailnet.

## 5. Actualización: Fase 1 aplicada (2026-11-09, con confirmación del dueño)

Se ejecutó `scripts/bootstrap-project.sh` por pasos (`apis`, `network`, `firewall`, `purge-default-network`).

| Recurso | Estado verificado |
|---------|-------------------|
| APIs `compute`, `iap`, `secretmanager` | habilitadas |
| VPC `orca-vpc` (custom) + `orca-subnet` 10.10.0.0/24, us-central1, Private Google Access | creadas |
| Regla `orca-allow-iap-ssh` (35.235.240.0/20, tcp:22, tag `orca`) | creada; **única regla de ingreso del proyecto** |
| Red `default` y sus 4 reglas públicas (SSH, RDP, ICMP, internal) | **borradas** (Compute las había creado al habilitarse) |
| Reejecución de `all` y `purge-default-network` | idempotente: omite lo existente |
| `client-sa <slug>` | **no aplicado**: exige que exista el secreto `tailscale-authkey-<slug>` (lo crea `create-client.sh`, ws1) |

Cuotas de us-central1 (solo lectura): zona `us-central1-a` UP, `n4-standard-8` disponible,
CPUS 0/200, IN_USE_ADDRESSES 0/8. La cuota específica de N4 y de Hyperdisk Balanced **no aparece**
en `regions describe`; queda por confirmar creando la VM piloto (si falla, revisar Quotas en consola).
