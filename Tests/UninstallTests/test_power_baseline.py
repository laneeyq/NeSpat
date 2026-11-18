import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('power_baseline', Path(__file__).parents[2]/'scripts/power_baseline.py')
baseline = importlib.util.module_from_spec(spec); spec.loader.exec_module(baseline)
FULL = 'Battery Power:\n sleep 0\n Sleep On Power Button 1\nAC Power:\n sleep 0\n Sleep On Power Button 1\n'

class PowerBaselineTests(unittest.TestCase):
    def sample(self):
        return dict(version=1, SleepDisabled=False, raw_custom=FULL, profiles=baseline.parse_custom(FULL),
                    context=dict(uid=501, boot='boot', os='build', architecture='arm64', pmset_sha256='hash'))
    def test_partial_is_not_absence_of_battery_settings(self):
        with self.assertRaises(ValueError): baseline.parse_custom('AC Power:\n sleep 0\n')
    def test_complete_matching_context(self):
        before=self.sample(); after=copy.deepcopy(before); after['timestamp_UTC']='later'
        baseline.compare(before, after)
    def test_all_modes_compared_even_if_on_ac(self):
        after=self.sample(); after['raw_custom']=FULL.replace('sleep 0', 'sleep 1', 1)
        after['profiles']=baseline.parse_custom(after['raw_custom'])
        with self.assertRaises(ValueError): baseline.compare(self.sample(),after)
    def test_context_change_stops(self):
        after=self.sample(); after['context']['boot']='new'
        with self.assertRaises(ValueError): baseline.compare(self.sample(),after)
    def test_malformed_unknown_duplicate_and_empty_stop(self):
        for raw in ['',FULL+'AC Power:\n sleep 0\n',FULL+'UPS Power:\n sleep 0\n',FULL+' sleep 0\n', 'sleep 0\n'+FULL]:
            with self.subTest(raw=raw), self.assertRaises(ValueError): baseline.parse_custom(raw)
    def test_unknown_power_and_inconsistent_payload_stop(self):
        for key,value in [('SleepDisabled',None),('profiles',{'AC Power':{}}),('version',2)]:
            after=self.sample(); after[key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): baseline.compare(self.sample(),after)
