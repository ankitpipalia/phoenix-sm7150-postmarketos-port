#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile
import threading
import time
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
        # A viewer is on the Tasks page, so the table is live, not rescanned.
        sampler._process_demand_until = manager.time.monotonic() + 60
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

    # ---- 2026-09-27 recheck: fixes and previously untested post-session edits ----
    def test_decode_proc_addr_ipv4_and_ipv6(self):
        self.assertEqual(manager.decode_proc_addr("0100007F"), "127.0.0.1")
        self.assertEqual(manager.decode_proc_addr("00000000"), "0.0.0.0")
        # loopback must never be rendered as "all addresses"
        self.assertEqual(manager.decode_proc_addr("00000000000000000000000001000000"), "::1")
        self.assertEqual(manager.decode_proc_addr("00000000000000000000000000000000"), "::")
        self.assertEqual(manager.decode_proc_addr("0000000000000000FFFF00000100007F"), "::ffff:127.0.0.1")
        with self.assertRaises(ValueError):
            manager.decode_proc_addr("0100")

    def test_listening_ports_keeps_loopback_ipv6_distinct(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "net").mkdir()
            (root / "net" / "tcp").write_text("  sl local rem st\n")
            (root / "net" / "tcp6").write_text(
                "  sl  local_address rem_address st\n"
                "   0: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A 0 0 0 0 0 0 0 0\n"
                "   1: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 0 0 0 0 0 0 0 0\n")
            original = manager.PROC_ROOT
            manager.PROC_ROOT = root
            try:
                ports = manager.listening_ports()
            finally:
                manager.PROC_ROOT = original
            self.assertEqual([(p["port"], p["host"]) for p in ports], [(22, "::"), (631, "::1")])

    def test_query_string_is_percent_decoded(self):
        handler = manager.Handler.__new__(manager.Handler)
        handler.path = "/api/journal?unit=bootmac%40bluetooth.service&q=a+b&lines=50&empty="
        q = handler._query()
        self.assertEqual(q["unit"], "bootmac@bluetooth.service")
        self.assertEqual(q["q"], "a b")
        self.assertEqual(q["lines"], "50")
        self.assertEqual(q["empty"], "")
        self.assertTrue(manager.UNIT_NAME.match(q["unit"]))

    def test_battery_preflight_fails_closed_without_plausible_voltage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            charger, battery = root / "pm8150b-charger", root / "qcom_qg"
            charger.mkdir(); battery.mkdir()
            (charger / "online").write_text("1")
            (battery / "voltage_avg").write_text("6377865")  # boot glitch, and no voltage_now
            original = manager.POWER_ROOT
            manager.POWER_ROOT = root
            try:
                with self.assertRaisesRegex(RuntimeError, "unavailable or implausible"):
                    manager.battery_preflight()
            finally:
                manager.POWER_ROOT = original

    def test_process_table_is_lazy_when_nobody_is_looking(self):
        sampler = manager.SystemSampler(start=False, maxlen=4, interval=1)
        calls = []
        real = sampler._process_table
        sampler._process_table = lambda delta: (calls.append(delta), real(delta))[1]
        sampler.sample_once(); sampler.sample_once()
        self.assertEqual(calls, [], "idle sampler must not scan /proc/<pid>")
        self.assertIsInstance(sampler.snapshot()["process_count"], int)
        sampler.process_report("cpu")          # a viewer arrives: immediate table
        self.assertEqual(len(calls), 1)
        sampler.sample_once()                  # and the loop keeps it fresh while in demand
        self.assertEqual(len(calls), 2)
        sampler._process_demand_until = 0      # viewer left
        sampler.sample_once()
        self.assertEqual(len(calls), 2)

    def test_battery_sampler_survives_errors_and_integrates_power(self):
        sampler = manager.BatterySampler(start=False)
        snaps = iter([
            {"timestamp": 1.0, "battery": {"current_now": -100000, "voltage_now": 4000000}, "charger": {}},
            {"timestamp": 2.0, "battery": {"current_now": -300000, "voltage_now": 3800000}, "charger": {}},
        ])
        sampler.snapshot = lambda: next(snaps)
        clock = iter([100.0, 110.0])
        original = manager.time.monotonic
        manager.time.monotonic = lambda: next(clock)
        try:
            sampler._sample(); sampler._sample()
        finally:
            manager.time.monotonic = original
        # 10 s: charge = 0.2 A avg -> 0.5556 mAh; energy = mean(P) = (0.4 W + 1.14 W)/2
        self.assertAlmostEqual(sampler.discharged_mah, 200000 * 10 / 3_600_000, places=6)
        self.assertAlmostEqual(sampler.discharged_mwh, (0.4e12 + 1.14e12) / 2 * 10 / 3_600_000_000_000, places=6)
        # an exception inside one sample must not escape the loop body
        sampler.snapshot = lambda: (_ for _ in ()).throw(OSError("transient"))
        with self.assertRaises(OSError):
            sampler._sample()   # _sample raises; _loop wraps it (checked below)
        self.assertIn("except Exception", __import__("inspect").getsource(manager.BatterySampler._loop))

    def test_cache_helper_is_defined_before_the_battery_sampler(self):
        source = Path(MODULE_PATH).read_text()
        self.assertLess(source.index("def cached("), source.index("BATTERY = BatterySampler("))

    def test_thermal_guard_does_nothing_without_a_runtime(self):
        original_snapshot, original_state = manager.thermal_snapshot, manager.RUNTIME._state
        def forbidden():
            raise AssertionError("thermal zones read with no runtime running")
        manager.thermal_snapshot = forbidden
        manager.RUNTIME._state = lambda: {}
        try:
            self.assertEqual(manager.thermal_guard_step(2), 0)
        finally:
            manager.thermal_snapshot, manager.RUNTIME._state = original_snapshot, original_state

    def test_thermal_guard_stops_a_hot_runtime_after_three_ticks(self):
        saved = (manager.thermal_snapshot, manager.RUNTIME._state, manager.RUNTIME._owned_pid, manager.RUNTIME.stop)
        stops = []
        manager.thermal_snapshot = lambda: {"hottest": {"name": "cpu7-thermal", "temp_c": manager.CONFIG.thermal_critical_c + 1}}
        manager.RUNTIME._state = lambda: {"pid": 4242}
        manager.RUNTIME._owned_pid = lambda pid: pid == 4242
        manager.RUNTIME.stop = lambda: stops.append(1)
        try:
            n = 0
            for _ in range(2):
                n = manager.thermal_guard_step(n)
            self.assertEqual((n, stops), (2, []))
            self.assertEqual(manager.thermal_guard_step(n), 0)
            self.assertEqual(stops, [1])
            # a cool reading resets the count
            manager.thermal_snapshot = lambda: {"hottest": {"name": "cpu7-thermal", "temp_c": 50.0}}
            self.assertEqual(manager.thermal_guard_step(2), 0)
        finally:
            (manager.thermal_snapshot, manager.RUNTIME._state, manager.RUNTIME._owned_pid, manager.RUNTIME.stop) = saved

    def test_thermal_reads_are_reused_within_the_ttl(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            zone = root / "thermal_zone0"; zone.mkdir()
            (zone / "type").write_text("cpu0-thermal"); (zone / "temp").write_text("40000")
            original = manager.THERMAL_ROOT
            manager.THERMAL_ROOT = root
            calls = []
            real = manager._read_thermal_zones
            manager._read_thermal_zones = lambda: (calls.append(1), real())[1]
            try:
                first = manager.thermal_snapshot()
                (zone / "temp").write_text("99000")          # changes within the TTL are not re-read
                second = manager.thermal_snapshot()
            finally:
                manager.THERMAL_ROOT, manager._read_thermal_zones = original, real
            self.assertEqual(len(calls), 1)
            self.assertEqual(first, second)
            self.assertEqual(first["hottest"]["temp_c"], 40.0)

    def test_thermal_callers_that_miss_together_share_one_read(self):
        # The sweep is held open while the other callers arrive; without
        # single-flight each of them would start its own sweep.
        with tempfile.TemporaryDirectory() as temporary:
            original, real = manager.THERMAL_ROOT, manager._read_thermal_zones
            manager.THERMAL_ROOT = Path(temporary)
            calls, release, results = [], threading.Event(), []
            def slow_read():
                calls.append(1)
                release.wait(5)
                return real()
            manager._read_thermal_zones = slow_read
            start = threading.Barrier(4)
            def caller():
                start.wait()
                results.append(manager.thermal_snapshot())
            threads = [threading.Thread(target=caller) for _ in range(4)]
            try:
                for thread in threads:
                    thread.start()
                time.sleep(0.3)
                release.set()
                for thread in threads:
                    thread.join(5)
            finally:
                release.set()
                manager.THERMAL_ROOT, manager._read_thermal_zones = original, real
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(results), 4)
            self.assertTrue(all(r is results[0] for r in results))

if __name__ == "__main__":
    unittest.main()
