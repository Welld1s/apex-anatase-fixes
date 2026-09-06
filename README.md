# apex-anatase-fixes

A utility for automatically applying all necessary fixes for the **OneXPlayer Apex** handheld console running [**Anatase OS**](https://anatase.org/) (an rpm-ostree based distribution).


## DISCLAIMER

**Important:** The fixes provided by this script are **not part of the official Anatase OS** and are offered **as-is**. The author of Anatase OS is **not responsible** for any issues that may arise from using this script. These fixes were created by the community to address specific hardware and software quirks and are provided for convenience only.

The script is **not endorsed** by the Anatase OS development team. Use it at your own risk.



## 📌 What this script does

- **Blocks fingerprint wake-on-touch**  
  A light touch on the power button's fingerprint sensor would wake the device from sleep, which is annoying when carrying it in a bag. The script disables this behavior immediately (via PME) and makes it persistent across reboots (kernel argument + udev rule).

- **Fixes suspend/resume issues**  
  Adds kernel argument `amd_iommu=off`, which resolve hangs when resuming from sleep (S3).

- **GameMode desktop shortcut**  
  Copies `/usr/share/applications/gamemode.desktop` to the Desktop if not already present.

The script is **idempotent** – running it multiple times won't make unnecessary changes.



## ⚙️ Requirements

- Hardware: **OneXPlayer Apex**
- OS: **Anatase OS** on the **rolling** release branch
- **root** privileges (the script will request sudo automatically)
- Internet connection (for the one-liner install)



## 🚀 Installation and Usage

Copy and run this **single command** in your terminal:
```sh
curl -fsSL https://raw.githubusercontent.com/Welld1s/apex-anatase-fixes/main/install.sh | sh
```

The script will prompt for your `sudo` password if needed. After successful execution, it will display colored notifications about what was done.



## 📋 What the script does step by step

1. **Verifies** that the system is Anatase OS and the hardware is OneXPlayer Apex.
2. **Locates** the xHCI controller that hosts the fingerprint reader.
3. **Disables PME wake** by writing `disabled` to `/sys/bus/pci/devices/.../power/wakeup` and installs a udev rule to persist this setting across reboots.
4. **Adds kernel arguments** via `rpm-ostree kargs`:
   - `gpiolib_acpi.ignore_wake=AMDI0030:00@58` (closes the second wake path – GPIO)
   - `amd_iommu=off` (suspend stability)
5. **Copies** `gamemode.desktop` to the Desktop if missing or different.
6. **Informs** the user about the required reboot and BIOS setting.



## ⚠️ Important Notes

- **A reboot is required** – kernel arguments only take effect after restarting.
- **BIOS setting** – after reboot, enter the BIOS (usually by pressing `Del` during boot) and set:  
  `Advanced -> ACPI Settings -> Enable ACPI Auto Configuration` -> **Enabled**.  
  This is necessary for proper suspend/resume behavior.
- The script is safe to run multiple times – it won't duplicate kernel arguments or overwrite already correct settings.



## 🐛 Error Messages

| Error | Meaning |
|-------|---------|
| `Anatase OS not detected.` | The script is not running on Anatase OS. |
| `This hardware is not a OneXPlayer Apex ...` | The hardware doesn't match (checked via DMI). |
| `Fingerprint reader not found.` | The fingerprint sensor is missing; this is not an Apex. |
| `Failed to add kernel argument: ...` | Issue with `rpm-ostree` (check network and permissions). |



## 🙏 Credits

This script wouldn't exist without the work of the following people:

- **[antheas](https://github.com/antheas)** – for creating **Anatase OS**, the fantastic gaming-focused distribution that makes the OneXPlayer Apex truly shine.

- **[srsholmes](https://github.com/srsholmes)** – for all the fixes. His research and code form the foundation of this script.

Thank you all for your contributions to the OneXPlayer community!



## 📄 License

MIT License – use, modify, and distribute freely.



## 🤝 Contributing

If you find a bug or want to add support for other OneXPlayer models, feel free to open an Issue or submit a Pull Request.



**Made for OneXPlayer Apex owners on Anatase OS.**
