# Clean-System.ps1

A single-file PowerShell cleanup tool for Windows. Its core is a **faithful, reverse-engineered re-implementation of [PatchCleaner](https://www.homedev.com.au/free/patchcleaner) (HomeDev)** that removes orphaned `.msi`/`.msp` files from `C:\Windows\Installer`, plus a few standard disk-cleanup steps (WinSxS, Windows Update cache, temp folders, Delivery Optimization).

Unlike stock PatchCleaner, it runs **aggressively**: it applies **no exclude filters**, so Adobe/Acrobat orphans are deleted too.

> ⚠️ **Deletion under `C:\Windows\Installer` is irreversible.** Run with `$DryRun = $true` first and review the output.

---

## What it does

The `C:\Windows\Installer` folder caches the `.msi`/`.msp` packages Windows Installer needs to repair, modify or uninstall software. Over time it accumulates packages that no installed product references any more (**orphans**), which can grow to many GB. This script finds and deletes those orphans, then runs additional cleanup tasks.

### Steps

| Step | What it cleans | How |
|------|----------------|-----|
| **PatchCleaner core** | Orphaned `.msi`/`.msp` in `C:\Windows\Installer` | PatchCleaner algorithm (see below) |
| **WinSxS** | Component store / superseded updates | `DISM /Online /Cleanup-Image /StartComponentCleanup [/ResetBase]` |
| **Windows Update cache** | `C:\Windows\SoftwareDistribution\Download` | Stops `wuauserv`+`bits`, clears, restarts |
| **Temp** | `%TEMP%` and `C:\Windows\Temp` | Deletes contents (in-use items are skipped) |
| **Delivery Optimization** | DO download cache | `Delete-DeliveryOptimizationCache` |

Each run prints initial/final free space and a per-step summary.

---

## How the PatchCleaner core works (reverse-engineered)

The logic mirrors `PatchCleaner.Classes.PatchCleanerManager` from the original app, confirmed by disassembling its .NET assemblies:

1. **`SetupAllFiles`** — enumerates `C:\Windows\Installer\*.msp` and `*.msi` (non-recursive, hidden files included). This is the candidate set.

2. **`SetupRequiredFiles`** — determines which packages are still **in use**. PatchCleaner does **not** read the registry; it shells out to a VBScript via:

   ```
   cscript //B //Nologo WMIProducts.vbs
   ```

   `WMIProducts.vbs` (the original HomeDev script, embedded in this script) enumerates installed products and patches through the COM API and writes their cached package paths to `products.txt` / `patches.txt`:

   - `WindowsInstaller.Installer.Products` → `ProductInfo(code, "LocalPackage")`
   - `Installer.Patches(product)` → `PatchInfo(code, "LocalPackage")`

   Each output line is split on `"||| "` and the **last field** is the `LocalPackage` path. The script keeps the **file names** of all referenced packages.

   > **Why VBScript and not in-process COM?** Enumerating `Installer.Products` directly from PowerShell is unreliable (it can return zero products depending on host/bitness). Running the VBScript via `cscript` is exactly what PatchCleaner does and works consistently.

3. **`FindOrphanedFiles`** — a store file is an **orphan** if its `Path.GetFileName` matches the file name of **no** required package. The comparison is **by file name, case-insensitive** (all packages live in the same folder, so the name is unique; this is also immune to path-format differences like 8.3/long/case). This is byte-for-byte the same rule PatchCleaner uses (`String.Compare`, `InvariantCulture`, ignore-case).

4. **Deletion** — replicates `DeleteOrphanedFiles`: clears `ReadOnly`/`Hidden` attributes and, on an access-denied error, takes ownership (`takeown`) and grants `Everyone:F` (`icacls`) before retrying the delete.

### Safety behavior
- If the VBScript produces **no** `products.txt` (broken VBScript engine), the step **aborts** and deletes nothing — there is **no registry fallback**, because a registry-based "in use" set is far broader and would either keep too much or, if empty, risk deleting everything.
- Per-product MSI errors (e.g. `80004005` on `ProductInfo`) are **tolerated** and those products skipped — identical to PatchCleaner, which only treats a missing `products.txt` as fatal.

---

## Differences vs. stock PatchCleaner

| | Stock PatchCleaner | This script |
|---|---|---|
| Orphan detection | `cscript`+`WMIProducts.vbs`, match by file name | **Identical** |
| Deletion (attrs/ownership) | clears attrs, grants Everyone, deletes | **Identical** |
| Exclude filters | `ExcludeFilters = ["Acrobat"]` by default → **keeps** Adobe orphans | **None** → **deletes** Adobe orphans (≡ PatchCleaner with empty `ExcludeFilters`) |
| Extra cleanup | none | WinSxS, WU cache, Temp, Delivery Optimization |

So orphan **detection is 1:1**; the only deliberate divergence is dropping the Adobe exclusion (aggressive mode).

---

## Requirements

- Windows with **Windows PowerShell 5.1**
- Administrator rights (the script **auto-elevates**)
- `cscript.exe` (always present on Windows)

---

## Usage

1. **Dry run first** — open the script and set:

   ```powershell
   $DryRun = $true
   ```

   Run it and review `Required files` and `ORPHANED files to delete` (size). The orphan size should match what PatchCleaner reports on its main screen.

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

- **Irreversible**: deleted `.msi`/`.msp` files are gone. Future *repair*, *modify* or *uninstall* of an affected product may then ask for the original media. This is inherent to removing installer-cache orphans (PatchCleaner has the same caveat) and is why the Adobe exclusion exists in stock PatchCleaner — disabled here on purpose.
- **`DISM /ResetBase`** can fail with exit code `1168` ("Element not found") on some systems; the script automatically retries plain `StartComponentCleanup`. Set `$WinSxSResetBase = $false` to skip it entirely.
- Re-enabling Adobe (or any) protection is trivial: filter orphans whose MSI metadata (Author/Title/Subject/digital-signature OU) contains a given string before deletion — mirroring PatchCleaner's `ApplyFilters`.

---

## Disclaimer

Provided as-is, without warranty. You are responsible for what you delete on your own system. Test with `$DryRun = $true` before any live run.
