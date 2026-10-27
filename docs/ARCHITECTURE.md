# Arquitectura

```
┌──────────────────── macOS ────────────────────┐        ┌──────── iPhone ────────┐
│                                               │  USB   │                        │
│  iPhone Digger.app (SwiftUI)                  │ ─────► │ lockdownd              │
│   ├─ Agent.swift  ── stdin: comandos JSON ──┐ │        │  ├ diagnostics_relay   │
│   │               ◄─ stdout: eventos JSON ─┐│ │        │  ├ installation_proxy  │
│   └─ Vistas (Resumen, Rendimiento, …)      ││ │        │  ├ os_trace_relay      │
│                                            ││ │        │  ├ crashreportcopymob. │
│  agent.py (Python + pymobiledevice3) ◄─────┘│ │        │  └ CoreDeviceProxy ──┐ │
│   ├─ usbmuxd  (lista de dispositivos)        │ │        │     (túnel iOS 17+)  │ │
│   ├─ lockdown (info, batería, apps, logs…)  ◄┘ │        │  instruments (DVT) ◄─┘ │
│   └─ túnel userspace → DVT (CPU, procesos, pantalla)    │                        │
└───────────────────────────────────────────────┘        └────────────────────────┘
```

## Por qué un agente en Python

Apple no ofrece ninguna API pública de macOS para leer datos de un iPhone. Las alternativas son:

- **libimobiledevice** (C): cubre lockdown, pero no el túnel RemoteXPC de iOS 17+, así que no llega a Instruments (CPU, procesos ni pantalla).
- **pymobiledevice3** (Python): cubre todo, incluido un túnel en espacio de usuario que no necesita root.

La app nativa lanza `agent.py` como proceso hijo y no tiene sandbox, porque necesita acceder a `/var/run/usbmuxd` y lanzar procesos. Si el agente muere, la app lo relanza a los 2 segundos.

Python se busca, por este orden, en: `$IPHONE_DIGGER_PYTHON`, `~/Library/Application Support/iPhoneDigger/venv` (lo crea `setup.sh`) y las rutas habituales de una instalación de pymobiledevice3 con pipx.

## Protocolo

Una línea JSON por mensaje. Cada evento lleva su tipo en el campo `t`.

### Comandos (app → agente, por stdin)

| `cmd` | Campos | Efecto |
|---|---|---|
| `select` | `udid` | Cambia el dispositivo observado |
| `apps` | — | Responde `apps` (tarda unos 10–20 s porque calcula tamaños) |
| `crashes` | — | Responde `crashes` |
| `crash` | `path` | Responde `crash` con el contenido del informe |
| `screenshot` | — | Responde `screenshot` |
| `live_screen` | `on` | Activa o desactiva el envío continuo de capturas |
| `log_filter` | `min_level`, `muted`, `only` | Filtra el syslog en origen: nivel mínimo (0 depuración … 3 errores), procesos silenciados y, opcionalmente, un único proceso. Es global y sobrevive a los cambios de dispositivo |

### Eventos (agente → app, por stdout)

| `t` | Frecuencia | Contenido |
|---|---|---|
| `hello` | al arrancar | `version` |
| `devices` | cuando cambian | `items[{udid, conn}]` |
| `info` | al conectar | `name, model, ios, storage_total, storage_free, developer_mode, fields[[etiqueta, valor]]` |
| `battery` | cada 2 s | nivel, carga, ciclos, mAh de diseño/actuales, voltaje, amperaje, `system_load_mw`… |
| `dev` | al cambiar | `status` (`ok` o `unavailable`) y `msg` |
| `system` | cada 1 s | `cpu`, `per_cpu`, memoria y `rates` (bytes/s de red y disco) |
| `procs` | cada 1 s | `items[{pid, name, cpu, mem, threads, power, disk_w}]` |
| `logs` | cada 0,5 s | `items[{ts, pid, proc, level, msg, sub, cat}]`, `dropped` y `rate` (líneas/s que emite el iPhone) |
| `apps`, `crashes`, `crash`, `screenshot` | bajo demanda | ver comandos |
| `error` | cuando ocurre | `where`, `msg` |

El syslog genera miles de líneas por segundo. El agente envía como mucho 400 líneas cada medio segundo e informa de cuántas descarta en `dropped`. Para no perder nada de un proceso concreto, usa `log_filter`.

## Detalles

- Cada servicio abre su propia conexión lockdown y cada comando corre en su propia tarea asyncio, con una referencia guardada para que el recolector de basura no la cierre a mitad de ejecución.
- La CPU se calcula como la media de `CPU_TotalLoad` por núcleo de sysmontap. La memoria «usada» es (activa + cableada + comprimida) × 16 KB.
- La salud de la batería es `NominalChargeCapacity / DesignCapacity`, el mismo dato que muestra Ajustes.
- El tráfico de red incluye el de la propia conexión USB con la app (capturas y logs).
