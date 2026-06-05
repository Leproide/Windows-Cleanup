# Clean-System.ps1

A single-file PowerShell tool that reclaims disk space on Windows. Its core removes **orphaned `.msi`/`.msp` packages** from `C:\Windows\Installer`, and it also runs a few standard cleanup tasks (WinSxS, Windows Update cache, temp folders, Delivery Optimization).

Inspired by the excellent free utility **[PatchCleaner](https://www.homedev.com.au/free/patchcleaner)** by HomeDev. This is an independent PowerShell implementation of the same publicly documented idea, run in **aggressive** mode: it applies **no exclude filters**, so Adobe/Acrobat orphans are removed too.

> ⚠️ **Deletion under `C:\Windows\Installer` is irreversible.** Always run with `$DryRun = $true` first and review the output.

---

## What it does

`C:\Windows\Installer` caches the `.msi`/`.msp` packages Windows Installer needs to repair, modify or uninstall software. Over time it accumulates packages that no installed product references any more (**orphans**), which can grow to many GB. This script finds and deletes those orphans, then runs additional cleanup tasks.

| Step | What it cleans | How |
|------|----------------|-----|
| **Installer store** | Orphaned `.msi`/`.msp` in `C:\Windows\Installer` | see below |
| **WinSxS** | Component store / superseded updates | `DISM /Online /Cleanup-Image /StartComponentCleanup [/ResetBase]` |
| **Windows Update cache** | `C:\Windows\SoftwareDistribution\Download` | stops `wuauserv`+`bits`, clears, restarts |
| **Temp** | `%TEMP%` and `C:\Windows\Temp` | deletes contents (in-use items are skipped) |
| **Delivery Optimization** | DO download cache | `Delete-DeliveryOptimizationCache` |

Each run prints initial/final free space and a per-step summary.

---

## How the installer-store cleanup works

The technique for safely removing unused packages from the Windows Installer folder is well documented (see, e.g., [raymond.cc](https://www.raymond.cc/blog/safely-delete-unused-msi-and-mst-files-from-windows-installer-folder/)). This script implements it as follows:

1. **List candidates** — enumerate `C:\Windows\Installer\*.msp` and `*.msi` (non-recursive, hidden files included).

2. **Determine what's in use** — query installed products and their applied patches through the **Windows Installer automation interface**:

   - `WindowsInstaller.Installer.Products` → `ProductInfo(code, "LocalPackage")`
   - `Installer.Patches(product)` → `PatchInfo(code, "LocalPackage")`

   This enumeration is run through a small helper **VBScript** executed with `cscript`, which writes the referenced package paths to text files that the script reads back. The script keeps the **file names** of all in-use packages.

   > **Why VBScript instead of in-process COM?** Enumerating `Installer.Products` directly from PowerShell is unreliable (it can return zero products depending on host/bitness). Driving it through `cscript` is consistent and robust.

3. **Find orphans** — a store file is an **orphan** when its file name is referenced by **no** in-use package. Matching is **by file name, case-insensitive** — all packages live in the same folder, so the name is unique, and this avoids path-format pitfalls (8.3/long/case).

4. **Delete** — clears `ReadOnly`/`Hidden` attributes and, on an access-denied error, takes ownership (`takeown`) and grants `Everyone:F` (`icacls`) before retrying the delete.

### Safety behavior
- If the in-use set **cannot be determined** (broken VBScript engine, no output), the step **aborts and deletes nothing**. There is no fall-back to registry guessing, which would either keep far too much or, if empty, risk deleting everything.
- Per-product MSI quirks (e.g. error `80004005` on `ProductInfo` for a package whose attributes aren't readable) are **tolerated**: that product is skipped and the rest proceed.

---

## Adobe / exclude filters

Stock PatchCleaner ships with an "Acrobat" exclude filter and therefore **keeps** Adobe orphans. **This script applies no exclude filters**, so Adobe/Acrobat packages are deleted like any other orphan. If you want to protect a vendor, you can filter orphans by MSI metadata (Author/Title/Subject/digital-signature OU) before deletion.

---

## Requirements

- Windows with **Windows PowerShell 5.1**
- Administrator rights (the script **auto-elevates**)
- `cscript.exe` (always present on Windows)

---

## Usage

1. **Dry run first** — edit the script and set:

   ```powershell
   $DryRun = $true
   ```

   Run it and review `Required files` and `ORPHANED files to delete` (count + size).

2. **Live run** — set `$DryRun = $false` and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Clean-System.ps1
   ```

   (or right-click → *Run with PowerShell*; it will prompt for elevation).

### Configuration flags (top of the script)

```powershell
$DryRun                    = $false  # simulate only, delete nothing
$CleanWinSxS               = $true   # DISM component store cleanup
$WinSxSResetBase           = $true   # add /ResetBase (auto-retries without it on failure)
$CleanWindowsUpdateCache   = $true   # clear SoftwareDistribution\Download
$CleanTempFiles            = $true   # clear %TEMP% and C:\Windows\Temp
$CleanDeliveryOptimization = $true   # clear Delivery Optimization cache
```

---

## Notes & caveats

- **Irreversible**: deleted `.msi`/`.msp` files are gone. Future *repair*, *modify* or *uninstall* of an affected product may then ask for the original media. This is inherent to removing installer-cache orphans.
- **`DISM /ResetBase`** can fail with exit code `1168` ("Element not found") on some systems; the script automatically retries plain `StartComponentCleanup`. Set `$WinSxSResetBase = $false` to skip it entirely.

---

## Credits & disclaimer

Inspired by **[PatchCleaner](https://www.homedev.com.au/free/patchcleaner)** (HomeDev) — a great, free tool; go support it. This project is an independent implementation and is **not affiliated with or endorsed by HomeDev**.

Provided **as-is, without warranty**. You are responsible for what you delete on your own system. Test with `$DryRun = $true` before any live run.

## License

MIT (or your preferred license — add a `LICENSE` file).
