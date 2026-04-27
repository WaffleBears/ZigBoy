# ZigBoy

A Game Boy and Game Boy Color emulator for Windows, written in Zig.

## Features

- Game Boy (DMG) and Game Boy Color (CGB) support
- Audio output via WaveOut
- Battery save support (.sav files written next to the ROM)
- Quick save states (F1/F3) and Save/Load State As...
- Drag and drop ROMs onto the window
- Pause, reset, mute, and turbo (hold Tab)
- Aspect-ratio preserved scaling

## Controls

| Key | Action |
| --- | --- |
| Arrow keys | D-pad |
| Z or X | A button |
| A | B button |
| Enter | Start |
| Right Shift or Backspace | Select |
| Tab (hold) | Turbo |
| F1 | Quick save state |
| F3 | Quick load state |
| P | Pause |
| R | Reset |
| M | Mute |
| O or Ctrl+O | Load ROM |
| Esc | Exit |

## Usage

Run the executable and pick a ROM from the file dialog, drag a `.gb` or `.gbc` file onto the window, or pass the ROM path on the command line:

```
ZigBoy.exe path\to\game.gbc
```

Battery-backed saves are written to `<rom>.sav` next to the ROM. Quick states are written to `<rom>.state`.

## Building

Requires Zig 0.16.0 or newer.

```
zig build
zig build run -- path\to\game.gbc
```

The build targets Windows by default and links against `user32`, `gdi32`, `winmm`, `comdlg32`, `shell32`, `ole32`, and `dwmapi`.

## Project Layout

```
src/
  main.zig       Win32 window, audio, input, file I/O
  gb.zig         Top-level system glue and frame stepping
  cpu.zig        SM83 CPU
  mmu.zig        Memory map and bus
  ppu.zig        Pixel processor (DMG and CGB)
  apu.zig        Audio processor
  cart.zig       Cartridge and MBC handling
  timer.zig      DIV/TIMA timer
  joypad.zig     Input
  savestate.zig  Save state serialization
```