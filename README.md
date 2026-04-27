## ZigBoy

A Game Boy, Game Boy Color, and Game Boy Advance emulator for Windows, written in Zig.

### Features

- Game Boy (GB), Game Boy Color (GBC), and Game Boy Advance (GBA) support
- Auto-detects ROM type by extension or header magic
- 10 save state slots per ROM
- Battery save support (`.sav` written next to the ROM)
- 5 selectable DMG palette presets (Classic Green, Grayscale, Autumn, Ocean Blue, Pocket)
- Volume control with smooth fade transitions
- Drag-and-drop ROM loading
- Fullscreen toggle, screenshot capture (PNG)
- Aspect-ratio-preserving and integer-only scaling modes
- Smooth and pixel-perfect texture filtering
- Pause, reset, mute, turbo (4×, hold Tab)
- Configurable settings panel (in-app, no config file required)

### Controls

| Key | Action |
| --- | --- |
| Arrow keys | D-pad |
| Z / X | A / B |
| A / S | L / R (GBA) |
| Enter | Start |
| Right Shift / Backspace | Select |
| Tab (hold) | Turbo (4×) |
| F1 or F5 | Save state |
| F3 or F7 | Load state |
| `[` / `]` | Previous / next state slot |
| - / = | Volume down / up |
| P | Pause |
| R | Reset |
| M | Mute |
| F11 | Toggle fullscreen |
| F12 | Take screenshot |
| Ctrl+O | Open ROM |
| Esc | Close menu |

### Usage

Run the executable and pick a ROM from the file dialog, drag a `.gb`, `.gbc`, or `.gba` file onto the window, or pass the ROM path on the command line:

```
ZigBoy.exe path\to\game.gba
```

- Battery saves: `<rom>.sav` written next to the ROM on exit and on ROM switch.
- Save state slot 0: `<rom>.state`. Slots 1-9: `<rom>.state1` … `<rom>.state9`.
- Screenshots: `<rom>_NNNN.png` next to the working directory, auto-numbered.

### Building

Requires Zig 0.16.0 or newer.

```
zig build                       # ReleaseFast (default)
zig build -Doptimize=Debug      # debug build with console
zig build run -- path\to\game.gba
```

raylib is fetched automatically via `build.zig.zon`. The build targets Windows by default and links against `user32`, `gdi32`, `winmm`, `comdlg32`, `shell32`, `ole32`, `kernel32`, `dwmapi`, and `opengl32`.

### Project Layout

```
src/
  main.zig          Entry point, main loop, mouse/click dispatch
  app.zig           App struct, types, ROM/state/input handlers
  draw.zig          UI rendering (toolbar, status bar, modals, placeholder)
  audio.zig         Audio stream pump with smooth gain transitions
  platform.zig      Windows file I/O and Open ROM dialog
  system.zig        GB/GBA backend dispatcher
  gb/               Game Boy / Color emulator core
    cpu.zig         SM83 CPU
    mmu.zig         Memory map and bus
    ppu.zig         Pixel processor (DMG and CGB)
    apu.zig         Audio processor
    cart.zig        Cartridge and MBC1/2/3/5 + RTC
    timer.zig       DIV/TIMA timer
    joypad.zig      Input
    savestate.zig   State serialization
    gb.zig          Top-level glue and frame stepping
  gba/              Game Boy Advance emulator core
    arm.zig         ARM7TDMI CPU (ARM and THUMB)
    bus.zig         Memory map, mirrors, wait states
    ppu.zig         PPU (modes 0-5, BG, OBJ, blending, mosaic, windows)
    apu.zig         APU (DMG channels + DirectSound A/B)
    cart.zig        ROM, EEPROM/Flash/SRAM, RTC
    bios.zig        BIOS HLE (SWI handlers, decompression)
    dma.zig         4-channel DMA
    timer.zig       4 timers with cascade
    irq.zig         Interrupt definitions
    gba.zig         Top-level glue and frame stepping
```

