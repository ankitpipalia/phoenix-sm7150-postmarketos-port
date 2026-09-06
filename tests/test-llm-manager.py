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


if __name__ == "__main__":
    unittest.main()
