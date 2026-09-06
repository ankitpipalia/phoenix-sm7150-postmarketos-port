#!/usr/bin/env python3
"""Small dependency-free control plane for llama.cpp on Xiaomi Phoenix.

The service deliberately owns one inference process at a time.  It exposes a
read-only hardware/battery API plus authenticated runtime mutations, and keeps
all heavyweight inference work in llama-server rather than the Python process.
"""

from __future__ import annotations

import collections
import dataclasses
import json
import os
import secrets
import signal
import socket
import subprocess
import threading
import time
import urllib.error
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
        temp_c = raw / 1000 if abs(raw) >= 1000 else raw / 10
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


class BatterySampler:
    def __init__(self, start: bool = True) -> None:
        self.lock = threading.Lock()
        self.history: collections.deque[dict[str, Any]] = collections.deque(maxlen=720)
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
        voltage = battery.get("voltage_avg") or battery.get("voltage_now")
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
            voltage = battery.get("voltage_avg") or battery.get("voltage_now")
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
                self.history.append({
                    "timestamp": snap["timestamp"], "voltage_uv": voltage, "current_ua": current,
                    "temp_c": battery.get("temperature_c"),
                    "charger_online": snap["charger"].get("online"),
                })
            time.sleep(5)

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
        try:
            return CONFIG.log_path.read_text(errors="replace").splitlines()[-max(1, min(lines, 2000)):]
        except OSError:
            return []


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
    server_version = "PhoenixLLM/1.0"

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

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
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
            return self._json({"lines": RUNTIME.logs()})
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
            if path == "/api/chat":
                payload = self._body()
                request = urllib.request.Request(
                    f"http://{CONFIG.runtime_host}:{CONFIG.runtime_port}/v1/chat/completions",
                    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST",
                )
                with urllib.request.urlopen(request, timeout=600) as response:
                    return self._json(json.loads(response.read()))
            return self._error(404, "not found")
        except (ValueError, RuntimeError, FileNotFoundError, MemoryError, TimeoutError) as exc:
            return self._error(409, str(exc))
        except urllib.error.URLError as exc:
            return self._error(502, f"runtime request failed: {exc.reason}")


def main() -> None:
    threading.Thread(target=thermal_guard, name="thermal-guard", daemon=True).start()
    server = ThreadingHTTPServer((CONFIG.bind_host, CONFIG.manager_port), Handler)
    server.daemon_threads = True
    print(f"Phoenix LLM manager listening on {CONFIG.bind_host}:{CONFIG.manager_port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
