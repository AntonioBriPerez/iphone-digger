<p align="center"><img src="docs/icon.png" width="128" alt="iPhone Digger"></p>

<h1 align="center">iPhone Digger</h1>

<p align="center">
Panel de observabilidad en vivo para iPhone, nativo para macOS.<br>
Conecta un iPhone por cable y mira lo que pasa dentro: batería, CPU, memoria, procesos, red por app, pantalla, apps, archivos, seguridad, ubicación, logs y fallos.
</p>

<p align="center"><img src="docs/screenshots/overview.png" alt="Resumen" width="820"></p>

> *English:* native macOS (SwiftUI) dashboard that streams live data from any USB-connected iPhone — battery health, power draw and history, CPU/memory/network, every process, which app talks to which server (plus pcap capture), screen mirroring and recording, installed apps with sizes and declared permissions, app file sharing, a security check (MDM, profiles, sideloaded and VPN-capable apps), GPS location simulation, the live system log and explained crash reports with notifications. Built on [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). UI in Spanish.

## Qué muestra

| Sección | Datos | Requiere modo desarrollador |
|---|---|:-:|
| **Resumen** | Modelo, iOS, número de serie, IMEI, MACs, almacenamiento, batería (nivel, salud real en mAh, ciclos, voltaje, amperaje), consumo del sistema en vatios | No |
| **Rendimiento** | Gráficas en vivo de CPU, memoria, red, consumo y carga por núcleo. «Grabar sesión» guarda todo cada segundo y lo exporta a CSV | Sí |
| **Batería** | Historial guardado en el Mac (un punto cada 30 s, 30 días): nivel, consumo en vatios, ratos con corriente, gasto por hora sin cargador y qué proceso gastaba más en cada momento | No¹ |
| **Procesos** | Todos los procesos (≈600) con CPU, memoria, energía, escrituras a disco e hilos; ordenables y filtrables | Sí |
| **Red** | Qué app habla con qué servidor: dominio (sacado de las propias consultas DNS o, si no, del DNS inverso), IP, puertos y bytes enviados y recibidos, con ranking por app. «Capturar .pcap» guarda todo el tráfico para abrirlo en Wireshark | No |
| **Pantalla** | Captura de la pantalla o espejo en vivo, guardar en PNG y grabar vídeo `.mp4` (HEVC, 1-2 fotogramas por segundo) | Sí |
| **Apps** | Apps instaladas con tamaño (binario + datos), permisos que declaran y modos de segundo plano | No |
| **Archivos** | Carpeta Documentos de las apps que comparten archivos (VLC, Pages, Obsidian…): navegar, subir (también arrastrando desde Finder), descargar y eliminar | No |
| **Seguridad** | Revisión en un vistazo: supervisión/MDM, perfiles de configuración instalados, apps fuera del App Store y apps que pueden crear VPN, filtros de contenido o proxies DNS | No |
| **Ubicación** | Mueve el GPS del iPhone a cualquier punto del mapa o lugar buscado; vuelve a la real con un botón o al cerrar la app | Sí |
| **Logs en vivo** | El log del sistema en tiempo real con nivel por colores, filtro de nivel (por defecto oculta info y depuración), búsqueda con resaltado, ranking de procesos que más escriben (pulsa para ver solo uno o siléncialo), pausa sin perder líneas, detalle de cada línea con subsistema y exportación a `.log` | No |
| **Fallos** | Informes de fallos (`.ips`) clasificados (cierre, falta de memoria, CPU, disco, bloqueo…) con el motivo explicado en castellano, ranking de los procesos que más fallan y **notificación de macOS** cuando aparece uno nuevo (como mucho una por proceso cada 6 horas) | No |

¹ El proceso que más gasta sale de Procesos, que sí necesita el modo desarrollador. Por cable el iPhone casi siempre está cargando; para medir la descarga real, conéctalo por Wi-Fi (Finder › «Mostrar este iPhone cuando esté conectado a una red Wi-Fi»). iOS 27 ya no informa de la temperatura de la batería.

**Modo privado** (botón del ojo o ⇧⌘P): oculta el nombre del dispositivo, número de serie, UDID, IMEI, teléfono y MACs para poder compartir capturas.

Funciona con **cualquier iPhone** emparejado con el Mac. Con varios conectados aparece un selector en la barra de herramientas.

<p align="center">
<img src="docs/screenshots/performance.png" alt="Rendimiento" width="410">
<img src="docs/screenshots/processes.png" alt="Procesos" width="410">
</p>

## Requisitos

- macOS 14 o superior (Apple Silicon o Intel)
- Xcode 15 o superior para compilar
- Python 3.10 o superior
- Un iPhone conectado por cable, desbloqueado y con «Confiar en este ordenador» aceptado

Para **Rendimiento, Procesos, Pantalla y Ubicación** el iPhone debe tener activado el **modo desarrollador** (Ajustes › Privacidad y seguridad › Modo de desarrollador; el iPhone se reinicia). Si no aparece la opción, conecta el iPhone con Xcode abierto una vez, o ejecuta `pymobiledevice3 amfi reveal-developer-mode`. La app monta sola la imagen de desarrollador (DDI) la primera vez; para ello se descarga de internet y se firma para tu dispositivo.

## Instalación

```bash
git clone https://github.com/AntonioBriPerez/iphone-digger.git
cd iphone-digger
./setup.sh                      # instala pymobiledevice3 en un entorno propio
open iPhoneDigger.xcodeproj     # y pulsa ⌘R
```

O desde terminal:

```bash
xcodebuild -project iPhoneDigger.xcodeproj -scheme iPhoneDigger -configuration Release -derivedDataPath build build
open "build/Build/Products/Release/iPhone Digger.app"
```

Si ya tienes pymobiledevice3 instalado con `pipx`, la app lo encuentra sin ejecutar `setup.sh`. También puedes indicar otro intérprete con la variable `IPHONE_DIGGER_PYTHON`.

Atajos de lanzamiento útiles:

```bash
open "iPhone Digger.app" --args -page logs -privacy YES   # abre en una sección y con modo privado
```

Valores de `-page`: `overview`, `performance`, `battery`, `processes`, `network`, `screen`, `apps`, `files`, `security`, `location`, `logs`, `crashes`.

## Cómo funciona

La interfaz es SwiftUI nativa. Para hablar con el iPhone usa un pequeño agente en Python ([`agent/agent.py`](agent/agent.py)) basado en pymobiledevice3, que la app lanza como proceso hijo y con el que se comunica por JSON línea a línea. Apple no ofrece una API pública para esto, y pymobiledevice3 es la única implementación abierta que cubre el túnel de iOS 17+ y los servicios de Instruments. Los detalles están en [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

No hace falta `sudo`. En iOS 17+ el túnel hacia el dispositivo se establece en espacio de usuario.

## Privacidad

Todo ocurre en tu Mac: la app no envía nada a ningún servidor. Las únicas conexiones a internet son la descarga de la imagen de desarrollador de Apple cuando hace falta, el mapa y el buscador de Ubicación (Apple Maps) y las consultas de DNS inverso de la página Red, que van al DNS que use tu Mac. El historial de batería se guarda en `~/Library/Application Support/iPhoneDigger/`. Los logs, los informes de fallos y las capturas `.pcap` pueden contener datos personales, así que revísalos antes de compartirlos. El modo privado también oculta los nombres de los perfiles de configuración, que a menudo incluyen tu nombre o DNI.

## Desarrollo

- `project.yml` es la fuente del proyecto de Xcode ([XcodeGen](https://github.com/yonaskolb/XcodeGen)): tras añadir archivos, ejecuta `xcodegen generate`.
- El icono se genera con `swift tools/make-icon.swift`.
- El agente se puede probar sin la app: `python3 agent/agent.py` y escribir comandos como `{"cmd":"apps"}`.
- `python3 agent/test_agent.py` comprueba el análisis de paquetes y DNS de la página Red.

## Licencia

[MIT](LICENSE)
