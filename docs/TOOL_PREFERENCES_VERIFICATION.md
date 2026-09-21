# Independent drawing-tool preferences

Tracking: #140. This is a bounded Studio settings slice; remaining text, effects, eraser modes, selection-specific persistence and fill-specific controls are still tracked separately. It does not declare every visible control finished.

The native shared view model stores device preferences in a bounded, versioned UserDefaults record. Pencil starts at 2 document pixels; pen and round brush at 3; marker at 12 with 75% opacity and a calligraphy tip; crayon at 8 with grain and 90% opacity; eraser at 8 using its existing rendering scale. Shapes retain separate stroke/fill/radius settings. Current drawing color stays shared deliberately, while each brush's gradient endpoint is remembered. Selecting a tool again keeps the user's chosen family.

Size, opacity, smoothing, family, nib angle, texture, grain, gradient endpoint and shape fill/radius are independent per tool. The existing sole options popup contains Reset this tool; longer options remain within its measured scrolling region. These are device preferences, not document edits. Existing stroke descriptors and immutable input captures retain their own settings. No source membership or document schema change is needed.

Invalid, oversized, unknown-version and unknown-tool records fall back to defaults without touching stored project artwork. Reading a corrupt record does not overwrite it. Invalid runtime settings are not persisted, and remain subject to existing operation validation. A subsequent valid user settings edit replaces the preference record. UserDefaults persistence is standard OS-managed preference storage, not a claim of synchronous crash-durable disk flushing.

Verification uses the actual StudioViewModel, UserDefaults, canonical renderer and DeviceStorageManager: independent settings, fresh-instance restore, reset isolation, strict decoding, captured strokes, real pixel coverage, undo/redo and cold project reopen. The native UI journey adjusts real sliders, switches tools, draws, saves, terminates/relaunches, checks settings and exact canvas pixels, and resets through the actual popup. Compiling that journey alone is not proof it has executed.
