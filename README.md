# rpi_mixxx_installer

A single Bash script, `install_mixxx_rpi5.sh`, that builds and installs the latest
stable **Mixxx 2.5.x** from the official sources on a **Raspberry Pi 5** running
**Debian 13 (Trixie) ARM64**.

## What it does

1. Detects the system: architecture (`aarch64`), Debian version, Raspberry Pi 5 model, CPU, RAM, GPU driver, disk space.
2. Checks the configured APT repositories without changing them.
3. Runs `apt update` and `apt full-upgrade` (skip the upgrade with `--no-upgrade`). The script never reboots on its own.
4. Resolves the build dependencies for Debian 13, checks their versions, simulates the install with `apt-get -s`, then installs only what is missing.
5. Finds the newest stable `2.5.x` tag in https://github.com/mixxxdj/mixxx.git, skipping alpha, beta and RC tags. It clones or updates `/opt/mixxx-source` and checks out that tag.
6. Builds a portable Release build as your normal user (not root). By default it uses `-j4` on a Pi 5, capped by available RAM.
7. Installs to a staging directory first and checks it (ARM64 binary, `ldd`, `mixxx --version`), then installs to `/usr/local`.
8. Checks the desktop launcher. On Wayland it can add an optional "Mixxx (XWayland)" launcher.
9. Reports the audio setup (ALSA, PipeWire, PulseAudio, JACK) and the USB audio and MIDI/HID devices it finds, without changing anything.
10. Runs final checks and prints a summary.

If the latest version is already installed, a second run does not rebuild anything.

## Usage

```bash
chmod +x install_mixxx_rpi5.sh
./install_mixxx_rpi5.sh --system-info          # show system info only
./install_mixxx_rpi5.sh --check-dependencies   # check dependencies only
sudo ./install_mixxx_rpi5.sh --dry-run         # show what would happen, change nothing
sudo ./install_mixxx_rpi5.sh                   # install
```

| Option | Description |
|---|---|
| `--help`, `--version` | Show help or the script version |
| `--system-info` | Detect and print system information only |
| `--check-dependencies` | Check dependency names, versions and installability only |
| `--dry-run` | Print the actions; apt, files, swap and audio are left untouched |
| `--no-upgrade` | Skip `apt full-upgrade` |
| `--skip-dependencies` | Skip the dependency stage |
| `--skip-build` | Don't configure or compile; install an existing build if there is one |
| `--force` | Rebuild and reinstall even if the version is already installed |
| `--jobs N` | Number of build jobs (default: safe value, at most 4) |
| `--configure-swap` | Offer temporary swap for the build if memory is low (asks first, not permanent) |
| `--no-external-downloads` | Disable Engine Prime export and KeyFinder (see notes) |
| `--verbose` | Show full command output |
| `-y`, `--yes` | Answer yes to prompts (Mixxx is never launched automatically) |
| `--enable-autostart` | Start Mixxx automatically after login (no rebuild, no root needed) |
| `--autostart-xwayland` | Same, but start Mixxx through XWayland (`QT_QPA_PLATFORM=xcb`) |
| `--disable-autostart` | Turn autostart off again |

## Autostart

```bash
./install_mixxx_rpi5.sh --enable-autostart     # or --autostart-xwayland
./install_mixxx_rpi5.sh --disable-autostart
```

This writes `~/.config/autostart/mixxx-autostart.desktop`, the standard XDG autostart location, for your user. Mixxx starts 5 seconds after you log in, so that PipeWire is already running. To have Mixxx start at boot without logging in, turn on desktop auto-login, for example with `sudo raspi-config` → System Options → Boot / Auto Login. The script checks whether auto-login is on but never changes it.

## Paths

| | |
|---|---|
| Sources | `/opt/mixxx-source` |
| Build | `/opt/mixxx-source/build` (kept on failure) |
| Executable | `/usr/local/bin/mixxx` |
| Log | `/var/log/mixxx-install.log`, or `~/mixxx-install.log` if `/var/log` is not writable |

## Notes

- **Safety:** the script never modifies APT sources, audio configuration, `~/.mixxx`, your music library, `/boot` or firmware. It never runs Mixxx as root.
- **External downloads during the build:** Mixxx 2.5.6 requires exactly libdjinterop 0.24.3, but Debian 13 ships 0.22.x. libkeyfinder is not packaged in Debian. Mixxx's own CMake downloads both from their official sources and verifies them with SHA256. Use `--no-external-downloads` to avoid this; Engine Prime export and KeyFinder key detection are then disabled.
- **`libgtest-dev` is required** even though tests are not built, because Mixxx sources include `gtest_prod.h`.
- **Wayland:** Debian starts Mixxx through XWayland (`-platform xcb`) because of Debian bug #1039859. On Wayland, the script can add a launcher that does the same.
- **GPU:** smooth waveforms need the `v3d` driver. Without it, Mixxx falls back to software rendering; choose simple waveforms in Preferences.

## License

See [LICENSE](LICENSE).
