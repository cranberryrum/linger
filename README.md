# linger

A macOS menu bar app that blurs your whole screen at a fixed interval and asks you to look far away for a moment. Built for one person's desk, not for sale.

Every ~20 minutes the screen frosts over, a short line appears ("Look far away"), a ring counts down 20 seconds, and the desk comes back. That's the whole product.

## What it does

- **Unmissable breaks** — a frosted-glass overlay covers every display, above full-screen apps and the menu bar. No clicks or keys reach what's underneath.
- **Heads-up first** — 60 s before a break a small card drops in top-right: *Start now*, or postpone by +1 / +10 / +15 min (up to three times per cycle). Swipe it away or hover to keep it around.
- **Final countdown at the cursor** — for the last 10 s a click-through pill trails the pointer: *Starting break in 4*.
- **Waits for you to finish** — if you're mid-typing at break time it waits for a 2 s pause (max 60 s). If you've been away for 3 min it counts that as a break and quietly resets.
- **Sleep and lock aware** — the timer pauses when the Mac sleeps or locks; a long gap counts as a break taken.
- **Three skip modes** — *Anytime*, *Hold to skip* (hold the button or Esc for one second), or *Never*.
- **Menu bar control** — time to next break, take a break now, postpone, pause for an hour / until tomorrow, and a Settings window with a live countdown card and preset sliders.
- **Global shortcut** — ⌃⌥⌘L starts a break from anywhere.
- **Soft sounds** — four synthesised tones (before, start, skip, end) from one instrument, all optional.

## Zero permissions

The blur is the app's own window filled with a system material, so macOS draws it without capturing pixels — no Screen Recording, no Accessibility. Idle detection reads the system's time-since-last-input value, which needs nothing either. The only optional item is *Launch at Login*, and the app explains it before asking.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 16 or later to build

## Build and run

```
git clone https://github.com/cranberryrum/linger.git
open linger/linger.xcodeproj
```

Select your own team under **Signing & Capabilities**, then ⌘R. The app has no Dock icon — look for the eye in the menu bar. First launch shows a four-screen onboarding; after that it lives entirely in the menu bar.

There are no dependencies and no package manager: SwiftUI for Settings and onboarding, AppKit for the overlay windows, menu bar item and panels.

## Testing without waiting

Settings → **Debug** shows the scheduler's live state and jumps straight to any moment in the cycle: heads-up at 70 s, cursor countdown at 12 s, break now, simulated sleep/wake, pause/resume, each sound, and a full reset to a fresh install.

## Project layout

| File | Role |
| --- | --- |
| `BreakScheduler.swift` | The state machine: working → heads-up → break → working, with postpones, idle reset, sleep/lock handling |
| `OverlayPresenter.swift` | One borderless `NSVisualEffectView` window per screen, fades, Esc handling |
| `BreakContentView.swift` | Message, countdown ring and skip / hold-to-skip controls |
| `HeadsUpPanelController.swift` | The 60 s card: postpone pills, swipe-to-dismiss, hover behaviour |
| `CursorCountdownController.swift` | The pill that follows the cursor for the last 10 s |
| `StatusItemController.swift` | Menu bar icon, countdown and menu |
| `SettingsView.swift`, `BreaksControls.swift` | Settings tabs, the Now card and preset sliders |
| `OnboardingView.swift` | First-run flow |
| `Motion.swift` | Shared easing curves and the entrance modifier |
| `Sounds.swift` | Synthesised sound palette |

## Design notes

Everything uses stock macOS components and system materials; the only custom-drawn element is the countdown ring. Motion follows two rules: UI that you see many times a day (menu bar, shortcuts) doesn't animate at all, and the break itself is deliberately slow and soft because slowing you down is the point. Reduce Motion and Reduce Transparency are honoured.

## License

MIT — see [LICENSE](LICENSE).
