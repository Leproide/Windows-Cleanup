#Requires -Version 5.1
<#

leprechaun@huginn.ovh


.SYNOPSIS
    Faithful re-implementation of PatchCleaner's logic (HomeDev), reverse-engineered
    from its assemblies, plus WinSxS and system cache cleanup. AGGRESSIVE mode: no
    exclusions (Adobe included).

.DESCRIPTION
    Algorithm identical to PatchCleaner.Classes.PatchCleanerManager:
      - SetupAllFiles      : enumerate C:\Windows\Installer\*.msp and *.msi (non-recursive).
      - SetupRequiredFiles : run "cscript //B //Nologo WMIProducts.vbs" (the same HomeDev
                             script: WindowsInstaller.Installer -> Products/
                             ProductInfo(LocalPackage) + Patches/PatchInfo(LocalPackage)),
                             which writes products.txt/patches.txt; each line is split on
                             "||| " and the LAST field is taken (the LocalPackage path).
                             An errors.txt file means the VBScript engine is broken.
      - FindOrphanedFiles  : orphan = a store file whose Path.GetFileName does not match
                             (String.Compare ignoreCase, InvariantCulture) the GetFileName
                             of any required file. Comparison is by FILE NAME.
    No registry fallback: if the VBScript yields nothing, the step aborts (just like
    PatchCleaner, which throws), so it never proceeds with a wrong/oversized "in use" set.

    Difference vs default PatchCleaner: PatchCleaner ships with ExcludeFilters = ["Acrobat"]
    and therefore skips Adobe/Acrobat orphans. This script applies NO exclude filters, so
    Adobe is included in deletion (equivalent to PatchCleaner with an empty ExcludeFilters).

.NOTES
    Run as Administrator (the script auto-elevates). Requires cscript.exe (always present).
    Deletion under C:\Windows\Installer is IRREVERSIBLE: set $DryRun = $true to simulate.
#>

# ============================== CONFIGURATION FLAGS =============================
$DryRun                    = $false   # $true = simulation only: nothing is deleted/modified
$CleanWinSxS               = $true
$WinSxSResetBase           = $true
$CleanWindowsUpdateCache   = $true
$CleanTempFiles            = $true
$CleanDeliveryOptimization = $true
# ===============================================================================


# -------------------------------- Utilities ----------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Administrative privileges required. Relaunching elevated..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    return
}

function Format-Size {
    param([long]$Bytes)
    if     ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N2} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N2} KB' -f ($Bytes / 1KB) }
    else                    { "$Bytes B" }
}

function Write-Section { param($Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Get-SystemFreeSpace {
    $drive = (Get-Item $env:WINDIR).PSDrive.Name
    (Get-PSDrive -Name $drive).Free
}

# Sum the size of FILES only (folders have no Length). Returns 0 on empty input.
function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($s) { [long]$s } else { 0 }
}


# --------------------------- PatchCleaner core -------------------------------
# Original HomeDev WMIProducts.vbs (output files are relative to WorkingDirectory).
$Script:WMIProductsVbs = @'
On Error Resume Next
Dim msi : Set msi = CreateObject("WindowsInstaller.Installer")
Dim objFileErrors : Set objFileErrors = Nothing
Set fso = CreateObject("Scripting.FileSystemObject")
Set objFileProducts = fso.CreateTextFile("products.txt", True)
Set objFilePatches = fso.CreateTextFile("patches.txt", True)
If fso.FileExists("errors.txt") Then fso.DeleteFile "errors.txt"
Dim products : Set products = msi.Products
Dim product, productLocation, productName, location, patches, patchCode
For Each product In products
    productLocation = "" : productName = ""
    productLocation = msi.ProductInfo(product, "LocalPackage") : CheckError
    productName = msi.ProductInfo(product, "ProductName") : CheckError
    If (productLocation <> "") Then
        objFileProducts.WriteLine product & "||| [" & productName & "]||| " & productLocation
        Set patches = msi.Patches(product)
        For Each patchCode In patches
            location = ""
            location = msi.PatchInfo(patchCode, "LocalPackage")
            objFilePatches.WriteLine product & "||| " & patchCode & "||| " & location
        Next
    End If
Next
objFileProducts.Close()
objFilePatches.Close()

Sub CheckError
    If Err = 0 Then Exit Sub
    Dim message : message = Err.Source & " " & Hex(Err) & ": " & Err.Description
    If objFileErrors Is Nothing Then Set objFileErrors = fso.CreateTextFile("errors.txt", True)
    objFileErrors.WriteLine Now & " - " & message
    Err.Clear
End Sub
'@

function Get-MsiRequiredFiles {
    # Returns a HashSet (OrdinalIgnoreCase) of the FILE NAMES referenced by products
    # and patches, obtained via cscript/WMIProducts.vbs (PatchCleaner's method).
    # Returns $null on failure (errors.txt / no output).
    $set = New-Object 'System.Collections.Generic.HashSet[string]' (
        [StringComparer]::OrdinalIgnoreCase)

    $cscript = Join-Path $env:WINDIR 'System32\cscript.exe'
    if (-not (Test-Path $cscript)) {
        Write-Host "cscript.exe not found." -ForegroundColor Red; return $null
    }

    $work = Join-Path $env:TEMP ("pc_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $vbsPath  = Join-Path $work 'WMIProducts.vbs'
    $prodTxt  = Join-Path $work 'products.txt'
    $patchTxt = Join-Path $work 'patches.txt'
    $errTxt   = Join-Path $work 'errors.txt'

    # CreateTextFile/cscript use ANSI: save the VBS as Default (ANSI) encoding.
    Set-Content -LiteralPath $vbsPath -Value $Script:WMIProductsVbs -Encoding Default

    # Invocation identical to PatchCleaner: ProcessStartInfo, WorkingDirectory set to
    # the work folder, relative VBS name, hidden window, wait for exit.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = $cscript
    $psi.Arguments        = '//B //Nologo WMIProducts.vbs'
    $psi.WorkingDirectory = $work
    $psi.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.UseShellExecute  = $true            # like PatchCleaner (no redirection)
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $p.Close()
    } catch {
        Write-Host "Failed to start cscript: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $work -Recurse -Force -EA SilentlyContinue
        return $null
    }

    # Like PatchCleaner: errors.txt is FATAL only if products.txt does not exist
    # (broken VBScript engine). If products.txt exists, per-product errors
    # (e.g. 80004005 on ProductInfo) are tolerated: those products are skipped.
    if (-not (Test-Path $prodTxt)) {
        Write-Host "products.txt was not generated: unable to determine products." -ForegroundColor Red
        if (Test-Path $errTxt) {
            Get-Content -LiteralPath $errTxt -EA SilentlyContinue | ForEach-Object { Write-Host "  $_" }
        }
        Remove-Item -LiteralPath $work -Recurse -Force -EA SilentlyContinue
        return $null
    }
    if (Test-Path $errTxt) {
        $nerr = (Get-Content -LiteralPath $errTxt -EA SilentlyContinue | Measure-Object).Count
        Write-Host ("Warning: {0} product(s) skipped due to MSI errors (same as PatchCleaner)." -f $nerr) `
            -ForegroundColor DarkYellow
    }

    # Parsing identical to PatchCleaner: Split("||| ") and take the LAST field = LocalPackage.
    foreach ($file in @($prodTxt, $patchTxt)) {
        if (Test-Path $file) {
            Get-Content -LiteralPath $file -EA SilentlyContinue | ForEach-Object {
                if ($_ -and $_.Trim()) {
                    $parts = $_ -split '\|\|\| '
                    $loc   = $parts[$parts.Length - 1].Trim()
                    if ($loc) { [void]$set.Add([System.IO.Path]::GetFileName($loc)) }
                }
            }
        }
    }

    Remove-Item -LiteralPath $work -Recurse -Force -EA SilentlyContinue
    ,$set
}

# Replicates DeleteOrphanedFiles: clears attributes (ReadOnly/Hidden), and on an
# access error takes ownership + grants Everyone Full Control, then retries Delete.
function Remove-OrphanFile {
    param([string]$Path)
    try { [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal) } catch {}
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch {
        & takeown.exe /F "$Path" 2>$null | Out-Null
        & icacls.exe "$Path" /grant '*S-1-1-0:F' /C 2>$null | Out-Null   # *S-1-1-0 = Everyone
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Host "Could not delete $Path : $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

function Invoke-PatchCleaner {
    Write-Section "PatchCleaner: orphaned files in C:\Windows\Installer"
    $installerDir = Join-Path $env:WINDIR 'Installer'
    if (-not (Test-Path $installerDir)) { Write-Host "Folder $installerDir not found."; return }

    $required = Get-MsiRequiredFiles
    if ($null -eq $required -or $required.Count -eq 0) {
        Write-Host "Unable to determine required files (VBS): aborting (nothing deleted)." `
            -ForegroundColor Red
        return
    }
    Write-Host ("Required files (products + applied patches): {0}" -f $required.Count)

    # SetupAllFiles: *.msi and *.msp in the store root (hidden files included).
    $allFiles = Get-ChildItem -LiteralPath $installerDir -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.msi', '.msp' }

    # FindOrphanedFiles: orphan = file name not present among the required (case-insensitive).
    $orphans   = $allFiles | Where-Object { -not $required.Contains($_.Name) }
    $totalSize = ($orphans | Measure-Object -Property Length -Sum).Sum
    if (-not $totalSize) { $totalSize = 0 }

    Write-Host ("Total files in store: {0}" -f $allFiles.Count)
    Write-Host ("ORPHANED files to delete: {0}  ({1})" -f $orphans.Count, (Format-Size $totalSize)) `
        -ForegroundColor Yellow

    $deleted = 0; $freed = 0
    foreach ($f in $orphans) {
        if ($DryRun) {
            Write-Host "[DRYRUN] Would delete: $($f.FullName) ($(Format-Size $f.Length))"
            continue
        }
        try {
            $size = $f.Length
            if (Remove-OrphanFile -Path $f.FullName) { $deleted++; $freed += $size }
        } catch {
            Write-Host "Could not delete $($f.FullName): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if (-not $DryRun) {
        Write-Host ("Deleted {0} file(s), freed {1}." -f $deleted, (Format-Size $freed)) `
            -ForegroundColor Green
    }
}


# ------------------------------- WinSxS --------------------------------------
function Invoke-WinSxSCleanup {
    Write-Section "WinSxS: component store cleanup (DISM)"
    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    if ($WinSxSResetBase) { $dismArgs += '/ResetBase' }
    Write-Host ("Command: dism.exe {0}" -f ($dismArgs -join ' '))
    if ($DryRun) { Write-Host "[DRYRUN] DISM not executed."; return }
    & dism.exe @dismArgs
    $code = $LASTEXITCODE
    # /ResetBase sometimes fails (e.g. 1168 "Element not found"): retry plain
    # StartComponentCleanup, which generally succeeds.
    if ($code -ne 0 -and $WinSxSResetBase) {
        Write-Host ("DISM with /ResetBase failed (exit {0}); retrying without /ResetBase..." -f $code) `
            -ForegroundColor Yellow
        & dism.exe '/Online' '/Cleanup-Image' '/StartComponentCleanup'
        $code = $LASTEXITCODE
    }
    Write-Host ("DISM finished (exit code {0})." -f $code) -ForegroundColor Green
}


# --------------------- Windows Update cache ----------------------------------
function Invoke-WUCacheCleanup {
    Write-Section "Windows Update cache (SoftwareDistribution\Download)"
    $path     = Join-Path $env:WINDIR 'SoftwareDistribution\Download'
    $services = 'wuauserv', 'bits'
    if (-not (Test-Path $path)) { Write-Host "$path not present."; return }
    $before = Get-FolderSize $path
    if ($DryRun) { Write-Host "[DRYRUN] Would empty $path ($(Format-Size $before))"; return }
    foreach ($s in $services) { Stop-Service -Name $s -Force -EA SilentlyContinue }
    Get-ChildItem -LiteralPath $path -Force -EA SilentlyContinue |
        Remove-Item -Recurse -Force -EA SilentlyContinue
    foreach ($s in $services) { Start-Service -Name $s -EA SilentlyContinue }
    Write-Host ("Freed approximately {0}." -f (Format-Size ($before - (Get-FolderSize $path)))) -ForegroundColor Green
}


# --------------------------- Temporary files ---------------------------------
function Invoke-TempCleanup {
    Write-Section "Temporary files (%TEMP% + C:\Windows\Temp)"
    $targets = @($env:TEMP, (Join-Path $env:WINDIR 'Temp')) | Select-Object -Unique
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { continue }
        $before = Get-FolderSize $t
        if ($DryRun) { Write-Host "[DRYRUN] Would empty $t ($(Format-Size $before))"; continue }
        Get-ChildItem -LiteralPath $t -Force -EA SilentlyContinue |
            Remove-Item -Recurse -Force -EA SilentlyContinue
        Write-Host ("{0}: freed approximately {1}." -f $t, (Format-Size ($before - (Get-FolderSize $t)))) `
            -ForegroundColor Green
    }
}


# ----------------------- Delivery Optimization -------------------------------
function Invoke-DOCleanup {
    Write-Section "Delivery Optimization cache"
    if ($DryRun) { Write-Host "[DRYRUN] Would run Delete-DeliveryOptimizationCache."; return }
    if (Get-Command Delete-DeliveryOptimizationCache -EA SilentlyContinue) {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Host "Delivery Optimization cache emptied." -ForegroundColor Green
        } catch {
            Write-Host "Delivery Optimization error: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "Delete-DeliveryOptimizationCache cmdlet not available." -ForegroundColor Yellow
    }
}


# --------------------------------- Main --------------------------------------
$mode = if ($DryRun) { 'SIMULATION (DryRun)' } else { 'LIVE RUN' }
Write-Host "Starting cleanup - $mode" -ForegroundColor Magenta

$freeBefore = Get-SystemFreeSpace
Write-Host ("Initial free space: {0}" -f (Format-Size $freeBefore)) -ForegroundColor Magenta

Invoke-PatchCleaner
if ($CleanWinSxS)               { Invoke-WinSxSCleanup }
if ($CleanWindowsUpdateCache)   { Invoke-WUCacheCleanup }
if ($CleanTempFiles)            { Invoke-TempCleanup }
if ($CleanDeliveryOptimization) { Invoke-DOCleanup }

$freeAfter = Get-SystemFreeSpace
$recovered = $freeAfter - $freeBefore

Write-Section "Summary"
Write-Host ("Initial free space: {0}" -f (Format-Size $freeBefore))
Write-Host ("Final free space:   {0}" -f (Format-Size $freeAfter))
if ($recovered -ge 0) {
    Write-Host ("Space recovered:    {0}" -f (Format-Size $recovered)) -ForegroundColor Green
} else {
    Write-Host ("Net change:         -{0} (usage increased during execution)" `
        -f (Format-Size ([math]::Abs($recovered)))) -ForegroundColor Yellow
}

Write-Section "Done"
