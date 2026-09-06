#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


os.environ["PHOENIX_LLM_DISABLE_SAMPLER"] = "1"
MODULE_PATH = Path(__file__).parents[1] / "device-xiaomi-phoenix/extra-addon/phoenix-llm-manager.py"
SPEC = importlib.util.spec_from_file_location("phoenix_llm_manager", MODULE_PATH)
manager = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = manager
SPEC.loader.exec_module(manager)


class ManagerTests(unittest.TestCase):
    def test_turbo4_profile_is_true_turboquant(self):
        profile = manager.PROFILES["spark-turbo4-128k"]
        self.assertEqual(profile["cache_k"], "turbo4")
        self.assertEqual(profile["cache_v"], "turbo4")
        self.assertEqual(profile["context"], 131072)
        command = manager.RUNTIME._command(profile)
        self.assertIn("--device", command)
        self.assertIn("none", command)
        self.assertNotIn("q4_0", command)

    def test_supply_values_and_unavailable_soh_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            battery = root / "qcom_qg"
            charger = root / "pm8150b-charger"
            source = root / "tcpm-source-psy-test"
            for path in (battery, charger, source):
                path.mkdir()
            values = {
                battery: {"capacity": "70", "voltage_avg": "4100000", "current_avg": "100000", "temp": "350", "voltage_max_design": "4400000", "charge_full": "0", "charge_full_design": "4500000"},
                charger: {"online": "1", "charge_behaviour": "[auto] inhibit-charge", "voltage_now": "5000000", "current_now": "300000"},
                source: {"online": "1", "voltage_now": "5000000", "current_max": "3000000", "usb_type": "[C] PD"},
            }
            for path, fields in values.items():
                for name, value in fields.items():
                    (path / name).write_text(value)
            original = manager.POWER_ROOT
            manager.POWER_ROOT = root
            try:
                report = manager.BatterySampler(start=False).snapshot()
            finally:
                manager.POWER_ROOT = original
            self.assertEqual(report["battery"]["temperature_c"], 35.0)
            self.assertIsNone(report["battery"]["state_of_health_percent"])
            self.assertEqual(report["charger"]["charge_behaviour"], "auto")
            self.assertEqual(report["source"]["advertised_power_w"], 15.0)


    def test_thermal_zones_are_millidegrees_and_sentinels_dropped(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, temp in (("zone0", "45000"), ("zone1", "950"), ("zone2", "200000"), ("zone3", "-45000")):
                zone = root / f"thermal_{name}"
                zone.mkdir()
                (zone / "type").write_text(name)
                (zone / "temp").write_text(temp)
            original = manager.THERMAL_ROOT
            manager.THERMAL_ROOT = root
            try:
                snap = manager.thermal_snapshot()
            finally:
                manager.THERMAL_ROOT = original
            temps = {z["name"]: z["temp_c"] for z in snap["zones"]}
            self.assertEqual(temps["zone0"], 45.0)
            # 950 millidegrees is 0.95 C, not 95 C.
            self.assertEqual(temps["zone1"], 0.9)
            self.assertNotIn("zone2", temps)
            self.assertNotIn("zone3", temps)
            self.assertEqual(snap["hottest"]["name"], "zone0")

    def test_tail_lines_reads_only_the_end(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "runtime.log"
            log.write_text("".join(f"line {i}\n" for i in range(50_000)))
            tail = manager.tail_lines(log, 5, chunk=1024)
            self.assertEqual(tail, [f"line {i}" for i in range(49_995, 50_000)])
            self.assertEqual(manager.tail_lines(Path(temporary) / "missing.log", 5), [])

    def test_rotate_log_keeps_one_generation(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "runtime.log"
            log.write_bytes(b"x" * 2048)
            manager.rotate_log(log, 1024)
            self.assertFalse(log.exists())
            self.assertEqual((Path(temporary) / "runtime.log.1").stat().st_size, 2048)
            log.write_bytes(b"y" * 10)
            manager.rotate_log(log, 1024)
            self.assertTrue(log.exists())

    def test_snapshot_ignores_boot_glitch_voltage_avg(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            battery = root / "qcom_qg"
            battery.mkdir()
            for name, value in {"voltage_avg": "6377865", "voltage_now": "4290000", "current_now": "100000",
                                "voltage_max_design": "4400000", "temp": "320"}.items():
                (battery / name).write_text(value)
            original = manager.POWER_ROOT
            manager.POWER_ROOT = root
            try:
                report = manager.BatterySampler(start=False).snapshot()
            finally:
                manager.POWER_ROOT = original
            self.assertNotIn("Battery voltage is above voltage_max_design", report["warnings"])
            # 4.29 V x 100 mA = 0.429 W; had the 6.38 V glitch been used it would read 0.638 W.
            self.assertEqual(report["battery"]["power_w"], 0.429)

    def test_battery_preflight_refuses_offline_and_low_cell(self):
        import dataclasses
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            charger = root / "pm8150b-charger"
            battery = root / "qcom_qg"
            charger.mkdir(); battery.mkdir()
            (charger / "online").write_text("0")
            (battery / "voltage_now").write_text("4200000")
            original_root, original_cfg = manager.POWER_ROOT, manager.CONFIG
            manager.POWER_ROOT = root
            try:
                with self.assertRaisesRegex(RuntimeError, "external power is offline"):
                    manager.battery_preflight()
                (charger / "online").write_text("1")
                manager.battery_preflight()
                (battery / "voltage_now").write_text("3600000")
                with self.assertRaisesRegex(RuntimeError, "below the 3.70 V floor"):
                    manager.battery_preflight()
                # An implausible avg must not satisfy the floor on its own.
                (battery / "voltage_avg").write_text("6377865")
                with self.assertRaisesRegex(RuntimeError, "below the 3.70 V floor"):
                    manager.battery_preflight()
                (battery / "voltage_now").write_text("invalid")
                with self.assertRaisesRegex(RuntimeError, "unavailable or implausible"):
                    manager.battery_preflight()
                manager.CONFIG = dataclasses.replace(original_cfg, require_external_power=False, minimum_battery_uv=0)
                (charger / "online").write_text("0")
                manager.battery_preflight()
            finally:
                manager.POWER_ROOT, manager.CONFIG = original_root, original_cfg

    # ---- device console backend ----
    DEVICE_STAT = "1 (systemd) S 0 1 1 0 -1 4194560 63777 1432996 98 384 530 331 7133 3971 20 0 1 0 0 23101440 3665 18446744073709551615 1 1 0 0 0 0 671173123 4096 1260 0 0 0 17 2 0 0 0 0 0 0 0 0 0 0 0 0 0"

    def test_parse_proc_stat_matches_device_layout(self):
        st = manager.parse_proc_stat(self.DEVICE_STAT)
        self.assertEqual(st["comm"], "systemd")
        self.assertEqual((st["state"], st["ppid"], st["utime"], st["stime"]), ("S", 0, 530, 331))
        self.assertEqual((st["nice"], st["threads"], st["starttime"], st["rss_pages"]), (0, 1, 0, 3665))
        # comm may itself contain spaces and parentheses
        weird = self.DEVICE_STAT.replace("(systemd)", "(a (weird) name)")
        self.assertEqual(manager.parse_proc_stat(weird)["comm"], "a (weird) name")
        self.assertIsNone(manager.parse_proc_stat("garbage"))

    def test_thermal_groups_take_hottest_per_group(self):
        zones = [{"name": "cpu0-thermal", "temp_c": 50.0}, {"name": "cpu7-thermal", "temp_c": 61.5},
                 {"name": "gpuss0-thermal", "temp_c": 40.0}, {"name": "qcom_qg", "temp_c": 32.4}, {"name": "aoss0-thermal", "temp_c": 99.0}]
        self.assertEqual(manager.thermal_groups(zones), {"cpu": 61.5, "gpu": 40.0, "battery": 32.4})

    def test_listening_ports_and_mounts_parse_proc(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "net").mkdir()
            (root / "net" / "tcp").write_text(
                "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                "   0: 0100007F:1B9E 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10000        0 1 1 0 10 0\n"
                "   1: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000 10000        0 2 1 0 10 0\n")
            (root / "net" / "tcp6").write_text(
                "  sl  local_address rem_address st\n"
                "   0: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 0 0 0 0 0 0 0 0\n")
            (root / "mounts").write_text("proc /proc proc rw 0 0\n/dev/fake0 /tmp ext4 rw,relatime 0 0\n/dev/fake0 /tmp ext4 rw 0 0\n/dev/fake0 /tmp/bind ext4 rw 0 0\n")
            original = manager.PROC_ROOT
            manager.PROC_ROOT = root
            try:
                ports = manager.listening_ports()
                mounts = manager.mounts()
            finally:
                manager.PROC_ROOT = original
            self.assertEqual([(p["port"], p["proto"], p["host"]) for p in ports], [(22, "tcp6", "::"), (7070, "tcp", "127.0.0.1")])
            self.assertEqual(ports[1]["service"], "phoenix console")
            self.assertEqual(len(mounts), 1)
            self.assertEqual((mounts[0]["mountpoint"], mounts[0]["fstype"]), ("/tmp", "ext4"))
            self.assertGreater(mounts[0]["total_bytes"], 0)

    def test_signal_process_guards(self):
        with self.assertRaisesRegex(ValueError, "pid 0 or 1"):
            manager.signal_process(1, "TERM")
        with self.assertRaisesRegex(ValueError, "console itself"):
            manager.signal_process(os.getpid(), "TERM")
        with self.assertRaisesRegex(ValueError, "signal must be"):
            manager.signal_process(99999999, "STOP")

    def test_journal_rejects_unsafe_unit_names(self):
        with self.assertRaisesRegex(ValueError, "invalid unit"):
            manager.journal_tail(10, "phoenix; rm -rf /")

    def test_system_sampler_runs_without_proc_and_sorts_processes(self):
        sampler = manager.SystemSampler(start=False, maxlen=4, interval=1)
        first = sampler.sample_once()
        second = sampler.sample_once()
        self.assertIn("t", first)
        self.assertEqual(len(sampler.history), 2)
        self.assertIsInstance(second["mem_used"], int)
        sampler.processes = [
            {"pid": 10, "name": "zeta", "cmdline": "zeta --x", "user": "user", "cpu_percent": 5.0, "rss_bytes": 100, "elapsed_s": 5},
            {"pid": 20, "name": "alpha", "cmdline": "/usr/bin/alpha", "user": "root", "cpu_percent": 1.0, "rss_bytes": 900, "elapsed_s": 50},
            {"pid": 30, "name": "mid", "cmdline": "", "user": "user", "cpu_percent": 3.0, "rss_bytes": 500, "elapsed_s": 500},
        ]
        self.assertEqual([r["pid"] for r in sampler.process_report("cpu")["rows"]], [10, 30, 20])
        self.assertEqual([r["pid"] for r in sampler.process_report("mem")["rows"]], [20, 30, 10])
        self.assertEqual([r["name"] for r in sampler.process_report("name")["rows"]], ["alpha", "mid", "zeta"])
        self.assertEqual(sampler.process_report("cpu", limit=1)["rows"][0]["pid"], 10)
        self.assertEqual([r["pid"] for r in sampler.process_report("cpu", query="root")["rows"]], [20])
        self.assertEqual(sampler.process_report("cpu", query="30")["total"], 1)

    def test_battery_history_rows_carry_chart_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            battery, charger = root / "qcom_qg", root / "pm8150b-charger"
            battery.mkdir(); charger.mkdir()
            for name, value in {"voltage_avg": "4300000", "current_now": "1000", "temp": "320"}.items():
                (battery / name).write_text(value)
            for name, value in {"online": "1", "voltage_now": "5000000", "current_now": "300000"}.items():
                (charger / name).write_text(value)
            original = manager.POWER_ROOT
            manager.POWER_ROOT = root
            try:
                sampler = manager.BatterySampler(start=False)
                # drive one iteration of the loop body without the thread
                snap = sampler.snapshot()
            finally:
                manager.POWER_ROOT = original
            self.assertEqual(snap["charger"]["input_power_w"], 1.5)

if __name__ == "__main__":
    unittest.main()
