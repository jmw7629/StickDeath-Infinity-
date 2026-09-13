# Native audio completion correction

Run 34731263030 at source 04ea35fc65f2e7d37fa7ed0238e3cfda8473dc37 passed the actual app build and every production stage. Seventeen of eighteen iPhone 16 Pro / iOS 18.5 journeys passed, including the corrected mixed MP4 preview, seek and sharing journey. Only the bundled sound-library journey failed: its captured UI remained stopped at 00:03.03 while the actual source duration was 00:03.06. Later volume and save/reopen assertions in that journey were not reached.

The complete log and 483,429,243-byte native artifact were retained. The artifact matched its published SHA256, all 1,669 ZIP entries passed CRC and path checks, and the actual source/configuration, test summary, hierarchy and recording were preserved. The five public backend settings were empty; UI preflight did not measure network requests.

The timeline clock previously stopped and released its AVAudioPlayer as soon as polling observed isPlaying=false. Its completion delegate dispatches onto the same actor. A clock poll could therefore clear the delegate and player identity before that queued callback confirmed the exact end.

A controlled production test reproduced this ordering with a real mixed CAF and AVAudioPlayer at zero audition gain. It held the actor while the short file ended, then invoked the actual production clock poll before releasing the queued completion callback. With only the poll's visibility made internal, the original behavior failed with the exact-end assertion. After the correction, all seventeen timeline production groups pass, including the original fifteen groups.

A stopped-engine poll now retains the player and owned output for the actual completion delegate. Only a successful delegate result sets the exact final time. If confirmation is absent for two seconds, playback ends with an explicit retryable error and the last known clock position. The bounded error branch is tested with controlled monotonic-clock advancement and a real player; it is not a physical-device interruption test. Existing one-shot callbacks, stale-context cancellation and identity-checked file cleanup remain covered.

Apple documents completion and interruption separately: [AVAudioPlayer completion callback](https://developer.apple.com/documentation/avfaudio/avaudioplayerdelegate/audioplayerdidfinishplaying(_:successfully:)). A stopped engine alone is not used as proof of successful completion.

The changed production body passes the iPhone SDK typecheck with all 120 app declarations. All eighteen native UI journeys, their assertions, the twelve-second end-time wait, per-test and suite deadlines remain unchanged. A new native run is required; local production checks do not establish a passing simulator result. No new assets, UI layout, backend, signing or publication behavior is included.
