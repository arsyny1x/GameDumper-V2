# GameDumper V2

A Roblox script dumper and decompiler utility designed to scan live game services, collect script instances, attempt decompilation, and save the output as local Lua files.

This project is built as a single Lua script that creates a small in-game UI, supports multiple executors, and can dump scripts from selected services such as `ReplicatedStorage`, `StarterPlayer`, `StarterGui`, and others.

## Features

- Dumps Lua/LocalScript/ModuleScript instances from selected Roblox services
- Scans service trees and exports script metadata and hierarchy
- Attempts decompilation using supported executor APIs or remote decompilation services
- Writes dumped code to a structured output folder
- Includes a crash blacklist to skip previously crashing scripts
- Supports safe mode and the option to ignore default Roblox scripts
- Provides a live progress UI with start/stop controls
- Can toggle the interface with the `Insert` key

## Project Structure

- `main.lua` — main script containing the dumper, UI, file writing logic, and decompiler adapters

## How It Works

1. The script initializes a GUI and connects UI controls.
2. It enumerates selected services and scans their descendants.
3. It identifies dumpable scripts (`LocalScript`, `ModuleScript`, and some client-side `Script` instances).
4. It checks for bytecode size and supported decompilation methods.
5. It writes the output to a folder structure similar to:

```text
GameDumps/
  Place_<PlaceId>/
    YYYY-MM-DD_HH-MM-SS/
      <Service>/<ScriptName...>.lua
      summary.txt
      hierarchy.txt
```

## Supported Decompiler Modes

The script supports multiple decompilation strategies, controlled by configuration:

- `bytefall` — uses the external ByteFall decompiler service
- `native` — uses the executor's built-in `decompile()` capability when available
- `custom` — uses a custom decompiler hook if provided
- `auto` — tries available modes in priority order
- `bytecode` — saves raw bytecode instead of decompiling

## Configuration Highlights

The script exposes several settings in `Config`, including:

- `GuiName` — UI name used for the in-game window
- `RootFolder` — output base folder (`GameDumps` by default)
- `ToggleKey` — keyboard shortcut to show/hide the interface (`Insert` by default)
- `YieldEvery` — scan pacing interval to reduce lag
- `DecompileDelay` — delay between decompilation tasks
- `MaxBytecodeSize` — skip oversized bytecode entries
- `WriteHierarchy` — writes a hierarchy dump to a text file
- `SaveBytecode` — optionally saves `.luac` copies together with `.lua`

## Requirements

This script is meant to run inside a Roblox executor environment that supports:

- `writefile` / `syn.writefile` / equivalent
- `makefolder` / `syn.makefolder` / equivalent
- a decompilation API or executor support for `decompile()`

If your executor does not support file writing, the script will show a warning and stop before dumping.

## Usage

1. Open a Roblox game in your executor.
2. Paste `main.lua` into the executor.
3. The script will automatically build the GUI.
4. Select one or more services to dump.
5. Click `Start` to begin scanning and decompiling.
6. Use the `Insert` key or the floating `GD` button to show/hide the panel.
7. Output files are saved under the configured dump folder.

## Safety Notes

- Some script names are skipped automatically when they are considered standard Roblox scripts.
- The crash guard protects against scripts that caused crashes during a previous dump attempt.
- `Safe Mode` disables decompilation and is useful for testing the scan flow without executing decompilation logic.
- The script uses a blacklist mechanism to avoid reprocessing known risky script paths.

## Credits
This project developed by arsyny1x
