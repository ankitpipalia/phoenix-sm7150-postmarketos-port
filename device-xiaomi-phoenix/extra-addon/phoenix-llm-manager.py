#!/usr/bin/env python3
"""Phoenix Console: dependency-free device management plane for Xiaomi Phoenix.

One process serves a LAN dashboard covering the whole phone-as-server: system
and process view, systemd services, network, storage, thermal/frequency state,
the power path (battery, charger, USB-C, adapter tests), the journal, and the
single llama.cpp runtime it owns.  Everything heavy stays out of this process:
inference runs in llama-server, and all device data is read from /proc, /sys
and a few short-lived system commands.  It runs unprivileged, so mutations are
limited to the runtime it owns and to signalling its own user's processes.
"""

from __future__ import annotations

import collections
import dataclasses
import json
import os
import pwd
import re
import secrets
import signal
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


@dataclasses.dataclass(frozen=True)
class Config:
    bind_host: str = os.getenv("BIND_HOST", "0.0.0.0")
    manager_port: int = int(os.getenv("MANAGER_PORT", "7070"))
    api_token: str = os.getenv("API_TOKEN", "")
    model_path: Path = Path(os.getenv("MODEL_PATH", "/home/user/models/Spark-X2.5-1.7B-Q8_0.gguf"))
    llama_server: Path = Path(os.getenv("LLAMA_SERVER", "/home/user/opt/llama-spark-turboquant/bin/llama-server"))
    runtime_host: str = os.getenv("RUNTIME_HOST", "127.0.0.1")
    runtime_port: int = int(os.getenv("RUNTIME_PORT", "8080"))
    minimum_available_mib: int = int(os.getenv("MIN_AVAILABLE_MIB", "768"))
    startup_timeout: int = int(os.getenv("STARTUP_TIMEOUT_SECONDS", "180"))
    shutdown_timeout: int = int(os.getenv("SHUTDOWN_TIMEOUT_SECONDS", "20"))
    thermal_warn_c: float = float(os.getenv("THERMAL_WARN_C", "80"))
    thermal_critical_c: float = float(os.getenv("THERMAL_CRITICAL_C", "92"))
    log_path: Path = Path(os.getenv("LOG_PATH", "/var/lib/phoenix-llm/runtime.log"))
    state_path: Path = Path(os.getenv("STATE_PATH", "/var/lib/phoenix-llm/state.json"))
    # Inference is the heaviest load this phone sees, and the power-path tests
    # showed the cell supplying -58 mA under heavy load even with a good adapter.
    # Refuse to start it on battery, or on a cell already below a safe floor.
    require_external_power: bool = os.getenv("REQUIRE_EXTERNAL_POWER", "1") != "0"
    minimum_battery_uv: int = int(os.getenv("MIN_BATTERY_UV", "3700000"))
    log_max_bytes: int = int(os.getenv("LOG_MAX_BYTES", str(8 * 2**20)))
    history_points: int = int(os.getenv("HISTORY_POINTS", "720"))
    sample_seconds: float = float(os.getenv("SAMPLE_SECONDS", "5"))


CONFIG = Config()
STATIC_DIR = Path("/usr/share/phoenix-llm-manager")
POWER_ROOT = Path("/sys/class/power_supply")
THERMAL_ROOT = Path("/sys/class/thermal")


PROFILES: dict[str, dict[str, Any]] = {
    "spark-turbo4-128k": {
        "title": "Turbo4 128K",
        "description": "Full native context with true rotated TurboQuant 4-bit K/V cache; CPU/OpenBLAS.",
        "context": 131072,
        "threads": 4,
        "threads_batch": 8,
        "batch": 512,
        "ubatch": 128,
        "cache_k": "turbo4",
        "cache_v": "turbo4",
        "cache_ram": 128,
        "experimental": True,
    },
    "spark-q8-128k": {
        "title": "Validated Q8 128K",
        "description": "Previously allocation-validated full context; highest cache fidelity and highest RAM use.",
        "context": 131072,
        "threads": 4,
        "threads_batch": 8,
        "batch": 512,
        "ubatch": 128,
        "cache_k": "q8_0",
        "cache_v": "q8_0",
        "cache_ram": 128,
        "experimental": False,
    },
    "spark-fast-32k": {
        "title": "Fast 32K",
        "description": "Six CPU threads and smaller context for the best short-session throughput; watch thermals.",
        "context": 32768,
        "threads": 6,
        "threads_batch": 8,
        "batch": 512,
        "ubatch": 128,
        "cache_k": "q8_0",
        "cache_v": "q8_0",
        "cache_ram": 128,
        "experimental": False,
    },
}


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace").strip()
    except (OSError, ValueError):
        return None


def read_int(path: Path) -> int | None:
    value = read_text(path)
    try:
        return int(value) if value not in (None, "") else None
    except ValueError:
        return None


def meminfo() -> dict[str, Any]:
    values: dict[str, int] = {}
    text = read_text(Path("/proc/meminfo")) or ""
    for line in text.splitlines():
        key, _, raw = line.partition(":")
        try:
            values[key] = int(raw.strip().split()[0]) * 1024
        except (ValueError, IndexError):
            continue
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    swap_total = values.get("SwapTotal", 0)
    swap_free = values.get("SwapFree", 0)
    return {
        "total_bytes": total,
        "available_bytes": available,
        "used_bytes": max(0, total - available),
        "used_percent": round(100 * (total - available) / total, 1) if total else None,
        "swap_total_bytes": swap_total,
        "swap_used_bytes": max(0, swap_total - swap_free),
    }


def process_rss(pid: int) -> int | None:
    text = read_text(Path(f"/proc/{pid}/status")) or ""
    for line in text.splitlines():
        if line.startswith("VmRSS:"):
            try:
                return int(line.split()[1]) * 1024
            except (ValueError, IndexError):
                return None
    return None


def pid_command(pid: int) -> list[str]:
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0")[:-1]
    except OSError:
        return []


def service_state(unit: str) -> str:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", unit], capture_output=True, text=True,
            timeout=2, check=False,
        )
        return result.stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def historical_battery_report() -> str | None:
    reporter = Path("/usr/bin/phoenix-battery-report")
    if not reporter.is_file():
        return None
    try:
        result = subprocess.run(
            [str(reporter)], capture_output=True, text=True, timeout=5, check=False,
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def thermal_snapshot() -> dict[str, Any]:
    zones: list[dict[str, Any]] = []
    for path in sorted(THERMAL_ROOT.glob("thermal_zone*")):
        raw = read_int(path / "temp")
        if raw is None:
            continue
        temp_c = raw / 1000
        if not -40.0 <= temp_c <= 150.0:
            continue
        zones.append({"name": read_text(path / "type") or path.name, "temp_c": round(temp_c, 1)})
    hottest = max(zones, key=lambda item: item["temp_c"], default=None)
    return {"zones": zones, "hottest": hottest}


def selected_value(raw: str | None) -> str | None:
    if raw is None:
        return None
    start, end = raw.find("["), raw.find("]")
    return raw[start + 1:end] if start >= 0 and end > start else raw


def supply_named(prefix: str) -> Path | None:
    for path in POWER_ROOT.glob(prefix + "*"):
        return path
    return None


PLAUSIBLE_BATTERY_UV = (2_500_000, 4_800_000)


def plausible_voltage_uv(*candidates: Any) -> int | None:
    """First candidate inside the physical range for this cell, else None.

    QGauge's averaged channel reads a constant 6377865 for ~70 s after boot, so
    preferring voltage_avg blindly would report a 100% cell and a 6.4 V warning.
    """
    lo, hi = PLAUSIBLE_BATTERY_UV
    for value in candidates:
        if isinstance(value, int) and lo <= value <= hi:
            return value
    return None


def battery_preflight() -> None:
    charger = supply_named("pm8150b-charger")
    battery = supply_named("qcom_qg")
    if CONFIG.require_external_power:
        if charger is None or read_int(charger / "online") != 1:
            raise RuntimeError("external power is offline; refusing to start inference on battery")
    if battery is not None and CONFIG.minimum_battery_uv > 0:
        voltage = plausible_voltage_uv(read_int(battery / "voltage_avg"), read_int(battery / "voltage_now"))
        if voltage is None:
            raise RuntimeError("battery voltage is unavailable or implausible; refusing to start inference")
        if voltage < CONFIG.minimum_battery_uv:
            raise RuntimeError(
                f"battery at {voltage / 1e6:.3f} V is below the {CONFIG.minimum_battery_uv / 1e6:.2f} V floor"
            )


class BatterySampler:
    def __init__(self, start: bool = True) -> None:
        self.lock = threading.Lock()
        self.history: collections.deque[dict[str, Any]] = collections.deque(maxlen=CONFIG.history_points)
        self.started = time.monotonic()
        self.last_t: float | None = None
        self.last_current_ua: int | None = None
        self.last_voltage_uv: int | None = None
        self.charged_mah = 0.0
        self.discharged_mah = 0.0
        self.charged_mwh = 0.0
        self.discharged_mwh = 0.0
        if start:
            threading.Thread(target=self._loop, name="battery-sampler", daemon=True).start()

    @staticmethod
    def _supply(path: Path | None, fields: tuple[str, ...]) -> dict[str, Any]:
        if path is None:
            return {}
        result: dict[str, Any] = {"name": path.name}
        for field in fields:
            raw = read_text(path / field)
            if raw is None:
                continue
            try:
                result[field] = int(raw)
            except ValueError:
                result[field] = selected_value(raw) if field in {"charge_behaviour", "usb_type"} else raw
        return result

    def snapshot(self) -> dict[str, Any]:
        battery_path = supply_named("qcom_qg")
        charger_path = supply_named("pm8150b-charger")
        tcpm_path = supply_named("tcpm-source-psy")
        battery = self._supply(battery_path, (
            "status", "present", "capacity", "capacity_level", "health", "technology", "temp",
            "voltage_now", "voltage_avg", "voltage_ocv", "voltage_min_design",
            "voltage_max_design", "current_now", "current_avg", "charge_now",
            "charge_full", "charge_full_design", "cycle_count", "constant_charge_current_max",
            "manufacturer", "model_name", "serial_number", "scope",
        ))
        charger = self._supply(charger_path, (
            "online", "present", "status", "health", "usb_type", "voltage_now", "current_now",
            "current_max", "input_current_limit", "constant_charge_current",
            "constant_charge_current_max", "constant_charge_voltage",
            "constant_charge_voltage_max", "charge_behaviour", "manufacturer",
            "model_name", "serial_number", "scope",
        ))
        source = self._supply(tcpm_path, (
            "online", "present", "usb_type", "voltage_now", "voltage_min", "voltage_max",
            "current_now", "current_max", "manufacturer", "model_name", "scope",
        ))
        typec: dict[str, Any] = {}
        for port in sorted(Path("/sys/class/typec").glob("port[0-9]*")):
            if "-" in port.name:
                continue
            typec["name"] = port.name
            for field in ("power_role", "data_role", "port_type", "preferred_role", "orientation"):
                value = read_text(port / field)
                if value is not None:
                    typec[field] = selected_value(value)
            break
        voltage = plausible_voltage_uv(battery.get("voltage_avg"), battery.get("voltage_now"))
        current = battery.get("current_now")
        battery["temperature_c"] = round(battery["temp"] / 10, 1) if isinstance(battery.get("temp"), int) else None
        battery["power_w"] = round(voltage * current / 1e12, 3) if isinstance(voltage, int) and isinstance(current, int) else None
        battery["capacity_semantics"] = "linear voltage estimate, not fuel-gauge SOC"
        battery["learned_full_capacity_available"] = bool(battery.get("charge_full"))
        battery["state_of_health_percent"] = (
            round(100 * battery["charge_full"] / battery["charge_full_design"], 1)
            if battery.get("charge_full") and battery.get("charge_full_design") else None
        )
        if source.get("voltage_now") and source.get("current_max"):
            source["advertised_power_w"] = round(source["voltage_now"] * source["current_max"] / 1e12, 2)
        if charger.get("voltage_now") and charger.get("current_now"):
            charger["input_power_w"] = round(charger["voltage_now"] * charger["current_now"] / 1e12, 3)
        thermals = thermal_snapshot()
        warnings: list[str] = []
        if voltage and battery.get("voltage_max_design") and voltage > battery["voltage_max_design"]:
            warnings.append("Battery voltage is above voltage_max_design")
        if battery.get("temperature_c") is not None and battery["temperature_c"] >= 45:
            warnings.append("Battery temperature is elevated")
        if not charger.get("online"):
            warnings.append("External charger input is offline")
        if source.get("current_max") and charger.get("current_max") and charger["current_max"] < min(500_000, source["current_max"]):
            warnings.append(
                f"Effective charger current limit is only {charger['current_max'] / 1000:.0f} mA "
                f"despite {source['current_max'] / 1_000_000:.1f} A source capability"
            )
        if charger.get("online") and isinstance(current, int) and current < -100_000:
            warnings.append("Battery is discharging significantly while external input is online")
        if battery.get("charge_full") in (None, 0):
            warnings.append("Learned full capacity and SOH are unavailable")
        return {
            "timestamp": time.time(), "battery": battery, "charger": charger,
            "source": source, "typec": typec, "thermals": thermals, "warnings": warnings,
            "services": {
                "charge_cap": service_state("phoenix-charge-cap.timer"),
                "battery_safety": service_state("phoenix-battery-safety.service"),
                "telemetry": service_state("phoenix-battery-telemetry.service"),
            },
        }

    def _loop(self) -> None:
        while True:
            snap = self.snapshot()
            now = time.monotonic()
            battery = snap["battery"]
            current = battery.get("current_now")
            voltage = plausible_voltage_uv(battery.get("voltage_avg"), battery.get("voltage_now"))
            with self.lock:
                if self.last_t is not None and current is not None and voltage is not None and self.last_current_ua is not None and self.last_voltage_uv is not None:
                    dt = now - self.last_t
                    if 0 < dt <= 15:
                        avg_i = (current + self.last_current_ua) / 2
                        avg_v = (voltage + self.last_voltage_uv) / 2
                        mah = abs(avg_i) * dt / 3_600_000
                        mwh = abs(avg_i * avg_v) * dt / 3_600_000_000_000
                        if avg_i >= 0:
                            self.charged_mah += mah
                            self.charged_mwh += mwh
                        else:
                            self.discharged_mah += mah
                            self.discharged_mwh += mwh
                self.last_t, self.last_current_ua, self.last_voltage_uv = now, current, voltage
                # `t` is the x-axis key every chart reads; input_w feeds the
                # adapter-power multiple on the Power page.
                self.history.append({
                    "t": snap["timestamp"], "timestamp": snap["timestamp"],
                    "voltage_uv": voltage, "current_ua": current,
                    "temp_c": battery.get("temperature_c"),
                    "charger_online": snap["charger"].get("online"),
                    "input_w": snap["charger"].get("input_power_w"),
                })
            time.sleep(CONFIG.sample_seconds)

    def report(self) -> dict[str, Any]:
        current = self.snapshot()
        with self.lock:
            current["usage_since_manager_start"] = {
                "elapsed_seconds": round(time.monotonic() - self.started, 1),
                "charged_mah": round(self.charged_mah, 3),
                "discharged_mah": round(self.discharged_mah, 3),
                "charged_mwh": round(self.charged_mwh, 3),
                "discharged_mwh": round(self.discharged_mwh, 3),
                "integration_clock": "CLOCK_MONOTONIC",
            }
            current["historical_telemetry_report"] = historical_battery_report()
        return current

    def history_report(self) -> list[dict[str, Any]]:
        with self.lock:
            return list(self.history)


BATTERY = BatterySampler(start=os.getenv("PHOENIX_LLM_DISABLE_SAMPLER") != "1")


def tail_lines(path: Path, count: int, chunk: int = 256 * 1024) -> list[str]:
    """Last `count` lines without reading the whole file.

    A verbose llama-server log grows without bound between rotations; slurping
    hundreds of megabytes into a Python string on a 5.4 GiB phone is not
    acceptable for a dashboard poll.
    """
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            data = b""
            while size > 0 and data.count(b"\n") <= count:
                step = min(chunk, size)
                size -= step
                handle.seek(size)
                data = handle.read(step) + data
                if size == 0:
                    break
    except OSError:
        return []
    return data.decode(errors="replace").splitlines()[-count:]


def rotate_log(path: Path, max_bytes: int) -> None:
    """Keep one previous generation; called before each runtime start."""
    try:
        if max_bytes > 0 and path.is_file() and path.stat().st_size > max_bytes:
            path.replace(path.with_suffix(path.suffix + ".1"))
    except OSError:
        pass



# ---------------------------------------------------------------------------
# Device-wide information: system, processes, services, network, storage.
# All reads come from /proc and /sys; the handful of system commands are
# cached so a dashboard polling every few seconds cannot fork-storm the phone.
# ---------------------------------------------------------------------------

CPUFREQ_ROOT = Path("/sys/devices/system/cpu/cpufreq")
NET_ROOT = Path("/sys/class/net")
PROC_ROOT = Path("/proc")
ADAPTER_RESULT_DIR = Path("/var/log/phoenix-adapter-tests")
CHARGE_CAP_SCRIPT = Path("/usr/libexec/phoenix-charge-cap.sh")
PHOENIX_UNITS = (
    "phoenix-charge-cap.timer", "phoenix-battery-safety.service",
    "phoenix-battery-telemetry.service", "phoenix-typec-recover.timer",
    "phoenix-usb-host-wake.service", "phoenix-screen-off.service",
    "phoenix-wlan-mac.service", "adsp-disable-recovery.service",
    "phoenix-llm-manager.service",
)
WELL_KNOWN_PORTS = {
    22: "ssh", 53: "dns", 631: "ipp (cups)", 5355: "llmnr", 7070: "phoenix console",
    8080: "llama-server", 6443: "kubernetes api", 10250: "kubelet", 20241: "cloudflared metrics",
    2375: "podman api (plain)", 2376: "podman api (tls)", 8000: "portainer edge tunnel",
    9000: "portainer (http)", 9443: "portainer (https)",
}
UNIT_NAME = re.compile(r"^[A-Za-z0-9_.@:\\-]{1,128}$")
try:
    CLK_TCK = os.sysconf("SC_CLK_TCK")
    PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
except (ValueError, OSError, AttributeError):
    CLK_TCK, PAGE_SIZE = 100, 4096

_CACHE: dict[str, tuple[float, Any]] = {}
_CACHE_LOCK = threading.Lock()


def cached(key: str, ttl: float, compute: Any) -> Any:
    now = time.monotonic()
    with _CACHE_LOCK:
        hit = _CACHE.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = compute()
    with _CACHE_LOCK:
        _CACHE[key] = (now, value)
    return value


def run_cmd(args: list[str], timeout: float = 5) -> str:
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def read_lines(path: Path) -> list[str]:
    text = read_text(path)
    return text.splitlines() if text else []


def cpu_times_total() -> tuple[int, int]:
    """(total, idle) jiffies from the aggregate cpu line of /proc/stat."""
    for line in read_lines(PROC_ROOT / "stat"):
        if line.startswith("cpu "):
            fields = [int(x) for x in line.split()[1:]]
            return sum(fields), fields[3] + (fields[4] if len(fields) > 4 else 0)
    return 0, 0


def cpu_times_per_cpu() -> dict[int, tuple[int, int]]:
    out: dict[int, tuple[int, int]] = {}
    for line in read_lines(PROC_ROOT / "stat"):
        if line.startswith("cpu") and not line.startswith("cpu "):
            parts = line.split()
            if not parts[0][3:].isdigit():
                continue
            fields = [int(x) for x in parts[1:]]
            out[int(parts[0][3:])] = (sum(fields), fields[3] + (fields[4] if len(fields) > 4 else 0))
    return out


def percent(part: float, whole: float) -> float:
    return round(100 * part / whole, 1) if whole > 0 else 0.0


def loadavg() -> dict[str, Any]:
    parts = (read_text(PROC_ROOT / "loadavg") or "0 0 0 0/0 0").split()
    running, _, threads = (parts[3] if len(parts) > 3 else "0/0").partition("/")
    try:
        return {"load1": float(parts[0]), "load5": float(parts[1]), "load15": float(parts[2]),
                "running": int(running or 0), "threads": int(threads or 0)}
    except (ValueError, IndexError):
        return {"load1": 0.0, "load5": 0.0, "load15": 0.0, "running": 0, "threads": 0}


def uptime_seconds() -> float:
    try:
        return float((read_text(PROC_ROOT / "uptime") or "0").split()[0])
    except (ValueError, IndexError):
        return 0.0


def cpufreq_policies() -> list[dict[str, Any]]:
    out = []
    for path in sorted(CPUFREQ_ROOT.glob("policy*"), key=lambda p: int(p.name[6:]) if p.name[6:].isdigit() else 0):
        out.append({
            "name": path.name, "cpus": read_text(path / "affected_cpus") or "",
            "governor": read_text(path / "scaling_governor"),
            "cur_khz": read_int(path / "scaling_cur_freq"), "min_khz": read_int(path / "scaling_min_freq"),
            "max_khz": read_int(path / "scaling_max_freq"), "hw_max_khz": read_int(path / "cpuinfo_max_freq"),
        })
    return out


def cooling_devices() -> list[dict[str, Any]]:
    return [{"type": read_text(c / "type") or c.name, "cur": read_int(c / "cur_state"), "max": read_int(c / "max_state")}
            for c in sorted(THERMAL_ROOT.glob("cooling_device*"))]


def thermal_groups(zones: list[dict[str, Any]]) -> dict[str, float | None]:
    """Hottest reading per silicon group, for charts that must stay at <=3 series."""
    groups: dict[str, float | None] = {"cpu": None, "gpu": None, "battery": None}
    for zone in zones:
        name = zone["name"].lower()
        key = "cpu" if name.startswith("cpu") else "gpu" if name.startswith("gpu") else "battery" if "qg" in name or "batt" in name else None
        if key and (groups[key] is None or zone["temp_c"] > groups[key]):
            groups[key] = zone["temp_c"]
    return groups


def net_counters() -> dict[str, tuple[int, int]]:
    out: dict[str, tuple[int, int]] = {}
    if not NET_ROOT.exists():
        return out
    for iface in NET_ROOT.iterdir():
        rx, tx = read_int(iface / "statistics/rx_bytes"), read_int(iface / "statistics/tx_bytes")
        if rx is not None and tx is not None:
            out[iface.name] = (rx, tx)
    return out


def net_interfaces() -> list[dict[str, Any]]:
    address_map: dict[str, list[str]] = {}
    for line in cached("ip-addr", 5.0, lambda: run_cmd(["ip", "-brief", "addr"])).splitlines():
        parts = line.split()
        if parts:
            address_map[parts[0]] = parts[2:]
    out = []
    if not NET_ROOT.exists():
        return out
    for iface in sorted(NET_ROOT.iterdir(), key=lambda p: p.name):
        stats = iface / "statistics"
        out.append({
            "name": iface.name, "operstate": read_text(iface / "operstate"), "carrier": read_int(iface / "carrier"),
            "speed_mbps": read_int(iface / "speed"), "mac": read_text(iface / "address"), "mtu": read_int(iface / "mtu"),
            "addresses": address_map.get(iface.name, []),
            "rx_bytes": read_int(stats / "rx_bytes"), "tx_bytes": read_int(stats / "tx_bytes"),
            "rx_packets": read_int(stats / "rx_packets"), "tx_packets": read_int(stats / "tx_packets"),
            "rx_errors": read_int(stats / "rx_errors"), "tx_errors": read_int(stats / "tx_errors"),
        })
    return out


def listening_ports() -> list[dict[str, Any]]:
    out = []
    for proto, path in (("tcp", PROC_ROOT / "net/tcp"), ("tcp6", PROC_ROOT / "net/tcp6")):
        for line in read_lines(path)[1:]:
            fields = line.split()
            if len(fields) < 4 or fields[3] != "0A":
                continue
            addr, _, port_hex = fields[1].rpartition(":")
            try:
                port = int(port_hex, 16)
                host = ".".join(str(b) for b in bytes.fromhex(addr)[::-1]) if proto == "tcp" else ("::" if set(addr) <= {"0"} else "[::]")
            except ValueError:
                continue
            out.append({"proto": proto, "host": host, "port": port, "service": WELL_KNOWN_PORTS.get(port, "")})
    out.sort(key=lambda row: (row["port"], row["proto"]))
    return out


def mounts() -> list[dict[str, Any]]:
    out, seen_paths, seen_devices = [], set(), set()
    for line in read_lines(PROC_ROOT / "mounts"):
        fields = line.split()
        if len(fields) < 3 or not fields[0].startswith("/dev/"):
            continue
        mountpoint = fields[1].replace("\\040", " ")
        # A bind mount of an already-listed device (the unit's StateDirectory,
        # PrivateTmp) is the same filesystem, not more storage.
        if mountpoint in seen_paths or fields[0] in seen_devices:
            continue
        seen_paths.add(mountpoint)
        seen_devices.add(fields[0])
        try:
            st = os.statvfs(mountpoint)
        except OSError:
            continue
        total, free, avail = st.f_blocks * st.f_frsize, st.f_bfree * st.f_frsize, st.f_bavail * st.f_frsize
        out.append({"device": fields[0], "mountpoint": mountpoint, "fstype": fields[2], "total_bytes": total,
                    "used_bytes": total - free, "available_bytes": avail,
                    "used_percent": round(100 * (total - free) / total, 1) if total else None})
    return out


def os_info() -> dict[str, Any]:
    release: dict[str, str] = {}
    for line in read_lines(Path("/etc/os-release")):
        key, _, value = line.partition("=")
        release[key] = value.strip('"')
    return {
        "hostname": socket.gethostname(),
        "kernel": read_text(PROC_ROOT / "sys/kernel/osrelease") or "",
        "os": release.get("PRETTY_NAME") or release.get("NAME") or "Linux",
        "model": (read_text(Path("/proc/device-tree/model")) or "").replace("\x00", "").strip() or "unknown",
        "boot_id": read_text(PROC_ROOT / "sys/kernel/random/boot_id"),
        "uptime_s": uptime_seconds(), "cpu_count": os.cpu_count() or 0,
    }


_USERS: dict[int, str] = {}


def username(uid: int) -> str:
    if uid not in _USERS:
        try:
            _USERS[uid] = pwd.getpwuid(uid).pw_name
        except KeyError:
            _USERS[uid] = str(uid)
    return _USERS[uid]


def parse_proc_stat(raw: str) -> dict[str, Any] | None:
    """Parse one /proc/<pid>/stat line; comm may contain spaces and parentheses."""
    left, right = raw.find("("), raw.rfind(")")
    if left < 0 or right < 0:
        return None
    rest = raw[right + 2:].split()
    try:
        return {"comm": raw[left + 1:right], "state": rest[0], "ppid": int(rest[1]), "utime": int(rest[11]),
                "stime": int(rest[12]), "nice": int(rest[16]), "threads": int(rest[17]),
                "starttime": int(rest[19]), "rss_pages": int(rest[21])}
    except (IndexError, ValueError):
        return None


def proc_uid(pid: int) -> int | None:
    for line in read_lines(PROC_ROOT / str(pid) / "status"):
        if line.startswith("Uid:"):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def list_units(kind: str) -> list[dict[str, Any]]:
    def compute() -> list[dict[str, Any]]:
        text = run_cmd(["systemctl", f"list-{kind}", "--all", "--no-legend", "--plain", "--output=json"], timeout=8)
        try:
            data = json.loads(text) if text.strip().startswith("[") else None
        except ValueError:
            data = None
        if data is None:  # older systemd: parse the plain columns
            data = []
            for line in run_cmd(["systemctl", f"list-{kind}", "--all", "--no-legend", "--plain"], timeout=8).splitlines():
                parts = line.split(None, 4)
                if kind == "units" and len(parts) >= 4:
                    data.append({"unit": parts[0], "load": parts[1], "active": parts[2], "sub": parts[3],
                                 "description": parts[4] if len(parts) > 4 else ""})
        return data
    return cached(f"units-{kind}", 10.0, compute)


def list_services() -> list[dict[str, Any]]:
    return [u for u in list_units("units") if str(u.get("unit", "")).endswith(".service")]


def list_timers() -> list[dict[str, Any]]:
    return list_units("timers")


def unit_details(unit: str) -> dict[str, Any]:
    props = ["ActiveState", "SubState", "UnitFileState", "MainPID", "MemoryCurrent", "CPUUsageNSec",
             "ActiveEnterTimestamp", "NRestarts", "Result", "Description"]
    out: dict[str, Any] = {"unit": unit}
    for line in run_cmd(["systemctl", "show", unit, "-p", ",".join(props)]).splitlines():
        key, _, value = line.partition("=")
        out[key] = value
    return out


def phoenix_units() -> list[dict[str, Any]]:
    return cached("phoenix-units", 10.0, lambda: [unit_details(u) for u in PHOENIX_UNITS])


def journal_tail(lines: int = 100, unit: str | None = None, priority: int | None = None) -> list[dict[str, Any]]:
    args = ["journalctl", "-n", str(max(1, min(lines, 1000))), "--no-pager", "-o", "json"]
    if unit:
        if not UNIT_NAME.match(unit):
            raise ValueError("invalid unit name")
        args += ["-u", unit]
    if priority is not None:
        args += ["-p", str(max(0, min(priority, 7)))]
    out = []
    for line in run_cmd(args, timeout=10).splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = entry.get("MESSAGE", "")
        if isinstance(message, list):
            message = bytes(message).decode(errors="replace")
        stamp = entry.get("__REALTIME_TIMESTAMP")
        prio = entry.get("PRIORITY")
        out.append({
            "ts": int(stamp) / 1e6 if str(stamp).isdigit() else None,
            "unit": entry.get("_SYSTEMD_UNIT") or entry.get("SYSLOG_IDENTIFIER") or entry.get("_COMM") or "",
            "priority": int(prio) if str(prio).isdigit() else None,
            "message": str(message),
        })
    return out


def power_status() -> dict[str, Any]:
    def compute() -> dict[str, Any]:
        text = run_cmd([str(CHARGE_CAP_SCRIPT), "status"]) if CHARGE_CAP_SCRIPT.exists() else ""
        fields: dict[str, str] = {}
        for line in text.splitlines():
            key, sep, value = line.partition(":")
            if sep:
                fields[key.strip()] = value.strip()
        return {"text": text.strip(), "fields": fields}
    return cached("power-status", 10.0, compute)


def adapter_results() -> list[dict[str, str]]:
    out = []
    for path in sorted(ADAPTER_RESULT_DIR.glob("*.result")) if ADAPTER_RESULT_DIR.exists() else []:
        row: dict[str, str] = {}
        for line in read_lines(path):
            key, sep, value = line.partition("=")
            if sep and key.startswith("R_"):
                row[key[2:].lower()] = value.strip().strip("'")
        if row:
            out.append(row)
    return out


def powerpath_results() -> list[dict[str, str]]:
    if not ADAPTER_RESULT_DIR.exists():
        return []
    return [{"file": p.name, "text": read_text(p) or ""} for p in sorted(ADAPTER_RESULT_DIR.glob("*-powerpath.txt"))]


SIGNALS = {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL, "INT": signal.SIGINT, "HUP": signal.SIGHUP}


def signal_process(pid: int, name: str) -> dict[str, Any]:
    """Send a signal to a process this unprivileged service is allowed to touch."""
    if pid <= 1:
        raise ValueError("refusing to signal pid 0 or 1")
    if pid == os.getpid():
        raise ValueError("refusing to signal the console itself")
    sig = SIGNALS.get(name.upper())
    if sig is None:
        raise ValueError("signal must be one of TERM, KILL, INT, HUP")
    uid = proc_uid(pid)
    if uid is None:
        raise ValueError(f"no such process: {pid}")
    if uid != os.getuid():
        raise PermissionError(
            f"pid {pid} belongs to {username(uid)}; the console runs unprivileged and can only signal "
            f"processes owned by {username(os.getuid())}"
        )
    stat = parse_proc_stat(read_text(PROC_ROOT / str(pid) / "stat") or "")
    os.kill(pid, sig)
    return {"pid": pid, "signal": name.upper(), "name": stat["comm"] if stat else None}


class SystemSampler:
    """Five-second device history plus a per-process CPU table.

    Process CPU% needs two samples; computing it here on the sampler's clock means
    a request never blocks, and the table reflects the same window as the graphs.
    """

    def __init__(self, start: bool = True, maxlen: int | None = None, interval: float | None = None) -> None:
        self.lock = threading.Lock()
        self.interval = interval or CONFIG.sample_seconds
        self.history: collections.deque[dict[str, Any]] = collections.deque(maxlen=maxlen or CONFIG.history_points)
        self.processes: list[dict[str, Any]] = []
        self.latest: dict[str, Any] = {}
        self._prev_total: tuple[int, int] | None = None
        self._prev_cpu: dict[int, tuple[int, int]] = {}
        self._prev_net: dict[str, tuple[int, int]] = {}
        self._prev_proc: dict[int, int] = {}
        self._prev_time: float | None = None
        if start:
            threading.Thread(target=self._loop, name="system-sampler", daemon=True).start()

    def sample_once(self) -> dict[str, Any]:
        now = time.monotonic()
        total, idle = cpu_times_total()
        per_cpu = cpu_times_per_cpu()
        net = net_counters()
        policies = cpufreq_policies()
        cpu_pct: float | None = None
        clusters: dict[str, float] = {}
        total_delta = 0
        if self._prev_total is not None:
            total_delta = total - self._prev_total[0]
            cpu_pct = percent(total_delta - (idle - self._prev_total[1]), total_delta)
            for pol in policies:
                busy = whole = 0
                for cpu in (int(c) for c in pol["cpus"].split() if c.isdigit()):
                    if cpu in per_cpu and cpu in self._prev_cpu:
                        d_total = per_cpu[cpu][0] - self._prev_cpu[cpu][0]
                        whole += d_total
                        busy += d_total - (per_cpu[cpu][1] - self._prev_cpu[cpu][1])
                clusters[pol["name"]] = percent(busy, whole)
        rates: dict[str, dict[str, float]] = {}
        if self._prev_time is not None:
            dt = now - self._prev_time
            for name, (rx, tx) in net.items():
                if name in self._prev_net and dt > 0 and name != "lo":
                    rates[name] = {"rx_bps": max(0, rx - self._prev_net[name][0]) / dt,
                                   "tx_bps": max(0, tx - self._prev_net[name][1]) / dt}
        processes, new_prev = self._process_table(total_delta)
        memory = meminfo()
        thermal = thermal_snapshot()
        groups = thermal_groups(thermal["zones"])
        load = loadavg()
        point = {
            "t": time.time(), "cpu": cpu_pct, "clusters": clusters,
            "freq": {p["name"]: p["cur_khz"] for p in policies},
            "mem_used": memory["used_bytes"], "mem_available": memory["available_bytes"],
            "swap_used": memory["swap_used_bytes"], "load1": load["load1"],
            "temp_hot": thermal["hottest"]["temp_c"] if thermal["hottest"] else None,
            "temp_cpu": groups["cpu"], "temp_gpu": groups["gpu"], "temp_battery": groups["battery"],
            "net": rates, "processes": len(processes),
        }
        with self.lock:
            self.history.append(point)
            self.processes = processes
            self.latest = {"cpu": cpu_pct, "clusters": clusters, "policies": policies, "memory": memory,
                           "thermal": thermal, "groups": groups, "load": load, "net_rates": rates,
                           "process_count": len(processes), "cooling": cooling_devices()}
        self._prev_total, self._prev_cpu, self._prev_net, self._prev_proc, self._prev_time = (total, idle), per_cpu, net, new_prev, now
        return point

    def _process_table(self, total_delta: int) -> tuple[list[dict[str, Any]], dict[int, int]]:
        rows, new_prev = [], {}
        ncpu = os.cpu_count() or 1
        up = uptime_seconds()
        my_uid = os.getuid()
        try:
            entries = [e for e in os.scandir(PROC_ROOT) if e.name.isdigit()]
        except OSError:
            return rows, new_prev
        for entry in entries:
            pid = int(entry.name)
            stat = parse_proc_stat(read_text(PROC_ROOT / entry.name / "stat") or "")
            if stat is None:
                continue
            ticks = stat["utime"] + stat["stime"]
            new_prev[pid] = ticks
            cpu = round(100 * (ticks - self._prev_proc[pid]) / total_delta * ncpu, 1) if pid in self._prev_proc and total_delta > 0 else 0.0
            uid = proc_uid(pid)
            cmdline = (read_text(PROC_ROOT / entry.name / "cmdline") or "").replace("\x00", " ").strip()
            rows.append({
                "pid": pid, "ppid": stat["ppid"], "name": stat["comm"], "cmdline": cmdline[:160],
                "state": stat["state"], "uid": uid, "user": username(uid) if uid is not None else "?",
                "rss_bytes": stat["rss_pages"] * PAGE_SIZE, "cpu_percent": max(0.0, cpu),
                "threads": stat["threads"], "nice": stat["nice"],
                "elapsed_s": max(0.0, up - stat["starttime"] / CLK_TCK),
                "killable": uid == my_uid and pid != os.getpid(),
            })
        return rows, new_prev

    def _loop(self) -> None:
        while True:
            try:
                self.sample_once()
            except Exception as exc:  # noqa: BLE001 - a sampler must never die
                print(f"system sampler error: {exc}", flush=True)
            time.sleep(self.interval)

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return dict(self.latest)

    def history_report(self) -> list[dict[str, Any]]:
        with self.lock:
            return list(self.history)

    def process_report(self, sort: str = "cpu", limit: int = 60, query: str = "") -> dict[str, Any]:
        with self.lock:
            rows = list(self.processes)
        if query:
            q = query.lower()
            rows = [r for r in rows if q in r["name"].lower() or q in r["cmdline"].lower() or q in r["user"].lower() or q == str(r["pid"])]
        key = {"cpu": lambda r: r["cpu_percent"], "mem": lambda r: r["rss_bytes"], "pid": lambda r: -r["pid"],
               "name": lambda r: (-1, r["name"].lower()), "time": lambda r: r["elapsed_s"]}.get(sort, lambda r: r["cpu_percent"])
        if sort == "name":
            rows.sort(key=lambda r: r["name"].lower())
        else:
            rows.sort(key=key, reverse=True)
        return {"total": len(rows), "rows": rows[:max(1, min(limit, 500))], "sampled_over_s": self.interval}


SYSTEM = SystemSampler(start=os.getenv("PHOENIX_LLM_DISABLE_SAMPLER") != "1")


def overview() -> dict[str, Any]:
    system = SYSTEM.snapshot()
    battery = BATTERY.snapshot()
    runtime = RUNTIME.status()
    power = power_status()
    root = next((m for m in mounts() if m["mountpoint"] == "/"), None)
    primary = next((i for i in net_interfaces() if i["operstate"] == "up" and i["name"] != "lo"), None)
    units = {u["unit"]: u.get("ActiveState", "unknown") for u in phoenix_units()}
    return {
        "info": os_info(), "system": system, "runtime": {k: runtime.get(k) for k in ("running", "ready", "profile", "pid", "process_rss_bytes")},
        "battery": {k: battery["battery"].get(k) for k in ("capacity", "voltage_avg", "voltage_now", "current_now", "temperature_c", "power_w")},
        "charger": {k: battery["charger"].get(k) for k in ("online", "status", "input_power_w", "current_max")},
        "power": power["fields"], "warnings": battery["warnings"], "root_fs": root, "primary_iface": primary,
        "units": units, "manager": {"auth_enabled": bool(CONFIG.api_token)},
    }


class RuntimeManager:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.process: subprocess.Popen[bytes] | None = None
        self.log_handle: Any = None

    def _state(self) -> dict[str, Any]:
        try:
            return json.loads(CONFIG.state_path.read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def _owned_pid(self, pid: int) -> bool:
        return pid > 1 and any("llama-server" in item for item in pid_command(pid))

    def status(self) -> dict[str, Any]:
        state = self._state()
        pid = int(state.get("pid", 0) or 0)
        running = self._owned_pid(pid)
        memory = meminfo()
        thermal = thermal_snapshot()
        return {
            "running": running,
            "ready": running and self._health(),
            "profile": state.get("profile") if running else None,
            "pid": pid if running else None,
            "started_at": state.get("started_at") if running else None,
            "command": state.get("command") if running else None,
            "process_rss_bytes": process_rss(pid) if running else None,
            "memory": memory,
            "thermal": thermal,
            "runtime_url": f"http://{CONFIG.runtime_host}:{CONFIG.runtime_port}",
            "turboquant": {
                "implemented": CONFIG.llama_server.exists(),
                "mode": "true rotated TurboQuant KV cache",
                "backend": "CPU/OpenBLAS",
                "vulkan_enabled": False,
                "reason": "Adreno 618 Turnip lacks the 16-bit-storage feature required by this Spark build",
            },
        }

    def _health(self) -> bool:
        try:
            with urllib.request.urlopen(f"http://{CONFIG.runtime_host}:{CONFIG.runtime_port}/health", timeout=1) as response:
                return response.status < 500
        except (OSError, urllib.error.URLError):
            return False

    def _command(self, profile: dict[str, Any]) -> list[str]:
        return [
            str(CONFIG.llama_server), "-m", str(CONFIG.model_path),
            "--host", CONFIG.runtime_host, "--port", str(CONFIG.runtime_port),
            "--device", "none", "--gpu-layers", "0",
            "--ctx-size", str(profile["context"]), "--parallel", "1",
            "--threads", str(profile["threads"]), "--threads-batch", str(profile["threads_batch"]),
            "--batch-size", str(profile["batch"]), "--ubatch-size", str(profile["ubatch"]),
            "--cache-type-k", profile["cache_k"], "--cache-type-v", profile["cache_v"],
            "--cache-ram", str(profile["cache_ram"]), "--flash-attn", "on",
            "--no-warmup", "--metrics",
        ]

    def start(self, profile_name: str) -> dict[str, Any]:
        with self.lock:
            if profile_name not in PROFILES:
                raise ValueError(f"unknown profile: {profile_name}")
            if self.status()["running"]:
                raise RuntimeError("an inference runtime is already running")
            battery_preflight()
            if not CONFIG.llama_server.is_file():
                raise FileNotFoundError(f"llama-server not found: {CONFIG.llama_server}")
            if not CONFIG.model_path.is_file():
                raise FileNotFoundError(f"model not found: {CONFIG.model_path}")
            available_mib = meminfo()["available_bytes"] // 2**20
            if available_mib < CONFIG.minimum_available_mib:
                raise MemoryError(f"only {available_mib} MiB available; require {CONFIG.minimum_available_mib} MiB")
            hottest = thermal_snapshot()["hottest"]
            if hottest and hottest["temp_c"] >= CONFIG.thermal_critical_c:
                raise RuntimeError(f"thermal preflight failed: {hottest['name']} is {hottest['temp_c']} C")
            command = self._command(PROFILES[profile_name])
            CONFIG.log_path.parent.mkdir(parents=True, exist_ok=True)
            CONFIG.state_path.parent.mkdir(parents=True, exist_ok=True)
            rotate_log(CONFIG.log_path, CONFIG.log_max_bytes)
            self.log_handle = CONFIG.log_path.open("ab", buffering=0)
            self.process = subprocess.Popen(
                command, stdout=self.log_handle, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            CONFIG.state_path.write_text(json.dumps({
                "pid": self.process.pid, "profile": profile_name,
                "started_at": time.time(), "command": command,
            }, indent=2) + "\n")
        deadline = time.monotonic() + CONFIG.startup_timeout
        while time.monotonic() < deadline:
            if not self._owned_pid(self.process.pid if self.process else 0):
                raise RuntimeError("llama-server was stopped while it was loading")
            if self.process and self.process.poll() is not None:
                code = self.process.returncode
                self.stop()
                raise RuntimeError(f"llama-server exited with code {code}; inspect runtime log")
            if self._health():
                return self.status()
            time.sleep(1)
        self.stop()
        raise TimeoutError("llama-server did not become ready before the startup timeout")

    def stop(self) -> dict[str, Any]:
        with self.lock:
            state = self._state()
            pid = int(state.get("pid", 0) or 0)
            if self._owned_pid(pid):
                try:
                    os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + CONFIG.shutdown_timeout
                while self._owned_pid(pid) and time.monotonic() < deadline:
                    time.sleep(0.2)
                if self._owned_pid(pid):
                    os.killpg(pid, signal.SIGKILL)
            CONFIG.state_path.unlink(missing_ok=True)
            if self.log_handle:
                self.log_handle.close()
            self.log_handle = None
            self.process = None
            return self.status()

    def logs(self, lines: int = 200) -> list[str]:
        return tail_lines(CONFIG.log_path, max(1, min(lines, 2000)))


RUNTIME = RuntimeManager()


def thermal_guard() -> None:
    """Stop inference after sustained critical SoC temperature.

    Kernel thermal throttling remains the primary hardware protection. This is
    an additional server policy that avoids leaving a runaway unattended model
    at the configured critical temperature.
    """
    critical_samples = 0
    while True:
        hottest = thermal_snapshot()["hottest"]
        if RUNTIME.status()["running"] and hottest and hottest["temp_c"] >= CONFIG.thermal_critical_c:
            critical_samples += 1
            if critical_samples >= 3:
                print(
                    f"thermal guard stopping runtime: {hottest['name']}="
                    f"{hottest['temp_c']} C",
                    flush=True,
                )
                RUNTIME.stop()
                critical_samples = 0
        else:
            critical_samples = 0
        time.sleep(5)


def profile_list() -> list[dict[str, Any]]:
    return [{"name": name, **profile} for name, profile in PROFILES.items()]


class Handler(BaseHTTPRequestHandler):
    server_version = "PhoenixConsole/2.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.client_address[0]} {fmt % args}", flush=True)

    def _authorized(self) -> bool:
        if not CONFIG.api_token:
            return True
        supplied = self.headers.get("X-API-Key", "")
        return secrets.compare_digest(supplied, CONFIG.api_token)

    def _json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, message: str) -> None:
        self._json({"error": message}, status)

    def _body(self) -> dict[str, Any]:
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 1_048_576)
            return json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            raise ValueError("invalid JSON request") from None

    def _static(self, name: str, content_type: str) -> None:
        try:
            body = (STATIC_DIR / name).read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _query(self) -> dict[str, str]:
        _, _, query = self.path.partition("?")
        return dict(urllib.parse.parse_qsl(query, keep_blank_values=True))

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        query = self._query()
        if path == "/":
            return self._static("index.html", "text/html; charset=utf-8")
        if path == "/app.js":
            return self._static("app.js", "text/javascript; charset=utf-8")
        if path == "/styles.css":
            return self._static("styles.css", "text/css; charset=utf-8")
        if path == "/health":
            return self._json({"status": "ok"})
        if not self._authorized():
            return self._error(401, "invalid or missing API token")
        try:
            if path == "/api/overview":
                return self._json(overview())
            if path == "/api/status":
                status = RUNTIME.status()
                status["manager"] = {"auth_enabled": bool(CONFIG.api_token), "bind_host": CONFIG.bind_host, "port": CONFIG.manager_port}
                return self._json(status)
            if path == "/api/profiles":
                return self._json(profile_list())
            if path == "/api/battery":
                return self._json(BATTERY.report())
            if path == "/api/battery/history":
                return self._json(BATTERY.history_report())
            if path == "/api/logs":
                return self._json({"lines": RUNTIME.logs(int(query.get("lines", "200") or 200))})
            if path == "/api/system":
                snap = SYSTEM.snapshot()
                snap["info"] = os_info()
                return self._json(snap)
            if path == "/api/system/history":
                return self._json(SYSTEM.history_report())
            if path == "/api/processes":
                return self._json(SYSTEM.process_report(query.get("sort", "cpu"), int(query.get("limit", "60") or 60), query.get("q", "")))
            if path == "/api/services":
                return self._json({"services": list_services(), "timers": list_timers(), "phoenix": phoenix_units()})
            if path == "/api/network":
                return self._json({"interfaces": net_interfaces(), "rates": SYSTEM.snapshot().get("net_rates", {}), "listening": listening_ports()})
            if path == "/api/storage":
                return self._json({"mounts": mounts()})
            if path == "/api/thermal":
                snap = SYSTEM.snapshot()
                return self._json({"thermal": snap.get("thermal") or thermal_snapshot(), "groups": snap.get("groups"),
                                   "cooling": snap.get("cooling") or cooling_devices(), "policies": snap.get("policies") or cpufreq_policies()})
            if path == "/api/journal":
                prio = query.get("priority")
                return self._json({"entries": journal_tail(int(query.get("lines", "100") or 100), query.get("unit") or None,
                                                           int(prio) if prio and prio.isdigit() else None)})
            if path == "/api/power":
                return self._json({"status": power_status(), "adapters": adapter_results(), "powerpath": powerpath_results(),
                                   "battery": BATTERY.report()})
        except ValueError as exc:
            return self._error(400, str(exc))
        return self._error(404, "not found")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if not self._authorized():
            return self._error(401, "invalid or missing API token")
        try:
            if path.startswith("/api/runtime/") and path.endswith("/start"):
                name = path.removeprefix("/api/runtime/").removesuffix("/start")
                return self._json(RUNTIME.start(name))
            if path == "/api/runtime/stop":
                return self._json(RUNTIME.stop())
            if path == "/api/runtime/restart":
                profile = RUNTIME.status().get("profile")
                if not profile:
                    raise RuntimeError("no running profile to restart")
                RUNTIME.stop()
                return self._json(RUNTIME.start(profile))
            if path.startswith("/api/processes/") and path.endswith("/signal"):
                pid_text = path.removeprefix("/api/processes/").removesuffix("/signal")
                if not pid_text.isdigit():
                    return self._error(400, "pid must be numeric")
                payload = self._body()
                return self._json(signal_process(int(pid_text), str(payload.get("signal", "TERM"))))
            if path == "/api/chat":
                payload = self._body()
                request = urllib.request.Request(
                    f"http://{CONFIG.runtime_host}:{CONFIG.runtime_port}/v1/chat/completions",
                    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST",
                )
                with urllib.request.urlopen(request, timeout=600) as response:
                    return self._json(json.loads(response.read()))
            return self._error(404, "not found")
        except PermissionError as exc:
            return self._error(403, str(exc))
        except (ValueError, RuntimeError, FileNotFoundError, MemoryError, TimeoutError) as exc:
            return self._error(409, str(exc))
        except urllib.error.URLError as exc:
            return self._error(502, f"runtime request failed: {exc.reason}")

def main() -> None:
    threading.Thread(target=thermal_guard, name="thermal-guard", daemon=True).start()
    server = ThreadingHTTPServer((CONFIG.bind_host, CONFIG.manager_port), Handler)
    server.daemon_threads = True
    print(f"Phoenix Console listening on {CONFIG.bind_host}:{CONFIG.manager_port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
