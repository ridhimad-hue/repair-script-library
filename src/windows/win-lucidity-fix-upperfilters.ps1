# win-lucidity-check-upperfilters.ps1
# Self-contained version for running directly on live VM
# Checks and fixes UpperFilters, driver Start values, and BootExecute
# for Lucidity-managed Windows VMs stuck in INACCESSIBLE_BOOT_DEVICE (0x7B) BSOD

$STATUS_SUCCESS = 0
$STATUS_ERROR = 1

function Log-Output($msg) { Write-Output "[Output $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }
function Log-Info($msg)   { Write-Output "[Info $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }
function Log-Error($msg)  { Write-Output "[Error $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $msg" }

$diskClassKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e967-e325-11ce-bfc1-08002be10318}"
$sessionManagerKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"

# ============================================================
# STEP 1: Check and fix UpperFilters
# ============================================================
Log-Info "Checking UpperFilters..."
$upperFilters = (Get-ItemProperty -Path $diskClassKey -Name "UpperFilters" -ErrorAction SilentlyContinue).UpperFilters

if ($upperFilters) {
    Log-Output "UpperFilters FOUND: $upperFilters"
    if ($upperFilters -notcontains "partmgr") {
        Log-Info "partmgr missing from UpperFilters — fixing..."
        $newFilters = @("partmgr") + $upperFilters
        Set-ItemProperty -Path $diskClassKey -Name "UpperFilters" -Value $newFilters
        Log-Output "UpperFilters FIXED: added partmgr"
    } else {
        Log-Output "UpperFilters OK: partmgr is present"
    }
} else {
    Log-Info "UpperFilters not found — creating with partmgr..."
    New-ItemProperty -Path $diskClassKey -Name "UpperFilters" -Value @("partmgr") -PropertyType MultiString -Force
    Log-Output "UpperFilters CREATED with partmgr"
}

# ============================================================
# STEP 2: Check and fix UpperFilters_LucidityBkp
# ============================================================
Log-Info "Checking UpperFilters_LucidityBkp..."
$lucidityBkp = (Get-ItemProperty -Path $diskClassKey -Name "UpperFilters_LucidityBkp" -ErrorAction SilentlyContinue).UpperFilters_LucidityBkp
if ($lucidityBkp) {
    Log-Output "UpperFilters_LucidityBkp FOUND: $lucidityBkp"
} else {
    Log-Output "UpperFilters_LucidityBkp NOT FOUND"
}

# ============================================================
# STEP 3: Check and fix driver Start values
# ============================================================
Log-Info "Checking driver Start values..."
$drivers = @{
    "partmgr" = 0
    "disk"    = 0
    "ntfs"    = 1
}

foreach ($driver in $drivers.Keys) {
    $expectedStart = $drivers[$driver]
    $driverKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$driver"
    $currentStart = (Get-ItemProperty -Path $driverKey -Name "Start" -ErrorAction SilentlyContinue).Start

    if ($currentStart -eq $null) {
        Log-Error "$driver Start value NOT FOUND"
    } elseif ($currentStart -eq 4) {
        Log-Info "$driver Start=4 (disabled) — fixing to $expectedStart..."
        Set-ItemProperty -Path $driverKey -Name "Start" -Value $expectedStart
        Log-Output "$driver Start FIXED: $expectedStart"
    } else {
        Log-Output "$driver Start OK: $currentStart"
    }
}

# ============================================================
# STEP 4: Check BootExecute
# ============================================================
Log-Info "Checking BootExecute..."
$bootExecute = (Get-ItemProperty -Path $sessionManagerKey -Name "BootExecute" -ErrorAction SilentlyContinue).BootExecute
Log-Output "BootExecute: $bootExecute"

if ($bootExecute -notcontains "autocheck autochk *") {
    Log-Info "autocheck autochk * missing from BootExecute — fixing..."
    $newBootExecute = @("autocheck autochk *") + $bootExecute
    Set-ItemProperty -Path $sessionManagerKey -Name "BootExecute" -Value $newBootExecute
    Log-Output "BootExecute FIXED"
} else {
    Log-Output "BootExecute OK"
}

# ============================================================
# STEP 5: Check Lucidity BootExecute entry
# ============================================================
Log-Info "Checking Lucidity BootExecute entry..."
if ($bootExecute -match "LuciBoot|luciboot") {
    Log-Output "Lucidity BootExecute entry FOUND: $($bootExecute | Where-Object { $_ -match 'LuciBoot|luciboot' })"
} else {
    Log-Output "Lucidity BootExecute entry NOT FOUND"
}

# ============================================================
# STEP 6: Check Ramdisk registry state
# ============================================================
Log-Info "Checking Lucidity Ramdisk registry..."
$ramdiskKey = "HKLM:\SYSTEM\CurrentControlSet\Services\LucidityRamdisk"
if (Test-Path $ramdiskKey) {
    $ramdiskStart = (Get-ItemProperty -Path $ramdiskKey -Name "Start" -ErrorAction SilentlyContinue).Start
    Log-Output "LucidityRamdisk Start: $ramdiskStart"
} else {
    Log-Output "LucidityRamdisk registry key NOT FOUND"
}

Log-Output "SCRIPT COMPLETED"
return $STATUS_SUCCESS