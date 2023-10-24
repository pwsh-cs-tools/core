Import-Module "PackageManagement"
$VerbosePreference = "Continue"

Import-Module "$PSScriptRoot\Import-Package\"

Import-Package Avalonia.Desktop -Offline
# Import-Package Avalonia.Win32 -Offline
Write-Host (Get-Runtime)

Import-Module "$PSScriptRoot\New-DispatchThread\"

Set-DispatcherFactory ([Avalonia.Threading.Dispatcher])

$t = New-DispatchThread
$t.Invoke({ Write-Host "test - Avalonia" })

Set-DispatcherFactory ([System.Windows.Threading.Dispatcher])

$t = New-DispatchThread
$t.Invoke({ Write-Host "test - WPF" })

$Threads = Get-Threads