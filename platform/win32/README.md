# KOReader for Windows

Native Windows (x86-64) port of KOReader: no emulation layer, no POSIX runtime
(like MSYS2 or Cygwin), just a regular Windows application.

Requirements: Windows 10 (version 1903 or later) or Windows 11, 64-bit.

## Installation

Two flavors are released (see the `koreader-win32-x86_64-*` assets):

- **Installer** (`…-setup.exe`): per-user installation (no administrator
  rights needed), in `%LOCALAPPDATA%\Programs\KOReader` by default. It creates
  Start menu (and optionally desktop) shortcuts, registers KOReader in the
  "Open with" menu of the supported document types, and can be uninstalled
  from the Windows settings. Upgrading is done by simply running the installer
  of the new version. Silent installation: `…-setup.exe /S [/D=C:\Path\To\KOReader]`.
- **Portable archive** (`….zip`): extract it anywhere (e.g. on a USB stick) and
  run `koreader.exe`.

Documents can also be opened from the command line: `koreader.exe C:\Books\book.epub`.

## Data location

KOReader stores its settings and data (reading history, caches, dictionaries,
fonts, etc.) in:

1. the folder specified by the `KO_HOME` environment variable, if set;
2. otherwise, the installation folder, if it contains a `portable.txt` file
   (that's the case with the portable archive);
3. otherwise, `%LOCALAPPDATA%\KOReader`.

Fonts installed in Windows for the current user can be used directly, and the
ones installed system-wide once "Enable system fonts" is checked (in the font
settings menu).

The file browser starts in the user's documents folder; its root (`/`) lists
the available drives.

## Troubleshooting

KOReader's output is logged to `crash.log` in the data location (the previous
log is kept as `crash.log.old`). If KOReader terminates unexpectedly, a dialog
offers to open that log.

## Differences with other platforms

Windows has no `fork()`: the background tasks (cover and metadata extraction,
Wikipedia, translations, OPDS & news downloads, file & collection searches…)
are run in "worker" processes instead (c.f. `frontend/worker.lua`), so they
don't block the UI, and can be cancelled, like on other platforms.

Only the tasks that need the document currently opened are run in KOReader's
own process: page thumbnails (book map / page browser, showing only the page
contents, without highlights) and search in the current book.

The following plugins are not available: SSH, terminal, time sync, external
keyboard, auto frontlight.

## Technical overview

- `koreader.exe` (`launcher.c`) is a small native launcher: it determines and
  prepares the data location and log file, then runs the reader (the same
  executable, embedding LuaJIT) in a child process, and restarts it when asked
  to (e.g. after a change of some settings).
- The executables are built with an application manifest enabling UTF-8 as
  the process code page, long paths support, and per-monitor DPI awareness:
  all file names are handled as UTF-8, like on other platforms.
- On the Lua side, paths use forward slashes (`C:/Users/…`), Windows specific
  code lives in `ffi/win32.lua` (koreader-base), and some POSIX APIs are mapped
  to their equivalent in the Universal C Runtime (`ffi/posix_h_win32.lua`).
- Worker processes are `luajit.exe` instances, set up like KOReader (with the
  same settings), but headless: they get their task from their standard
  input, and send back its results on their standard output.

## Building

KOReader for Windows is cross-compiled with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)
(Clang, LLD and the Universal C Runtime), the installer is built with NSIS.
The [`Dockerfile`](Dockerfile) in this directory provides a ready-to-use
toolchain image.

On Linux (or in that image):

```
./kodev release win32
```

On Windows (or any other host with Docker, e.g. Docker Desktop), from Git Bash
or WSL:

```
platform/win32/build.sh
```

That script builds the toolchain image, synchronizes the sources into a Docker
volume (where the build runs, and incremental build outputs are kept), and
copies the resulting release archives (`koreader-win32-x86_64-*.zip` and
`…-setup.exe`) back into the checkout.

**NOTE:** the build system does not support CRLF line endings, so on Windows
clone the repository with `git clone -c core.autocrlf=false …` (the script
explains how to convert an existing checkout).
