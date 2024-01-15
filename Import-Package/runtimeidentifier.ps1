param(
    [parameter(Mandatory = $true)]
    [psobject]
    $Exported
)

Try {
    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name Runtime `
        -Value ([System.Runtime.InteropServices.RuntimeInformation]::RuntimeIdentifier.ToString())
} Catch {

    # The C# Architecture Enum should cover all architectures listed in Microsoft.NETCore.Platforms
    # - see: https://learn.microsoft.com/en-us/dotnet/api/system.runtime.interopservices.architecture?view=net-7.0
    $arch = Try {
        [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    } Catch {
        Try {
            [System.Runtime.InteropServices.RuntimeInformation, mscorlib]::OSArchitecture.ToString()
        } Catch {}
    }
    $os_releases_file = Get-Content -Path "/etc/os-release" -ErrorAction SilentlyContinue
    $os_checks = @{
        # Standard Linux Checks
        @(
            "alpine", "arch", "centos", "debian", "exherbo", "fedora",
            "gentoo", "linuxmint", "manjaro", "miraclelinux", "ol",
            "opensuse", "rhel", "rocky", "sles", "tizen", "ubuntu"
        ) = { param( $OS ); Try { $os_releases_file -match "ID\=[`"']?$OS" } Catch { $false } }
        
        # Unsupported OS Checks
        @(
            "android", # Android currently requires Xamarin/.NET MAUI to run, and PowerShell only supports .NET Core and .NET Framework
            "browser", # While Blazor Web Assembly technically has limited capability to run .NET Core, there is no current implementation of PowerShell for it
            "illumos", "omnios", "openindiana", "smartos", "solaris", # Solaris systems are not supported by PowerShell
            "ios", "iossimulator", "tvos", "tvossimulator", # iOS currently requires Xamarin/.NET MAUI to run, and PowerShell only supports .NET Core and .NET Framework
            "maccatalyst", # While maccatalyst supports .NET core, there is no current implementation of PowerShell for it
            "freebsd" # FreeBSD does not yet support .NET Core
        ) = { $false }

        # Built-in Checks
        @( "osx", "linux" ) = { param( $OS ); [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::"$OS") }
        "win" = { [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) }
        "unix" = {
            [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux) -or `
            [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
        }
    }

    $oses = $os_checks.GetEnumerator() | ForEach-Object {
        $os_array = $_.Key
        $os_check = $_.Value
        $os_array | Where-Object {
            $os_check.Invoke( $_ )
        }
    } | Where-Object { $_ }
    
    $rids = if( $oses.Count ){
        $version_ammendments = @(
            @(
                @(
                    "alpine", "centos", "debian", "fedora", "linuxmint",
                    "miraclelinux", "ol", "opensuse", "rhel", "rocky",
                    "sles", "tizen", "ubuntu"
                ),
                { param( $OS ); ($os_releases_file | Where-Object { $_ -match "VERSION_ID" }).Split("=")[1].Trim("`"' ") },
                { param( $OS, $Version ); "$OS.$Version" }
            ),
            # Currently unsupported systems that do have version checks
            # "android", "freebsd", "ios", "iossimulator"
            # "maccatalyst", "omnios", "smartos", "solaris"
            # "tvos", "tvossimulator"
            @(
                "osx",
                {
                    param( $OS )
                    $v = $(sw_vers -productVersion)
                    $maj = $v.Split(".")[0]
                    $min = $v.Split(".")[1]
                    if( $maj -eq "10" ){
                        "$maj.$min"
                    } else {
                        $maj
                    }
                },
                { param( $OS, $Version ); "$OS.$Version" }
            ),
            @(
                "win",
                {
                    param( $OS )
                    $version = [System.Environment]::OSVersion.Version

                    switch -Wildcard ($version.ToString()) 
                    {
                        "10.0*" { "10" }
                        "6.3*"  { "81" }
                        "6.2*"  { "8" }
                        "6.1*"  { "7" }
                        default { "" }
                    }
                },
                { param( $OS, $Version ); "$($OS)$($Version)" }
            )
        )
        $oses = $oses | ForEach-Object {
            $os = $_
            $version_ammendment = $version_ammendments | Where-Object { $_[0] -contains $os }
            $ammended = if( $version_ammendment.Count ){
                $version_ammendment[2].Invoke( $os, $version_ammendment[1].Invoke( $os ) )
            } else {
                $os
            }
            $ammended
        }
        $oses | ForEach-Object {
            $os = $_
            (@( $os, $arch.ToLower() ) | Where-Object { $_ }) -join "-"
        }
    } else {
        (@( "any", $arch.ToLower() ) | Where-Object { $_ }) -join "-"
    }

    # aot checks are not required for PowerShell

    # need to check the RID graph for the top most RID in the list of detected RIDs
    # I think I will create a set of graphs for each RID, then check which RID only occurs in one set of graphs

    $graphs = @{}
    $rids | ForEach-Object {
        $graphs[$_] = [System.Collections.ArrayList]::new()
        $graphs[$_].add( [System.Collections.ArrayList]::new() ) | Out-Null

        & $grapher $_ $graphs[$_][0] $graphs[$_]
    }

    $rid = $rids | ForEach-Object {
        # iterate through the other graph sets and count how many of the sets contain the current RID
        $output = @{
            "rid" = $_
            "tally" = 0
        }

        If( $graphs.Keys.Count -ne 1 ){
            $graphs.Keys | Where-Object { $_ -ne $output.rid } | ForEach-Object {
                $graph = $graphs[$_]
                $graph | Where-Object { $_.Contains( $output.rid ) } | ForEach-Object { $output.tally += 1 }
            }
        }

        $output
    } | Where-Object { $_.tally -eq 0 } | ForEach-Object { $_.rid } | Select-Object -First 1

    if( $rid.Count -ne 1 ){
        Write-Host "Unable to determine the correct RID for this system."
        Write-Host "Possible RID Count: $($rid.Count)"
        Write-Host "Possible RIDs: $($rid -join ", ")"
        Write-Host "All RIDs Detected: $($rids -join ", ")"
    }

    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name Runtime `
        -Value $rid

    $Exported
}