param(
    [switch] $ImportPackage,
    [Alias("NewThreadController")]
    [switch] $NewDispatchThread,
    [string] $Root = (& {
            If( $PSScriptRoot ){
            $PSScriptRoot
        } Else {
            Resolve-Path .
        }
    })
)

If( -not $ImportPackage -and -not $NewDispatchThread ){
    $ImportPackage = $true
    $NewDispatchThread = $true
}

$global:__testing = $true

If( $ImportPackage ){
    Import-Module "PackageManagement"
}

$VerbosePreference = "Continue"

If( $ImportPackage ){

    Write-Host "[Import-Package:Testing] Begin Testing?"
    pause;

    Measure-Command {
        Import-Module "$Root\Import-Package\"
    }
    
    Write-Host "[Import-Package:Testing] Initialized. Continue Testing?"
    pause;

    # --- Basic Testing ---

    Measure-Command {
        Write-Host "[Import-Package:Testing] Testing with Avalonia.Desktop and Microsoft.ClearScript"
    
        Import-Package Avalonia.Desktop -Offline
        Import-Package Microsoft.ClearScript -Offline
    }
    
    Write-Host "[Import-Package:Testing] Avalonia.Desktop and Microsoft.ClearScript should be loaded. Continue Testing?"
    pause;

    # --- Path Parameter Testing ---

    Write-Host "[Import-Package:Testing] Testing the Unmanaged Parameterset"

    $unmanaged = @{}

    # Has no dependencies
    $unmanaged.Simple = Get-Package NewtonSoft.json

    # Has 1 dependency
    $unmanaged.Complex = Get-Package NLua
    
    $unmanaged.Simple = $unmanaged.Simple.Source
    $unmanaged.Complex = $unmanaged.Complex.Source

    Measure-Command { Import-Package -Path $unmanaged.Simple }
    Write-Host "[Import-Package:Testing] Testing the Unmanaged Parameterset with a simplistic package is complete. Continue Testing?"
    pause;

    Measure-Command { Import-Package -Path $unmanaged.Complex }
    Write-Host "[Import-Package:Testing] Testing the Unmanaged Parameterset with a complex package is complete. Continue Testing?"
    pause;

    Measure-Command { Import-Package NLua -SkipDependencies }
    Write-Host "[Import-Package:Testing] Testing the -SkipDependencies switch is complete. Continue Testing?"
    pause;

    Measure-Command { Import-Package IronRuby.Libraries }
    Write-Host "[Import-Package:Testing] Testing the Semver2 packages (and the package cache) is complete. Continue Testing?"
    pause;
    
    @(
        [Microsoft.ClearScript.V8.V8ScriptEngine]
        [Avalonia.Application]
        [Newtonsoft.Json.JsonConverter]
        [NLua.Lua]
        [IronRuby.Ruby]
    ) | Format-Table

    Write-Host
    Write-Host "System Runtime ID:" (Get-Runtime)
}

If( $NewDispatchThread ){

    Write-Host "[New-ThreadController:Testing] Begin Testing?"
    pause;

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
        Write-Host "--- New-ThreadControllerd:WPF"
        Update-DispatcherFactory ([System.Windows.Threading.Dispatcher])
        
        $t3 = New-ThreadController
        $t3.Invoke({
            Write-Host "Thread:" $ThreadName
            Write-Host "test - WPF:Un-named"
        }).
            Invoke({ Write-Host "done - WPF:Un-named" }, $true) | Out-Null
        Write-Host

        Try{ 
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
        Write-Host
        
    }
    
    Write-Host
    Write-Host "Threads:"
    
    $Threads = Get-Threads
    $Threads
}