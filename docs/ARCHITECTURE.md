# Arquitectura

```
┌──────────────────── macOS ────────────────────┐        ┌──────── iPhone ────────┐
│                                               │  USB   │                        │
│  iPhone Digger.app (SwiftUI)                  │ ─────► │ lockdownd              │
│   ├─ Agent.swift  ── stdin: comandos JSON ──┐ │        │  ├ diagnostics_relay   │
│   │               ◄─ stdout: eventos JSON ─┐│ │        │  ├ installation_proxy  │
│   └─ Vistas (Resumen, Rendimiento, …)      ││ │        │  ├ os_trace_relay      │
│                                            ││ │        │  ├ crashreportcopymob. │
│                                            ││ │        │  ├ pcapd, house_arrest │
│                                            ││ │        │  ├ mobile_config       │
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
| `net` | — | Empieza a analizar el tráfico por app (se queda activo toda la sesión) y emite `net` cada 2 s |
| `pcap` | `path` | Guarda todo el tráfico en un `.pcapng` en `path`; con `path` vacío para la captura |
| `location` | `lat`, `lon` | Simula la posición GPS; sin coordenadas vuelve a la real. Responde `location` |
| `security` | — | Responde `security` |
| `files` | `bundle`, `op`, `path`, `local` | Carpeta Documents de una app con File Sharing. `op`: `ls`, `pull` (copia `path` a la carpeta local `local`), `push` (copia `local` a la carpeta `path`) o `rm`. Responde `files` con el listado de la carpeta |

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
| `apps`, `crash`, `screenshot` | bajo demanda | ver comandos; `apps` incluye `sharing` (File Sharing) |
| `crashes` | bajo demanda y cada 60 s si cambia la lista | `items` (rutas). La app avisa con una notificación de los nuevos |
| `net` | cada 2 s tras `net` | `items[{proc, ip, host, ports, rx, tx, packets, last}]`, los 500 destinos con más tráfico |
| `pcap` | al empezar, cada 25 paquetes y al parar | `on`, `packets`, `path` |
| `location` | tras `location` | `lat`, `lon` (nulos = ubicación real) |
| `security` | bajo demanda | `supervised`, `profiles[{id, name, removable, active}]`, `sideloaded` y `traffic` (`[{name, bundle, detail}]`) |
| `files` | tras `files` | `bundle`, `dir`, `items[{name, dir, size, mtime}]`, `msg` |
| `error` | cuando ocurre | `where`, `msg` |

El syslog genera miles de líneas por segundo. El agente envía como mucho 400 líneas cada medio segundo e informa de cuántas descarta en `dropped`. Para no perder nada de un proceso concreto, usa `log_filter`.

## Detalles

- Cada servicio abre su propia conexión lockdown y cada comando corre en su propia tarea asyncio, con una referencia guardada para que el recolector de basura no la cierre a mitad de ejecución.
- La CPU se calcula como la media de `CPU_TotalLoad` por núcleo de sysmontap. La memoria «usada» es (activa + cableada + comprimida) × 16 KB.
- La salud de la batería es `NominalChargeCapacity / DesignCapacity`, el mismo dato que muestra Ajustes.
- El tráfico de red incluye el de la propia conexión USB con la app (capturas y logs).
- La página Red sale de `pcapd`, que etiqueta cada paquete con su proceso (`ecomm`, el proceso para el que trabaja un daemon como `nsurlsessiond`). El monitor de red de Instruments no sirve: en iOS 27 devuelve `pid -2` en todas las conexiones. El extremo remoto se decide por el puerto (el servidor tiene el bajo) porque el campo de dirección de `pcapd` no es fiable. Los nombres salen de las respuestas DNS que pasan por el cable y, si no, del DNS inverso.
- La ubicación simulada dura lo que dura el canal DVT abierto; la app la quita al cerrarse.
- Seguridad: una app está «fuera del App Store» si su `SignerIdentity` no es la de Apple; «puede desviar tráfico» si declara `networkextension` o `vpn.api`.
- El historial de batería y la grabación de rendimiento los guarda la app (no el agente) en CSV.
