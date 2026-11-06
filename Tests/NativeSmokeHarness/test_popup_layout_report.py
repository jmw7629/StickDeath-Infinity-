"""Pure Python result-policy checks; no simulator/Swift/toolchain execution."""
from pathlib import Path
import copy
import importlib.util
import json
import os
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
path = ROOT / "Tests/StudioPopupLayout/verify_layout.py"
spec = importlib.util.spec_from_file_location("popup_layout_verifier", path)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
ORIGINAL_CASES = (("short controls", 0, 360), ("long library", 30, 360),
                  ("compact landscape", 0, 88))
PREFIX = "STUDIO_POPUP_LAYOUT_RESULT="
IDENTITY={"nonce":"a"*32,"sourceCommit":"9"*40,"productionFileSHA256":"b"*64,
          "productionHelperSHA256":"c"*64,"harnessSHA256":"d"*64}

def valid():
    cases=[]
    for name,rows,bound in ORIGINAL_CASES:
        content=120 if rows==0 else 900
        cases.append({"name":name,"rows":rows,"width":236,"bound":bound,"passed":True,
                      "content":content,"viewport":min(content,bound),"fitting":min(content,bound),
                      "caseBudgetSeconds":1,"measurementSeconds":1.01})
    return {"version":1,"passed":3,"cases":cases,**IDENTITY}

def wire(value):
    return ("Simulator diagnostic\n"+PREFIX+json.dumps(value)+"\n").encode()

class ResultPolicy(unittest.TestCase):
    def rejects(self,value):
        with self.assertRaises((ValueError,TypeError,AttributeError)):
            verifier.validate_report(wire(value),IDENTITY)

    def test_accepts_all_three_measured_cases(self):
        self.assertEqual(verifier.CASES, ORIGINAL_CASES)
        self.assertEqual(verifier.PREFIX, PREFIX)
        data=valid()
        self.assertEqual(verifier.validate_report(wire(data),IDENTITY),data)

    def test_sentinel_without_measured_data_is_rejected(self):
        with self.assertRaises(ValueError):
            verifier.validate_report(b"STUDIO_POPUP_LAYOUT=PASS 3/3 actual hosted UIKit cases\n",IDENTITY)

    def test_every_source_hash_and_nonce_must_match(self):
        for key in IDENTITY:
            with self.subTest(key=key):
                data=valid();data[key]="wrong";self.rejects(data)

    def test_all_three_cases_in_exact_order_required(self):
        data=valid();data["cases"].pop();self.rejects(data)
        data=valid();data["cases"].reverse();self.rejects(data)
        data=valid();data["cases"][1]=data["cases"][0];self.rejects(data)

    def test_original_width_rows_bounds_and_budget_retained(self):
        for key in ("width","rows","bound","caseBudgetSeconds"):
            data=valid();data["cases"][0][key]+=1;self.rejects(data)
        data=valid();data["cases"][0]["rows"]=False;self.rejects(data)

    def test_zero_dimensions_cannot_pass(self):
        for key in ("content","viewport","fitting"):
            data=valid();data["cases"][0][key]=0;self.rejects(data)

    def test_exact_half_point_tolerance_stays_strict(self):
        for key in ("viewport","fitting"):
            data=valid();data["cases"][0][key]+=0.5;self.rejects(data)
            data=valid();data["cases"][0][key]+=0.499
            verifier.validate_report(wire(data),IDENTITY)

    def test_nonfinite_and_non_numeric_measurements_rejected(self):
        for value in (float("nan"),float("inf"),True,"120",None):
            for key in ("content","viewport","fitting","measurementSeconds"):
                data=valid();data["cases"][0][key]=value;self.rejects(data)

    def test_failure_flag_or_partial_success_never_passes(self):
        data=valid();data["failure"]="real app error";self.rejects(data)
        data=valid();data["passed"]=2;self.rejects(data)
        data=valid();data["cases"][0]["passed"]=False;self.rejects(data)
        data=valid();data["passed"]=True;self.rejects(data)

    def test_full_one_second_measurement_required(self):
        data=valid();data["cases"][0]["measurementSeconds"]=0.99;self.rejects(data)

    def test_missing_duplicate_oversized_or_malformed_result_rejected(self):
        for data in (b"",wire(valid())+wire(valid()),
                     (PREFIX+"x"*17000+"\n").encode(),
                     (PREFIX+"{notjson}\n").encode()):
            with self.assertRaises(ValueError):
                verifier.validate_report(data,IDENTITY)

    def test_non_CI_invocation_stops_before_any_SDK_command_or_output(self):
        repository=ROOT
        sys.path.insert(0,str(repository/"scripts/native-smoke"))
        import select_simulator
        output=ROOT/"must-not-be-created-popup-policy-check"
        self.assertFalse(output.exists())
        with mock.patch.dict(os.environ,{"GITHUB_ACTIONS":"false"},clear=True), \
             mock.patch.object(sys,"argv",["verify_layout.py","--output-directory",str(output)]), \
             mock.patch.object(select_simulator,"run_bounded",side_effect=AssertionError("SDK forbidden")):
            with self.assertRaisesRegex(ValueError,"ephemeral CI"):
                verifier.main()
        self.assertFalse(output.exists())

if __name__=="__main__":
    unittest.main(verbosity=2)
