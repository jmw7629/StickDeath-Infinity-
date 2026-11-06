"""Pure Python result-policy checks; no simulator/Swift/toolchain execution."""
from pathlib import Path
import copy
import importlib.util
import contextlib
import io
import plistlib
import tempfile
import time
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

class SetupPolicy(unittest.TestCase):
    def app(self, root, version):
        app = root / ("Xcode_" + version + ".app")
        developer = app / "Contents/Developer"
        swiftc = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        swiftc.parent.mkdir(parents=True)
        swiftc.write_bytes(b"mock; never executed")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString":version}))
        return developer, swiftc

    def test_selects_newest_Xcode26_clears_SDKROOT_and_resolves_its_compiler(self):
        with tempfile.TemporaryDirectory() as directory:
            apps = Path(directory).resolve(); self.app(apps, "26.3")
            developer, swiftc = self.app(apps, "26.10")
            calls = []
            def command(name, argv, seconds, cap):
                self.assertNotIn("SDKROOT", os.environ); calls.append(name)
                if name == "xcode-version": return b"Xcode 16.4\n"
                self.assertEqual(os.environ["DEVELOPER_DIR"],str(developer))
                return b"Xcode 26.10\n" if name == "selected-xcode-version" else str(swiftc).encode()
            with mock.patch.dict(os.environ,{"SDKROOT":"/wrong/MacOSX.sdk"},clear=True):
                result = verifier.configure_toolchain(command,applications=apps)
            self.assertEqual(result["swiftc"],str(swiftc))
            self.assertEqual(calls,["xcode-version","selected-xcode-version","selected-swiftc"])

    def test_current_Xcode26_stays_selected_and_rejects_foreign_compilers(self):
        with tempfile.TemporaryDirectory() as directory:
            apps=Path(directory).resolve();developer,swiftc=self.app(apps,"26.3")
            foreign=apps/"foreign";foreign.write_bytes(b"never executed")
            for found,requested,accept in [(swiftc,"swiftc",True),(foreign,"swiftc",False),(swiftc,str(foreign),False)]:
                with self.subTest(found=found,requested=requested), mock.patch.dict(os.environ,{"DEVELOPER_DIR":str(developer)},clear=True):
                    command=mock.Mock(side_effect=[b"Xcode 26.3\n",str(found).encode()])
                    if accept: self.assertEqual(verifier.configure_toolchain(command,requested,apps)["swiftc"],str(swiftc))
                    else:
                        with self.assertRaisesRegex(ValueError,"swiftc"):verifier.configure_toolchain(command,requested,apps)
                    self.assertEqual(command.call_count,2)

    def test_swiftc_symlink_preserves_selected_alias_and_rejects_escaped_target(self):
        with tempfile.TemporaryDirectory() as directory:
            apps=Path(directory).resolve();developer,swiftc=self.app(apps,"26.3")
            driver=swiftc.with_name("swift-driver")
            swiftc.rename(driver);swiftc.symlink_to(driver.name)
            with mock.patch.dict(os.environ,{"DEVELOPER_DIR":str(developer)},clear=True):
                command=mock.Mock(side_effect=[b"Xcode 26.3\n",str(swiftc).encode()])
                result=verifier.configure_toolchain(command,str(driver),apps)
                self.assertEqual(result["swiftc"],str(swiftc))
                self.assertNotEqual(result["swiftc"],str(driver))
                self.assertEqual(Path(result["swiftc"]).resolve(),driver)
            foreign=apps/"foreign-driver";foreign.write_bytes(b"never executed")
            swiftc.unlink();swiftc.symlink_to(foreign)
            with mock.patch.dict(os.environ,{"DEVELOPER_DIR":str(developer)},clear=True):
                command=mock.Mock(side_effect=[b"Xcode 26.3\n",str(swiftc).encode()])
                with self.assertRaisesRegex(ValueError,"selected Xcode toolchain"):
                    verifier.configure_toolchain(command,applications=apps)
                self.assertEqual(command.call_count,2)

    def test_missing_or_misreported_Xcode26_stops_without_fallback(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ,{},clear=True):
            apps=Path(directory).resolve();command=mock.Mock(return_value=b"Xcode 16.4\n")
            with self.assertRaisesRegex(ValueError,"Xcode26"):verifier.configure_toolchain(command,applications=apps)
            self.assertEqual(command.call_count,1)
            self.app(apps,"26.3");command.reset_mock()
            with self.assertRaisesRegex(ValueError,"not Xcode26"):verifier.configure_toolchain(command,applications=apps)
            self.assertEqual(command.call_count,2)

    def selector(self):
        sys.path.insert(0,str(ROOT/"scripts/native-smoke"))
        import select_simulator
        return select_simulator

    def test_readiness_is_one_read_only_inventory_before_one_creator(self):
        selector=self.selector()
        command=mock.Mock(return_value=b'{"devices":{},"runtimes":[],"devicetypes":[]}')
        with mock.patch.object(selector,"create_fresh",return_value="owned") as create:
            self.assertEqual(verifier.prepare_fresh_simulator(command,selector,time.monotonic()+900),"owned")
            create.assert_called_once_with("iphone")
        command.assert_called_once_with("coresimulator-readiness",["xcrun","simctl","list","--json"],60,cap=selector.INVENTORY_CAP)

    def test_failed_malformed_or_budget_exhausted_readiness_never_creates(self):
        selector=self.selector()
        for command,remaining in [(mock.Mock(side_effect=RuntimeError("failed")),900),
                                  (mock.Mock(return_value=b"{}"),900),
                                  (mock.Mock(return_value=b'{"devices":{},"runtimes":[],"devicetypes":[]}'),100)]:
            with self.subTest(remaining=remaining), mock.patch.object(selector,"create_fresh") as create:
                with self.assertRaises((RuntimeError,ValueError)):verifier.prepare_fresh_simulator(command,selector,time.monotonic()+remaining)
                create.assert_not_called();self.assertEqual(command.call_count,1)

    def test_nested_creator_failure_is_not_retried(self):
        selector=self.selector();command=mock.Mock(return_value=b'{"devices":{},"runtimes":[],"devicetypes":[]}')
        with mock.patch.object(selector,"create_fresh",side_effect=ValueError("initial-inventory failed")) as create:
            with self.assertRaisesRegex(ValueError,"initial-inventory"):verifier.prepare_fresh_simulator(command,selector,time.monotonic()+900)
            create.assert_called_once_with("iphone");self.assertEqual(command.call_count,1)

    def test_marker_diagnostic_preserves_failure_facts_but_never_device_authority(self):
        selector=self.selector();run={"runID":"123"}
        value={"version":1,"run":run,"sourceCommit":"9"*40,"state":"failed",
               "steps":[{"stage":"initial-inventory","returnCode":17,"timedOut":False}]}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();marker=root/selector.MARKER;marker.write_text(json.dumps(value))
            report=verifier.creator_failure_diagnostic(root,selector,run,"9"*40)
            self.assertEqual(report["creator"]["steps"][-1],value["steps"][-1])
            self.assertTrue(report["diagnosticOnlyNoDeviceAuthority"])
            with self.assertRaisesRegex(ValueError,"another source/run"):verifier.creator_failure_diagnostic(root,selector,{"runID":"456"},"9"*40)
            marker.write_bytes(b"x"*(selector.MARKER_CAP+1))
            with self.assertRaisesRegex(ValueError,"Unsafe"):verifier.creator_failure_diagnostic(root,selector,run,"9"*40)
            marker.unlink();marker.symlink_to(root/"absent")
            with self.assertRaises(OSError):verifier.creator_failure_diagnostic(root,selector,run,"9"*40)

    def test_main_restores_environment_and_retains_actual_readiness_failure(self):
        for scenario in ("readiness","creator"):
            selector=self.selector()
            import seed_diagnostics
            cwd=Path.cwd()
            with tempfile.TemporaryDirectory() as directory:
                temp=Path(directory).resolve();fake=temp/"repo"
                panel=fake/"StickDeathInfinity/Views/Studio/Panels/ToolSettingsPanel.swift"
                panel.parent.mkdir(parents=True)
                panel.write_text("private struct ToolSettingsContentHeight:\nmock helper\nprivate enum StudioImagePlacementField:")
                script=fake/"Tests/StudioPopupLayout/verify_layout.py";script.parent.mkdir(parents=True)
                script.with_name("Harness.swift").write_text("mock harness; never compiled")
                sdk=temp/"iPhoneSimulator.sdk";sdk.mkdir();output=temp/"probe";calls=[]
                def configure(*args):
                    os.environ.pop("SDKROOT",None);os.environ["DEVELOPER_DIR"]="/selected/Xcode26"
                    return {"swiftc":"/selected/Xcode26/swiftc","version":"Xcode 26.3"}
                def bounded(argv,deadline,stdout_cap,stderr_cap):
                    self.assertNotIn("SDKROOT",os.environ);self.assertEqual(os.environ["DEVELOPER_DIR"],"/selected/Xcode26")
                    calls.append((argv,deadline));data=b"";code=0
                    if argv[:3]==["git","rev-parse","--verify"]:data=("9"*40).encode()
                    elif argv[:2]==["xcrun","--sdk"]:data=str(sdk).encode()
                    elif argv[:3]==["xcrun","simctl","list"]:
                        if scenario=="readiness":code=17
                        else:data=b'{"devices":{},"runtimes":[],"devicetypes":[]}'
                    return seed_diagnostics.Result(code,False,0.01,stdout=data,stdout_seen=len(data))
                def create_failure(device):
                    marker={"version":1,"run":{"runID":"123","runAttempt":"1","job":"production"},
                            "sourceCommit":"9"*40,"state":"failed","createAttempted":False,
                            "steps":[{"stage":"initial-inventory","returnCode":17,"timedOut":False}]}
                    (temp/selector.MARKER).write_text(json.dumps(marker))
                    raise ValueError("nested initial-inventory failed")
                sink=io.TextIOWrapper(io.BytesIO(),write_through=True)
                try:
                    with mock.patch.dict(os.environ,{"SDKROOT":"/original/MacOSX.sdk","DEVELOPER_DIR":"/original/Xcode16"},clear=True), \
                         mock.patch.object(verifier,"ROOT",fake), mock.patch.object(verifier,"__file__",str(script)), \
                         mock.patch.object(verifier.platform,"system",return_value="Darwin"), mock.patch.object(verifier.platform,"machine",return_value="arm64"), \
                         mock.patch.object(selector,"context",return_value=(temp,{"runID":"123","runAttempt":"1","job":"production"})), \
                         mock.patch.object(selector,"create_fresh",side_effect=create_failure) as create, mock.patch.object(verifier,"configure_toolchain",side_effect=configure), \
                         mock.patch.object(seed_diagnostics,"run_bounded",side_effect=bounded), \
                         mock.patch.object(sys,"argv",["verify_layout.py","--output-directory",str(output)]),contextlib.redirect_stderr(sink):
                        with self.assertRaisesRegex(SystemExit,"coresimulator-readiness" if scenario=="readiness" else "initial-inventory"):verifier.main()
                        self.assertEqual(os.environ["SDKROOT"],"/original/MacOSX.sdk")
                        self.assertEqual(os.environ["DEVELOPER_DIR"],"/original/Xcode16")
                        if scenario=="readiness":create.assert_not_called()
                        else:create.assert_called_once_with("iphone")
                    report=json.loads((output/"result.json").read_text())
                    self.assertEqual(report["state"],"FAIL")
                    if scenario=="creator":
                        self.assertEqual(report["creatorFailureDiagnostic"]["creator"]["steps"][-1],
                                         {"stage":"initial-inventory","returnCode":17,"timedOut":False})
                        self.assertIn(b"STUDIO_POPUP_CREATOR_DIAGNOSTIC=",sink.buffer.getvalue())
                    self.assertEqual(report["steps"][-1]["returnCode"],17 if scenario=="readiness" else 0)
                    self.assertIs(report["steps"][-1]["timedOut"],False)
                    self.assertEqual([report[k] for k in ("compileBudgetSeconds","appRunBudgetSeconds","overallBudgetSeconds")],[240,30,900])
                    self.assertEqual(sum(argv[:3]==["xcrun","simctl","list"] for argv,_ in calls),1)
                finally:os.chdir(cwd)

if __name__=="__main__":
    unittest.main(verbosity=2)
