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

If( $ImportPackage ){
    Import-Module "PackageManagement"
}

$VerbosePreference = "Continue"

If( $ImportPackage ){
    Import-Module "$Root\Import-Package\"

    # --- Avalonia ---
    
    Import-Package Avalonia.Desktop -Offline
    # Import-Package Avalonia.Win32 -Offline]

    Write-Host
    Write-Host (Get-Runtime)

    Pause;
}

If( $NewDispatchThread ){
    Import-Module "$Root\New-ThreadController\"

    # Should dump a warning followed by an error

    Write-Host
    Write-Host "--- New-ThreadController:Avalonia"
    Update-DispatcherFactory ([Avalonia.Threading.Dispatcher])
    
    # --- ThreadExtensions ---

    Write-Host
    Write-Host "--- New-ThreadController:ThreadExtensions"
    Update-DispatcherFactory ([ThreadExtensions.Dispatcher])
    
    $t1 = New-ThreadController
    $t1.Invoke({
        Write-Host "Thread:" $ThreadName
        Write-Host "test - ThreadExtensions:Un-named"
    }).
        Invoke({ Write-Host "done - ThreadExtensions:Un-named" }, $true) | Out-Null
    Write-Host

    Try{
        $t2 = New-ThreadController -Name "Tester"
        $t2.Invoke({
            Write-Host "Thread:" $ThreadName
            Write-Host "test - ThreadExtensions:Named"
        }).
            Invoke({ Write-Host "done - ThreadExtensions:Named" }, $true) | Out-Null
    } Catch {
        Write-Host "Caught error: $_"
    }
    Write-Host

    Try{
        (Async {
            Write-Host "Thread:" $ThreadName
            Write-Host "self-disposed test - ThreadExtensions:Async"
        }).
            Invoke({ Write-Host "done - ThreadExtensions:Async" }, $true) | Out-Null
    } Catch {
        Write-Host "Caught error: $_"
    }

    Try{
        # This test ensures that the scriptmethod ThreadController.Invoke has no sessionstate, and is therefore thread-safe
        $safety1 = New-ThreadController -Name "Safety1"
        $t1.Invoke({
            $Threads[ "Safety1" ].Invoke({ Write-Host "ThreadSafe - ThreadExtensions:t1 -> Safety1" }, $true) | Out-Null
        }, $true) | Out-Null
    } Catch {
        Write-Host "Caught error: $_"
    }
    Write-Host

    $anon1 = New-ThreadController -Name "Anonymous"
    (Async {
        Write-Host "Thread:" $ThreadName
        Write-Host "test - ThreadExtensions:Anon"
    } -Thread $anon1).
        Invoke({ Write-Host "done - ThreadExtensions:Anon" }, $true) | Out-Null
    Write-Host

    # --- WPF ---
    
    If( [System.Windows.Threading.Dispatcher] ){

        Write-Host
        Write-Host "--- New-ThreadController:WPF"
        Update-DispatcherFactory ([System.Windows.Threading.Dispatcher])
        
        $t3 = New-ThreadController
        $t3.Invoke({
            Write-Host "Thread:" $ThreadName
            Write-Host "test - WPF:Un-named"
        }).
            Invoke({ Write-Host "done - WPF:Un-named" }, $true) | Out-Null
        Write-Host

        Try{ 
            # should error out
            $t4 = New-ThreadController -Name "Tester"
            $t4.Invoke({
                Write-Host "Thread:" $ThreadName
                Write-Host "test - WPF:Named"
            }).
                Invoke({ Write-Host "done - WPF:Named" }, $true) | Out-Null
        } Catch {
            Write-Host "Caught error: $_"
        }
        Write-Host
    
        Try {
            (Async {
                Write-Host "Thread:" $ThreadName
                Write-Host "self-disposed test - WPF:Async"
            }).
                Invoke({ Write-Host "done - WPF:Anon" }, $true) | Out-Null
        } Catch {
            Write-Host "Caught error: $_"
        }
        Write-Host

        $anon2 = New-ThreadController -Name "Anonymous"
        (Async {
            Write-Host "Thread:" $ThreadName
            Write-Host "test - WPF:Anon"
        } -Thread $anon2).
            Invoke({ Write-Host "done - WPF:Anon" }, $true) | Out-Null

        Try{
            # This test ensures that the scriptmethod ThreadController.Invoke has no sessionstate, and is therefore thread-safe
            $safety2 = New-ThreadController -Name "Safety2"
            $t3.Invoke({
                $Threads[ "Safety2" ].Invoke({ Write-Host "ThreadSafe - WPF:t3 -> Safety2" }, $true) | Out-Null
            }, $true) | Out-Null
        } Catch {
            Write-Host "Caught error: $_"
        }
        Write-Host
        
    }
    
    Write-Host
    Write-Host "Threads:"
    
    $Threads = Get-Threads
    $Threads
}