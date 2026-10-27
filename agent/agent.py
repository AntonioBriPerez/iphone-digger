"""iPhone Digger agent: talks to iPhones via pymobiledevice3 and streams NDJSON events on stdout.

Commands arrive as JSON lines on stdin: {"cmd": "...", ...}. Every event is one JSON line with a "t" type.
"""

import asyncio
import base64
import dataclasses
import json
import logging
import os
import sys
import time

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.services.crash_reports import CrashReportsManager
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.services.os_trace import OsTraceService
from pymobiledevice3.usbmux import list_devices

logging.disable(logging.CRITICAL)  # stdout is the protocol channel; library logs would corrupt it
OUT = sys.stdout
PAGE = 16384  # arm64 iOS page size

# lockdown key -> label shown in the app
INFO_FIELDS = {
    "DeviceName": "Nombre", "ProductType": "Modelo", "ProductVersion": "iOS", "BuildVersion": "Build",
    "SerialNumber": "Número de serie", "ModelNumber": "Número de modelo", "HardwareModel": "Placa",
    "CPUArchitecture": "Arquitectura", "UniqueDeviceID": "UDID", "WiFiAddress": "MAC Wi-Fi",
    "BluetoothAddress": "MAC Bluetooth", "PhoneNumber": "Teléfono", "InternationalMobileEquipmentIdentity": "IMEI",
    "InternationalMobileEquipmentIdentity2": "IMEI 2", "BasebandVersion": "Firmware módem",
    "FirmwareVersion": "iBoot", "ActivationState": "Activación", "TimeZone": "Zona horaria", "RegionInfo": "Región",
}


# syslog level -> rank used by the app's level filter (Console's default level sits at 2)
LEVEL_RANK = {"DEBUG": 0, "INFO": 1, "NOTICE": 2, "USER_ACTION": 2, "ERROR": 3, "FAULT": 4}
# shared by every session so it survives device changes; set by the app with the log_filter command
LOG_FILTER = {"min_level": 0, "muted": set(), "only": ""}


def log_passes(proc, level):
    f = LOG_FILTER
    return LEVEL_RANK.get(level, 2) >= f["min_level"] and proc not in f["muted"] and (not f["only"] or proc == f["only"])


def emit(t, **data):
    OUT.write(json.dumps({"t": t, **data}, default=str) + "\n")
    OUT.flush()


def err(where, e):
    emit("error", where=where, msg=f"{type(e).__name__}: {e}")


class Session:
    """Everything streamed for one device; cancelled as a whole when the device leaves or is deselected."""

    def __init__(self, udid):
        self.udid = udid
        self.ld = None
        self.dvt = None
        self.live_screen = False
        self.tasks = []

    async def start(self):
        self.ld = await create_using_usbmux(serial=self.udid)
        for coro in (self.info(), self.battery_loop(), self.syslog_loop(), self.dev_loop(), self.screen_loop()):
            self.tasks.append(asyncio.create_task(coro))

    async def connect(self):
        """Dedicated lockdown connection: concurrent service starts on one shared client get their replies mixed up."""
        return await create_using_usbmux(serial=self.udid)

    def stop(self):
        for t in self.tasks:
            t.cancel()

    async def info(self):
        v = await self.ld.get_value()
        du = {}
        try:
            du = await self.ld.get_value(domain="com.apple.disk_usage")
        except Exception as e:
            err("storage", e)
        try:
            dev_mode = await self.ld.get_developer_mode_status()
        except Exception:
            dev_mode = None
        emit("info", udid=self.udid, name=v.get("DeviceName", ""), model=v.get("ProductType", ""),
             ios=v.get("ProductVersion", ""), storage_total=du.get("TotalDiskCapacity") or 0,
             storage_free=du.get("AmountDataAvailable") or du.get("TotalDataAvailable") or 0, developer_mode=dev_mode,
             fields=[[label, str(v[k])] for k, label in INFO_FIELDS.items() if v.get(k) not in (None, "")])

    async def battery_loop(self):
        diag = DiagnosticsService(lockdown=await self.connect())
        while True:
            try:
                b = await diag.get_battery() or {}
                bd = b.get("BatteryData", {})
                pt = b.get("PowerTelemetryData", {})
                emit("battery",
                     level=b.get("CurrentCapacity"), charging=b.get("IsCharging"), external=b.get("ExternalConnected"),
                     fully_charged=b.get("FullyCharged"), cycles=b.get("CycleCount"), voltage_mv=b.get("Voltage"),
                     amperage_ma=b.get("InstantAmperage"), temp_c=(b.get("Temperature") or bd.get("Temperature") or 0) / 100 or None,
                     design_mah=bd.get("DesignCapacity"), max_mah=bd.get("NominalChargeCapacity") or bd.get("AppleRawMaxCapacity"),
                     remaining_mah=bd.get("RemainingCapacity"), time_to_empty_min=b.get("AvgTimeToEmpty"),
                     system_load_mw=pt.get("SystemLoad"), power_in_mw=pt.get("SystemPowerIn"), battery_power_mw=pt.get("BatteryPower"))
            except Exception as e:
                err("battery", e)
            await asyncio.sleep(2)

    async def syslog_loop(self):
        batch, dropped, seen, last = [], 0, 0, time.monotonic()
        while True:
            try:
                async with await self.connect() as ld:
                    async for e in OsTraceService(lockdown=ld).syslog():
                        seen += 1
                        proc = os.path.basename(e.filename)
                        if log_passes(proc, e.level.name):
                            if len(batch) < 400:  # firehose cap per flush; the UI only keeps a window anyway
                                batch.append({"ts": e.timestamp.strftime("%H:%M:%S.%f")[:-3], "pid": e.pid, "proc": proc,
                                              "level": e.level.name, "msg": e.message,
                                              "sub": e.label.subsystem if e.label else "", "cat": e.label.category if e.label else ""})
                            else:
                                dropped += 1
                        if (elapsed := time.monotonic() - last) > 0.5:
                            emit("logs", items=batch, dropped=dropped, rate=round(seen / elapsed))
                            batch, dropped, seen, last = [], 0, 0, time.monotonic()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                err("syslog", e)
                await asyncio.sleep(3)

    async def dev_loop(self):
        """Developer services (CPU, memory, processes, screen) over the iOS 17+ no-root tunnel."""
        mounted = False
        while True:
            try:
                rsd = await userspace_tunnel.establish_userspace_rsd(serial=self.udid)
                async with DvtProvider(rsd) as dvt:
                    self.dvt = dvt
                    emit("dev", status="ok")
                    await self.sysmon(dvt)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self.dvt = None
                emit("dev", status="unavailable", msg=f"{type(e).__name__}: {e}")
                if not mounted:
                    mounted = True
                    try:  # DVT needs the Developer Disk Image; it stays mounted until the phone reboots
                        await auto_mount(await self.connect())
                        continue
                    except Exception as me:
                        emit("dev", status="unavailable", msg=f"No se pudo montar la imagen de desarrollador: {me}")
                await asyncio.sleep(10)

    async def sysmon(self, dvt):
        sm = await Sysmontap.create(dvt, interval=1000)
        prev = None
        async with sm:
            async for row in sm:
                if not isinstance(row, dict):
                    continue
                if "System" in row:
                    s = dataclasses.asdict(sm.system_attributes_cls(*row["System"]))
                    per = [c.get("CPU_TotalLoad", 0) for c in row.get("PerCPUUsage", [])]
                    now = time.monotonic()
                    rates = {}
                    if prev:
                        dt = now - prev[0]
                        for k in ("netBytesIn", "netBytesOut", "diskBytesRead", "diskBytesWritten"):
                            rates[k] = max(0, (s.get(k, 0) - prev[1].get(k, 0)) / dt)
                    prev = (now, s)
                    emit("system", cpu=sum(per) / len(per) if per else None, per_cpu=per,
                         mem_total=s.get("physMemSize", 0) * PAGE,
                         mem_used=(s.get("vmActiveCount", 0) + s.get("vmWireCount", 0) + s.get("vmCompressorPageCount", 0)) * PAGE,
                         mem_free=s.get("vmFreeCount", 0) * PAGE, threads=s.get("threadCount"), rates=rates)
                if "Processes" in row:
                    procs = []
                    for pid, values in row["Processes"].items():
                        p = sm.process_attributes_cls(*values)
                        procs.append({"pid": pid, "name": p.name, "cpu": p.cpuUsage or 0, "mem": p.physFootprint or 0,
                                      "threads": p.threadCount, "power": p.avgPowerScore or 0,
                                      "disk_w": p.diskBytesWritten or 0})
                    emit("procs", items=procs)

    async def screen_loop(self):
        while True:
            if self.live_screen and self.dvt:
                await self.screenshot()
                await asyncio.sleep(0.3)
            else:
                await asyncio.sleep(0.5)

    async def screenshot(self):
        if not self.dvt:
            emit("error", where="screenshot", msg="Servicios de desarrollador no disponibles")
            return
        try:
            async with Screenshot(self.dvt) as s:
                emit("screenshot", png=base64.b64encode(await s.get_screenshot()).decode())
        except Exception as e:
            err("screenshot", e)

    async def apps(self):
        async with await self.connect() as ld:
            apps = await InstallationProxyService(lockdown=ld).get_apps(application_type="User", calculate_sizes=True)
        items = []
        for bid, a in apps.items():
            items.append({"bundle": bid, "name": a.get("CFBundleDisplayName") or a.get("CFBundleName") or bid,
                          "version": a.get("CFBundleShortVersionString"), "static": a.get("StaticDiskUsage", 0),
                          "dynamic": a.get("DynamicDiskUsage", 0), "background": a.get("UIBackgroundModes", []),
                          "permissions": sorted(k.removeprefix("NS").removesuffix("UsageDescription")
                                                for k in a if k.startswith("NS") and k.endswith("UsageDescription"))})
        emit("apps", items=items)

    async def crashes(self):
        async with await self.connect() as ld, CrashReportsManager(ld) as cr:
            emit("crashes", items=[p for p in await cr.ls("/", depth=-1) if "." in os.path.basename(p)])

    async def crash(self, path):
        async with await self.connect() as ld, CrashReportsManager(ld) as cr:
            emit("crash", path=path, text=(await cr.afc.get_file_contents(path)).decode(errors="replace"))


async def main():
    session = None
    known = None
    loop = asyncio.get_running_loop()

    async def switch(udid):
        nonlocal session
        if session:
            session.stop()
        session = Session(udid) if udid else None
        if session:
            try:
                await session.start()
            except Exception as e:
                err("connect", e)
                session = None

    async def watch_devices():
        nonlocal known
        while True:
            try:
                devs = [{"udid": d.serial, "conn": d.connection_type} for d in await list_devices()]
            except Exception as e:
                err("usbmux", e)
                devs = []
            if devs != known:
                known = devs
                emit("devices", items=devs)
                udids = [d["udid"] for d in devs]
                if session and session.udid not in udids:
                    await switch(None)
                if not session and udids:
                    await switch(udids[0])
            await asyncio.sleep(2)

    async def run(cmd):
        name = cmd.get("cmd")
        try:
            if name == "select":
                await switch(cmd["udid"])
            elif name == "log_filter":  # global, so it may arrive before any device is connected
                LOG_FILTER.update(min_level=int(cmd.get("min_level", 0)), muted=set(cmd.get("muted", [])), only=cmd.get("only", ""))
            elif not session:
                emit("error", where=name, msg="No hay iPhone conectado")
            elif name == "apps":
                await session.apps()
            elif name == "crashes":
                await session.crashes()
            elif name == "crash":
                await session.crash(cmd["path"])
            elif name == "screenshot":
                await session.screenshot()
            elif name == "live_screen":
                session.live_screen = bool(cmd.get("on"))
        except Exception as e:
            err(name, e)

    running = set()  # the event loop only keeps weak refs to tasks; unreferenced ones get collected mid-flight

    def spawn(coro):
        task = asyncio.create_task(coro)
        running.add(task)
        task.add_done_callback(running.discard)

    spawn(watch_devices())
    emit("hello", version=1)
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:  # app closed the pipe
            break
        try:
            spawn(run(json.loads(line)))
        except json.JSONDecodeError:
            pass
    if session:
        session.stop()


if __name__ == "__main__":
    asyncio.run(main())
