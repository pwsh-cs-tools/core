param(
    [bool] $ImportPackage = $true,
    [bool] $NewDispatchThread = $true,
    [string] $Root = (& {
            If( $PSScriptRoot ){
            $PSScriptRoot
        } Else {
            Resolve-Path .
        }
    })
)

$VerbosePreference = "Continue"

If( $ImportPackage ){
    Import-Module "PackageManagement"
    Import-Module "$Root\Import-Package\"

    # --- Avalonia ---
    
    Import-Package Avalonia.Desktop -Offline
    # Import-Package Avalonia.Win32 -Offline]

    Write-Host
    Write-Host (Get-Runtime)

    Pause;
}

If( $NewDispatchThread ){
    Import-Module "$Root\New-DispatchThread\"

    # Should dump a warning followed by an error
    Update-DispatcherFactory ([Avalonia.Threading.Dispatcher])
    
    # --- ThreadExtensions ---
    Update-DispatcherFactory ([ThreadExtensions.Dispatcher])
    
    $t1 = New-DispatchThread
    $t1.Invoke({ Write-Host "test - ThreadExtensions:Un-named" }).
        Invoke({ Write-Host "done - ThreadExtensions:Un-named" }, $true) | Out-Null
    
    Try{
        $t2 = New-DispatchThread -name "Tester"
        $t2.Invoke({ Write-Host "test - ThreadExtensions:Named" }).
            Invoke({ Write-Host "done - ThreadExtensions:Named" }, $true) | Out-Null
    } Catch {
        Write-Host "Caught error: $_"
    }
    
    # --- WPF ---
    
    If( [System.Windows.Threading.Dispatcher] ){

        Write-Host
        Update-DispatcherFactory ([System.Windows.Threading.Dispatcher])
        
        $t3 = New-DispatchThread
        $t3.Invoke({ Write-Host "test - WPF:Un-named" }).
            Invoke({ Write-Host "done - WPF:Un-named" }, $true) | Out-Null
    
        Try{ 
            $t4 = New-DispatchThread -name "Tester"
            $t4.Invoke({ Write-Host "test - WPF:Named" }).
                Invoke({ Write-Host "done - WPF:Named" }, $true) | Out-Null
        } Catch {
            Write-Host "Caught error: $_"
        }
    }
    
    Write-Host
    Write-Host "Threads:"
    
    $Threads = Get-Threads
    $Threads
}