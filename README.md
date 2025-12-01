Velocity-Vector: The "Chaos Proof" macOS Window Switcher
For the 5% of power users who've been silently gaslit by Alt+Tab.
Lua Hammerspoon Version

🛑 The Problem
If you are a Windows refugee on macOS, you know the pain.

Cmd+Tab switches apps, not windows.
Cmd+` is unreliable and loses context.
AltTab.app (and others) suffer from MRU Corruption when using multiple Workspaces (Spaces).
You switch spaces, try to bounce back to your previous window, and land on a random Terminal from 3 hours ago. You blame your muscle memory. It's not you. It's the architecture.

⚡ The Solution: Velocity-Vector
This is not just another window switcher. It is a Biomimetic State Machine written in Lua for Hammerspoon. It uses Velocity (Time) and Vector (Direction) to read your intent.

Key Features
🧠 Velocity-Aware Navigation:
Fast Tap (<300ms): "Panic Mode". Instantly bounces to the previous window (Index 2). No UI. Pure muscle memory.
Slow Tap (>300ms): "Browse Mode". Shows a full-screen preview and lets you cycle through windows (Index 3, 4, 5...).
🛡️ Titanium Core (v25.8 Eventtap):
Uses `hs.eventtap` to intercept keys at the OS level (O(1) latency).
Zero Lag: Bypasses the heavy `hs.hotkey` system entirely.
Robust: "Janitor" protocol prevents UI sticking by watching physical key releases.
⚓ Memory Anchors:
Pin a window (e.g., Slack or Terminal) with `Cmd+Opt+``.
Jump to it from anywhere. Jump back instantly.
🌌 Hybrid Bootstrap:
No startup lag. Uses a "Ghost Mode" (Z-order switch) for the first 40s while the heavy cache warms up in the background.
📦 Installation
Install Hammerspoon:

brew install --cask hammerspoon
Download the Script: Save 
init_titanium.lua
 to ~/.hammerspoon/init.lua.

Grant Permissions:

Hammerspoon needs Accessibility (to focus windows).
Hammerspoon needs Screen Recording (to take window snapshots).
Note: If you see a big "X" instead of a preview, you missed the Screen Recording permission.
Reload Config: Click the Hammerspoon icon in the menu bar -> Reload Config.

🎮 Controls
Hotkey	Action	Behavior
Cmd + `	Bounce / Browse	Fast Tap: Instant toggle (A <-> B).
Hold: Show UI and cycle (A -> B -> C).
Cmd + Shift + `	Reverse Cycle	Go backwards in the stack.
Cmd + Opt + `	Memory Anchor	Tap 1: Set Anchor (or Jump to it).
Tap 2: Jump back to where you were.
Cmd + Ctrl + `	Cycle Space	Move to the next macOS Workspace.
🏗️ Architecture: "v25.8 Eventtap"
The script uses `hs.eventtap` to solve the "Race Condition" and "System Conflict" bugs found in `hs.hotkey`.

Cmd+` (First Tap)
Idle
Passive Watcher
Window Focused/Created
Listening
UpdateList
Active
Fast Release (<300ms)
Hold (>300ms)
Release Cmd
Index2
Bounce
Browse
O(1) Activation\nUses Pre-warmed List
📜 License
MIT. Hack it. Fork it. Fix your workflow.R