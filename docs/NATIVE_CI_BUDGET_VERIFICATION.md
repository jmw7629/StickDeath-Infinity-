# Native CI budget and cancelled-run evidence

Source `f3f34ef012804a0c0db8b91f7de98eb0b14de082`, run 34728363046, passed every production stage and the actual iOS app build. The native job was cancelled by its overall 50-minute limit; the check annotation explicitly reports that deadline. The final iPhone result counts and recording are unavailable, so this run is not a native UI pass.

The job began at 00:35:48UTC. Production checks and the app build finished around 00:56:39; test setup reached a booted simulator around 00:59:07. That leaves less than 27 minutes before the overall deadline for a UI suite permitted to run 28 minutes, followed by result export and artifact upload. The previous 18-journey job used 49 minutes51 seconds overall.

The same single standard macos-15 job now has a 60-minute overall allowance. The 180-second per-test limit, 1680-second shared UI-suite limit, all 18 journeys and their assertions, serial simulator execution, build-worker limits and failure propagation remain unchanged. This fixes the containing job's budget; it does not make a failed test pass.

The production shell runner now registers its uniquely created evidence directory in the Actions output before invoking any long-running child. The existing always-run upload step can therefore retain partial evidence if the job is cancelled. Previously that output was written only after the test command returned, so cancellation skipped the main artifact upload. Missing or incomplete test results still leave a cancelled or failed gate; a directory is not a verification receipt.

A new controlled-process probe runs the actual shell script in a temporary Git fixture, blocks the selector with a fake child and cancels only that owned process group. It checks that the path was published before cancellation and that the same directory and marker survive. The probe failed against the previous script and passed after the correction. It does not execute or claim an iOS simulator test.

The complete final job log and cancellation annotations are preserved. Only the small simulator-setup artifact was listed; its temporary download links returned 403, so its bytes and CRC were not verified. The unavailable main UI artifact cannot be reconstructed from that setup record. The corrected source requires a new actual native run.
