param(
    [parameter(Mandatory = $true)]
    [psobject]
    $Exported
)

& {
    ## Get all NuGet and Microsoft Supported RIDs from Microsoft.NETCore.Platforms
    $package = Get-Package "Microsoft.NETCore.Platforms" -ProviderName NuGet -ErrorAction SilentlyContinue
    $latest = Try {
        $Exported.GetStable( "Microsoft.NETCore.Platforms" )
    } Catch { $package.Version }

    if( (-not $package) -or ($package.Version -ne $latest) ){

        Try {
            Install-Package "Microsoft.NETCore.Platforms" `
                -ProviderName NuGet `
                -RequiredVersion $latest `
                -SkipDependencies `
                -Force `
                -ErrorAction Stop | Out-Null
        } Catch {        
            Install-Package "Microsoft.NETCore.Platforms" `
                -ProviderName NuGet `
                -RequiredVersion $latest `
                -SkipDependencies `
                -Scope CurrentUser `
                -Force | Out-Null
        }

        $package = Get-Package "Microsoft.NETCore.Platforms" -ProviderName NuGet -ErrorAction Stop
    }
    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name Runtimes `
        -Value (Get-Content "$($package.source | Split-Path )\runtime.json" -Raw | ConvertFrom-Json).runtimes
    
    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name Graphs `
        -Value ([System.Collections.ArrayList]::new())

    $grapher = {
        param( [string] $_rid, [System.Collections.ArrayList] $_graph, [System.Collections.ArrayList] $_graphs = $Exported.Graphs )

        if( $_rid ){
            $_graph.Add( $_rid ) | Out-Null

            $_kids = $Exported.Runtimes."$_rid".'#import'
            If( $_kids.Count -gt 0 ){
                $_kids | Select-Object -Skip 1 | ForEach-Object {
                    $_clone = $_graph.Clone()
                    $_graphs.Add( $_clone ) | Out-Null
                    & $grapher $_ $_clone $_graphs
                }
            }
            & $grapher $_kids[0] $_graph $_graphs
        }
    }

    & "$PSScriptRoot\runtimeidentifier.ps1" $Exported | Out-Null

    $Exported.Graphs.Add( [System.Collections.ArrayList]::new() ) | Out-Null

    & $grapher $Exported.Runtime $Exported.Graphs[0]

    $Exported
}