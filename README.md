# apex-anatase-fixes

A utility for automatically applying all necessary fixes and tweaks for the **OneXPlayer Apex** handheld console running [**Anatase OS**](https://anatase.org/) (an rpm-ostree based distribution).

## DISCLAIMER

**Important:** The fixes provided by this script are **not part of the official Anatase OS** and are offered **as-is**. The author of Anatase OS is **not responsible** for any issues that may arise from using this script. These fixes were created by the community to address specific hardware and software quirks and are provided for convenience only.

The script is **not endorsed** by the Anatase OS development team. Use it at your own risk.

## 📌 What this script does

The script applies the following stages, each reported with its own status (`done`, `not needed`, or `error`):

- **Fingerprint sensor tweaks** — A light touch on the power button's fingerprint sensor would wake the device from sleep, which is annoying when carrying it in a bag. The script disables this via two paths: the PCIe PME wake of the reader's xHCI controller (runtime + persistent udev rule) and the GPIO wake line (`gpiolib_acpi.ignore_wake` kernel argument).

- **Gamemode shortcut** — Copies `/usr/share/applications/gamemode.desktop` to the user's Desktop folder for quick access.

- **HHD settings** — Applies a curated Handheld Daemon preset: custom TDP (55 W), manual fan curve, AMD energy mode, RGB (cyberpunk), OXP controller mode with `hori_steam` layout, vibration strength, GameMode behaviour and power/battery configuration. All settings are applied via `hhdctl set` after a full `hhd.settings.reset` (settings reset). Before applying anything, the script reads the current HHD configuration and skips this stage entirely if every parameter already matches — so a second run does no work and does not reset your HHD settings.

- **Steam setup** — Configures Steam (Flatpak) for a seamless handheld experience:
  - copies the *Silent* Steam autostart entry to `~/.config/autostart` so the client starts quietly with the Desktop session;
  - adds `steam` to `XwaylandEisNoPromptApps` in `kwinrc` so the system stops prompting about Xwayland gamepad/EIS access;
  - launches Steam if it is not running, opens the on-screen keyboard window once to capture its exact title, closes it, and writes a KWin window rule that pins the keyboard to the bottom of the screen with correct scaling and transparency settings.

The script is **idempotent** – running it multiple times won't make unnecessary changes.

## ⚙️ Requirements

- Hardware: **OneXPlayer Apex**
- OS: **Anatase OS** version **20260907.10** or newer
- **HHD** (comes with Anatase OS; if absent, the HHD stage is skipped)
- **root** privileges (the script will request sudo automatically)
- Internet connection

## 🚀 Installation and Usage

Copy and run this **single command** in your terminal:

```
curl -fsSL https://raw.githubusercontent.com/Welld1s/apex-anatase-fixes/main/install.sh | sh
```

The script will prompt for your `sudo` password if needed. Each stage prints its own status line, and the final summary tells you whether a reboot and/or BIOS tweak is required.

## ⚠️ Important Notes

- **A reboot is required** if the fingerprint GPIO kernel argument was added, or if the `kwinrc` Xwayland entry was changed for the first time. The script will tell you at the end.

- **BIOS setting** — when the fingerprint sensor tweaks stage adds the GPIO kernel argument, enter the BIOS (usually by pressing `Del` during boot) and set: `Advanced -> ACPI Settings -> Enable ACPI Auto Configuration` -> **Enabled**. This is necessary for proper suspend/resume behavior.

- The script is safe to run multiple times – it won't duplicate kernel arguments or overwrite already correct settings.

- If you are not on Anatase OS, not on a OneXPlayer Apex, or your OS version is too old, the script exits during the **Preparation** stage with a clear error message and does not modify anything.

## 🙏 Credits

This script wouldn't exist without the work of the following people:

- **[antheas](https://github.com/antheas)** – for creating **Anatase OS** and **HHD**, the fantastic software that makes the OneXPlayer Apex truly shine.

- **[srsholmes](https://github.com/srsholmes)** – for all the fixes. His research and code form the foundation of this script.

Thank you all for your contributions to the OneXPlayer community!

## 📄 License

MIT License – use, modify, and distribute freely.

## 🤝 Contributing

If you find a bug or want to add support for other OneXPlayer models, feel free to open an Issue or submit a Pull Request.

**Made for OneXPlayer Apex owners on Anatase OS.**
