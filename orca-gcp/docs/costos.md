# Costos por cliente (us-central1)

Estimación mensual, en USD, de **una VM de cliente**: `n4-standard-8` (8 vCPU, 32 GB) + disco Hyperdisk Balanced de 200 GB + IP externa efímera + snapshots diarios (retención 7 días).
Fecha de la estimación: **2026-11-09**. Son valores de lista (on-demand), sin descuentos por uso comprometido, impuestos ni créditos. Verifica con la [calculadora de precios](https://cloud.google.com/products/calculator) antes de comprometer un presupuesto.

## Precios usados y fuentes

| Concepto | Precio | Fuente (consultada 2026-11-09) |
|---|---|---|
| `n4-standard-8`, on-demand, us-central1 | **$0.3628 / hora** (≈ $264.84 por 730 h) | [gcloud-compute.com/n4-standard-8](https://gcloud-compute.com/n4-standard-8.html) (agregador, "Last Update: Sun Nov 8 2026"). **No es fuente oficial**: la página oficial [Compute Engine pricing](https://cloud.google.com/compute/all-pricing) no entrega las tablas sin JavaScript. Coincide con otros agregadores ([holori](https://calculator.holori.com/gcp/vm/n4-standard-8), [economize](https://www.economize.cloud/resources/gcp/pricing/compute-engine/n4-standard-8/)), que listan ≈ $0.3628/h. |
| Hyperdisk Balanced, espacio | **$0.000109589 / GiB-hora** = $0.08 / GiB-mes | [Disk and image pricing](https://cloud.google.com/compute/disks-image-pricing) (oficial) |
| Hyperdisk Balanced, IOPS aprovisionados sobre 3.000 | $0.000006849 / hora = **$0.005 / IOPS-mes** | ídem |
| Hyperdisk Balanced, throughput aprovisionado sobre 140 MiB/s | $0.000054795 / hora = **$0.04 / MiB/s-mes** | ídem |
| Snapshot estándar **regional** us-central1 | **$0.05 / GiB-mes** (el multi-regional `us` cuesta ≈ $0.083) | ídem (sección *Regional standard snapshots*) |
| IP externa efímera en uso, VM estándar | **$0.005 / hora** (solo mientras la VM corre) | [Network pricing](https://cloud.google.com/vpc/network-pricing) (oficial) |
| Egreso a internet | primeros **200 GiB/mes gratis** por cuenta | ídem |
| Cloud NAT (público) | **$0.0014 / hora por VM** + **$0.005 / hora por IP de la pasarela** + **$0.045 / GiB** procesado | [Cloud NAT pricing](https://cloud.google.com/nat/pricing) (oficial) |
| IOPS/throughput por defecto de un disco de 200 GiB | 4.200 IOPS y 440 MiB/s (fórmulas `6x+3000` y `min(2400, 1.5x+140)`); gratis solo 3.000 IOPS y 140 MiB/s | [Hyperdisk Balanced](https://docs.cloud.google.com/compute/docs/disks/hd-types/hyperdisk-balanced) (oficial) |

> **Estado actual (2026-11-11):** `orca-cliente-a` corre 24/7 (escenario A); el horario se quitó a propósito. `schedule-client.sh` lo crea solo con `--auto-shutdown`. Los escenarios B y C siguen como referencia.

Supuestos de cálculo: mes = 730 h; días hábiles por mes = 260/12 ≈ 21,67; el disco y los snapshots se cobran **siempre**, aunque la VM esté apagada; una IP efímera solo se cobra mientras la VM corre.

### Hallazgo: el disco por defecto cuesta más del doble

Si el disco se crea sin indicar IOPS/throughput, GCP aprovisiona 4.200 IOPS y 440 MiB/s, y cobra el exceso sobre la base gratuita:

- Espacio: 200 × $0.08 = **$16.00**
- IOPS extra: (4.200 − 3.000) × $0.005 = **$6.00**
- Throughput extra: (440 − 140) × $0.04 = **$12.00**
- **Total por defecto: $34.00/mes** frente a **$16.00/mes** fijando 3.000 IOPS y 140 MiB/s.

Para una VM de desarrollo no hace falta más. **TODO para el workspace 1** (dueño de `create-client.sh`): crear el disco con `provisioned-iops=3000,provisioned-throughput=140` (p. ej. en `--create-disk=...`). Ahorra $18/mes por cliente. Esta tabla muestra ambos casos.

### Snapshots

Los snapshots son incrementales y comprimidos. Con retención de 7 días, el espacio es ≈ datos usados + cambios de 7 días. Supuesto: 60 GB usados y ~5 % de cambio diario → ≈ 80–100 GB facturables → **≈ $4–5/mes**. Cota superior: 200 GB completos + incrementos ≈ $10–12. En las tablas uso **$5**.
`schedule-client.sh` fija `--storage-location=us-central1` (regional). Sin ese flag, GCP elige una ubicación "cercana", que puede ser multi-regional y ≈ 66 % más cara.

## Escenarios

| Concepto | A. 24/7 (730 h) | B. Horario 08–21 lun–vie (13 h × 21,67 d ≈ 282 h) | C. Auto-apagado por inactividad (6 h × 21,67 d ≈ 130 h) |
|---|---:|---:|---:|
| VM `n4-standard-8` | $264.84 | $102.19 | $47.16 |
| IP externa efímera | $3.65 | $1.41 | $0.65 |
| Disco 200 GB, **3.000 IOPS / 140 MiB/s** | $16.00 | $16.00 | $16.00 |
| Snapshots (supuesto) | $5.00 | $5.00 | $5.00 |
| **Total/mes (disco optimizado)** | **≈ $289** | **≈ $125** | **≈ $69** |
| Total/mes con disco por defecto (4.200 IOPS / 440 MiB/s) | ≈ $307 | ≈ $143 | ≈ $87 |

Notas:

- **B** es lo que implementa `schedule-client.sh` (≈ 57 % menos que 24/7). Incluye fines de semana apagados; el instance-schedule no considera feriados.
- **C** supone que la VM solo corre las horas con uso real (6 h por día hábil) y que algo la enciende (el horario de las 08:00 o a mano). En la práctica habrá además el tiempo de espera antes de apagar (p. ej. +30 min/día ≈ +$4/mes). Los agentes de larga duración que corren de noche cuentan como actividad y mantienen la VM encendida.
- Egreso: git, APIs de Anthropic/OpenAI y Tailscale caben en los 200 GiB gratuitos; no se incluye.
- Claude Code / Codex se pagan aparte (suscripción o API del cliente); no están en esta tabla.
- Cada VM extra de cliente repite estos totales; los costos se separan con la etiqueta `cliente=<slug>` en facturación.

## Alternativa: sin IP externa + Cloud NAT

La VM no tendría IP pública (la salida a internet va por Cloud NAT) y el SSH por IAP sigue funcionando sin IP externa. No cambia la superficie de ataque entrante (ya es nula por reglas de firewall), pero reduce la exposición accidental si alguien agrega una regla.

Costo con **un NAT por cliente** (escenario B, 20 GiB/mes procesados):

| Concepto | Con IP efímera | Con Cloud NAT dedicado |
|---|---:|---:|
| IP efímera de la VM | $1.41 | $0 |
| Pasarela NAT: $0.0014 × 282 h | – | $0.39 |
| IP de la pasarela: $0.005 × 730 h (supuesto: la IP está asignada todo el mes) | – | $3.65 |
| Datos procesados: 20 GiB × $0.045 | – | $0.90 |
| **Diferencia** | | **≈ +$3.50/mes por cliente** |

- Si los clientes **comparten una pasarela NAT** (una por región, hasta 32 VM por tarifa horaria), la IP de $3.65 se reparte y la diferencia baja a ≈ +$1/mes por cliente. Contra eso: una pasarela compartida mezcla la IP de salida de todos los clientes, y las VM comparten red (`orca-vpc`).
- Cloud NAT también cobra por cada GiB que atraviesa (también entrante respondiendo a salidas): un `npm install` o clonar repos grandes se nota ($0.045/GiB vs. gratis con IP propia).
- Riesgo operativo: con NAT, Tailscale puede quedar más veces en relay (DERP) en lugar de conexión directa, lo que sube la latencia del terminal remoto. Para un cliente que consume mucha banda, el costo y la latencia pueden pesar más que el beneficio.
- Requiere Cloud Router + NAT, recursos nuevos en la red que posee el workspace 0 (`bootstrap-project.sh`) o 1. **No lo implemento**; recomendación: mantener IP efímera para el piloto y evaluar NAT compartido cuando haya más de 2 clientes o una exigencia de seguridad concreta.

## Propuesta (sin implementar): auto-apagado por inactividad

> **Pendiente de tu confirmación.** No existe código; lo que sigue es solo el diseño. Dime si lo implemento, y con qué umbrales.

**Objetivo:** apagar la VM cuando nadie la usa, para acercarse al escenario C (≈ $69/mes) sin cortar trabajo real.

**Forma:** script `idle-shutdown.sh` instalado por `vm-startup.sh` como `systemd` timer (cada 5 min, como root vía unidad del sistema; ejecuta `systemctl poweroff` y no `shutdown -h` interactivo). Mantiene un archivo de estado en `/var/lib/orca-idle/` con la marca de tiempo de la última actividad y escribe en un log sin secretos. Un `poweroff` desde dentro deja la VM en estado `TERMINATED` (disco e IP efímera: la IP se libera; el disco sigue).

**Señales (cualquiera "activa" reinicia el reloj de inactividad):**

1. **Sesiones de Orca.** ¿Hay clientes conectados al puerto 6768? `ss -Htn state established '( sport = :6768 )'` (solo conteo; no registra IP ni tokens). Una sesión de terminal viva del daemon de Orca (el daemon mantiene sesiones aunque el cliente se desconecte): se cuenta como actividad **solo si** hay un proceso hijo ocupado (señal 2). *Incertidumbre:* la doc de Orca no describe una API de estado de sesiones; la CLI `orca-ide` podría tener `status`/`list`, por verificar (ver `docs/orca-notas-doc.md` del workspace 1).
2. **Procesos de agente.** Procesos del usuario `orca` llamados `claude`, `codex`, `node` (hijo de claude), `git`, `npm`, `cargo`, etc., con **CPU > ~2 %** acumulada en la ventana. Un agente esperando entrada del usuario sin consumir CPU no cuenta; uno compilando o ejecutando tests sí. Ventaja: capta el caso "cerré la laptop y el agente sigue trabajando".
3. **Conexiones Tailscale activas.** `tailscale status --json` → peers con `Active: true` y/o `LastHandshake` reciente (< 5 min), restringido al peer del Mac del dueño. Presencia de peers pasivos (conectados pero ociosos) **no** cuenta si no hay tráfico; se compara el contador de bytes de `tailscale status --json` (RxBytes/TxBytes) entre ejecuciones.
4. **Sesiones SSH/IAP del administrador.** `who`/`loginctl list-sessions` con usuarios reales: si el admin está dentro, no apagar.
5. **Carga general.** `loadavg(5m) > 0.5×nproc`: salvaguarda para trabajo que ninguna de las otras detecta.

**Regla:** si ninguna señal activa durante **N minutos consecutivos** (por defecto 45; configurable en `/etc/orca-idle.conf`), apagar. Aviso previo 5 min antes con `wall` / archivo en `/var/log`. Periodo de gracia de 20 min tras arrancar la VM (para que el dueño llegue). Archivo `/var/lib/orca-idle/disable` para suspender el auto-apagado (mantenimiento).

**Interacción con el horario:** el instance-schedule enciende a las 08:00 y apaga a las 21:00. El idle-shutdown solo puede apagar antes; no interfiere con el horario (el scheduler arranca/para en horas fijas; si la VM está apagada a las 21:00 el `stop` es inocuo). Para volver a encender durante el día: consola, `gcloud compute instances start orca-<slug>` o app móvil.

**Riesgos y mitigaciones:**

- Apagar con un agente "pensando" sin CPU (espera de red larga) → mitigar con CPU de proceso + ventana larga (45 min) y registrar cada decisión.
- Perder sesiones de terminal de Orca: al apagar se pierden los procesos; el repo en disco persiste. Debe documentarse para el cliente.
- Falsos positivos de actividad (un cron o `apt`) → ignorar procesos de root/sistema; solo usuario `orca`.
- Latencia de encendido: ≈ 1–2 min hasta que Tailscale reconecta; el Mac verá el servidor "Disconnected" hasta entonces.

**Qué necesito de ti para implementarlo:** (a) confirmar que quieres C; (b) minutos de inactividad (¿45?); (c) si el cliente debe poder reiniciar la VM solo (permiso `compute.instances.start` en su cuenta) o solo tú; (d) respuesta del workspace 1 sobre qué expone `orca-ide` para estado de sesiones.
