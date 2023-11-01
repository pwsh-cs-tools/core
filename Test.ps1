Import-Module "PackageManagement"
$VerbosePreference = "Continue"

Import-Module "$PSScriptRoot\Import-Package\"

Import-Module "$PSScriptRoot\New-DispatchThread\"

# --- Avalonia ---

Import-Package Avalonia.Desktop -Offline
# Import-Package Avalonia.Win32 -Offline]

# Should dump a warning followed by an error
Update-DispatcherFactory ([Avalonia.Threading.Dispatcher])

# --- ThreadExtensions ---
Update-DispatcherFactory ([ThreadExtensions.Dispatcher])

$t = New-DispatchThread
$t.Invoke({ Write-Host "test - ThreadExtensions" }).
    Invoke({ Write-Host "done - ThreadExtensions" }, $true) | Out-Null

# --- WPF ---

Write-Host
Update-DispatcherFactory ([System.Windows.Threading.Dispatcher])

$t = New-DispatchThread
$t.Invoke({ Write-Host "test - WPF" }).
    Invoke({ Write-Host "done - WPF" }, $true) | Out-Null

Write-Host
Write-Host (Get-Runtime)
Write-Host
Write-Host "Threads:"

$Threads = Get-Threads
$Threads