# Initialize - Bootstraps the nuget type system
$bootstrapper = & (Resolve-Path "$PSScriptRoot\packaging.ps1")

<#
    .Synopsis
        A simplistic cmdlet for getting the target framework of the current PowerShell session.

    .Description
        This cmdlet is used to get the target framework of the current PowerShell session.
        It is used by Import-Package to determine which dlls to load from a NuGet package into the session.

    .Example
        Get-Dotnet # Example Return: Net,Version=v4.7.2
#>
function Get-Dotnet {
    [CmdletBinding()]
    param()

    Process {
        $bootstrapper.system
    }
}

<#
    .Synopsis
        Imports NuGet/Nupkg packages downloaded by PackageManagement

    .Description
        PackageManagement's default package providers (NuGet and PowerShellGet/Gallery)
        lack the ability to load their NuGet Packs into PowerShell. While PowerShellGallery 
        Packages can be loaded with `Import-Module`, they import the packs using a module 
        manifest, not the actual nuspec. This module provides a `Import-Package` cmdlet for 
        importing packages by the nuspec instead of the module manifest.

        By offering the commands `Import-Package` and `Import-Module` separately, this 
        module allows you to handle the C# dependencies (.nuspec) and PowerShell 
        dependencies (.psd1) from the same pack file on their own. This is useful for 
        dependency control. A couple of use cases for this feature:
            - You want to rewrite an existing powershell module using the same C# 
            dependencies, but you want to provide a different PowerShell API.
            - You are using multiple PowerShell modules that depend on the same C# 
            dependencies, and don't want to load the same C# dependencies multiple times.
            - You want to inject your own C# dependencies into a PowerShell module.

    .Parameter Name
        The name of the package to import.
        Alias: PackageName
        ParameterSetName: Managed (default)

    .Parameter Provider
        The name of the PackageManagement Provider to use. Defaults to 'NuGet' as PowerShellGallery modules can already be imported with Import-Module.
        Alias: ProviderName, PackageProvider
        ParameterSetName: Managed (default)

    .Parameter Version
        The version of the package to import. Defaults to the latest version.
        ParameterSetName: Managed (default)

    .Parameter Package
        The SoftwareIdentity object of the package to import (returned by Get-Package)
        ParameterSetName: Managed-Object
    
    .Parameter Path
        The path to the .nupkg file to import.
        Alias: PackagePath
        ParameterSetName: Unmanaged

    .Parameter TargetFramework
        The target framework of the package to import. Defaults to TFM of the current PowerShell session.

    .Parameter SkipLib
        Skip loading the crossplatform dlls from the package.

    .Parameter SkipRuntimes
        Skip loading the platform specific dlls from the package.

    .Parameter PostInstallScript
        A scriptblock to run after the package is imported. Defaults to a scriptblock that does nothing.
    
    .Parameter Loadmanifest
        A hashtable of package names mapped to manifest objects. The manifest object can contain the following properties:
            - Skip: A boolean or hashtable with the following properties:
                - Lib: A boolean indicating whether to skip loading the crossplatform dlls from the package.
                - Runtimes: A boolean indicating whether to skip loading the platform specific dlls from the package.
            - Script: A scriptblock to run after the package is imported.
            - Framework: The target framework of the package to import.
            - NativeDir: The directory to load native dlls from.
                - This is the recommended way to place native dlls for a specific package.
    
    .Parameter NativeDir
        The directory to place and load native dlls from. Defaults to the current directory.
        Recommended to be used in conjunction with Loadmanifest.

    .Example
        # These are the actual packages that make up the foundation of this module.
        Import-Package -Package 'NuGet.Frameworks' -TargetFramework 'netstandard2.0'
        Import-Package -Package 'NuGet.Packaging' -TargetFramework 'netstandard2.0'
#>
function Import-Package {
    [CmdletBinding(DefaultParameterSetName='Managed')]
    param(
        # Gets .nupkg from PackageManagement by name
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Managed',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Alias("PackageName")]
        [string] $Name,
        [Parameter(
            ParameterSetName='Managed',
            ValueFromPipeline=$true
        )]
        [string] $Version,
        [Parameter(
            ParameterSetName='Managed',
            ValueFromPipeline=$true
        )]
        [Alias("ProviderName","PackageProvider")]
        [string] $Provider = 'NuGet',
        
        # Gets .nupkg from PackageManagement by the SoftwareIdentity object
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Managed-Object',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Microsoft.PackageManagement.Packaging.SoftwareIdentity] $Package,
        $TargetFramework = (Get-Dotnet),

        # Gets .nupkg from the filesystem
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Unmanaged',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Alias("PackagePath")]
        [string] $Path,
        
        [switch] $SkipLib,
        [switch] $SkipRuntimes,
        [scriptblock] $PostInstallScript = {
            param(
                $Package,
                [string] $Version,
                [string] $Provider,
                $TargetFramework = (Get-Dotnet)
            )
        },
        [hashtable] $Loadmanifest,
        [string] $NativeDir = (Resolve-Path ".")
    )

    Process {
        $Package = if( $PSCmdlet.ParameterSetName -eq "Managed" ){

            $_package = Get-Package $Name -ProviderName NuGet -ErrorAction SilentlyContinue
            $latest = Try {
                $bootstrapper.GetLatest( $Name )
            } Catch { $_package.Version }

            if( (-not $_package) -or ($_package.Version -ne $latest) ){
                Try {
                    Install-Package $Name `
                        -ProviderName NuGet `
                        -SkipDependencies `
                        -Force | Out-Null
                } Catch {}

                $_package = Get-Package $Name -ProviderName NuGet -ErrorAction Stop
            }
            $_package
        } elseif( $PSCmdlet.ParameterSetName -eq "Unmanaged" ){

            $_package = [Microsoft.PackageManagement.Packaging.SoftwareIdentity]::new()
            $_package | Add-Member `
                -MemberType NoteProperty `
                -Name Name `
                -Value (Split-Path $Path -Leaf) `
                -Force
            $_package | Add-Member `
                -MemberType NoteProperty `
                -Name Unmanaged `
                -Value $true `
                -Force

            # Unpack the package to a temporary directory
            $system_temp = [System.IO.Path]::GetTempPath()
            [string] $temp_dir = [System.Guid]::NewGuid()
            New-Item -ItemType Directory -Path "$system_temp\$temp_dir" | Out-Null

            [System.IO.Compression.ZipFile]::ExtractToDirectory( $Path, "$system_temp\$temp_dir")
            # Copy the nupkg to the temporary directory
            Copy-Item -Path $Path -Destination "$system_temp\$temp_dir" -Force

            $_package | Add-Member `
                -MemberType NoteProperty `
                -Name Source `
                -Value "$system_temp\$temp_dir\$(Split-Path $Path -Leaf)" `
                -Force
            $_package
        } else {
            $Package
        }

        if( $Loadmanifest -and $Loadmanifest[ $Package.Name ] ){
            If( $null -ne $Loadmanifest[ $Package.Name ].Skip ){
                If( $Loadmanifest[ $Package.Name ].Skip.GetType() -eq [bool] ){
                    $SkipLib = $true
                    $SkipRuntimes = $true
                } Else {
                    If( $null -ne $Loadmanifest[ $Package.Name ].Skip.Lib ){
                        $SkipLib = $Loadmanifest[ $Package.Name ].Skip.Lib
                    }
                    If( $null -ne $Loadmanifest[ $Package.Name ].Skip.Runtimes ){
                        $SkipRuntimes = $Loadmanifest[ $Package.Name ].Skip.Runtimes
                    }
                }
            }
            If( $null -ne $Loadmanifest[ $Package.Name ].Script ){
                $PostInstallScript = $Loadmanifest[ $Package.Name ].Script
            }
            If( $null -ne $Loadmanifest[ $Package.Name ].Framework ){
                $TargetFramework = $Loadmanifest[ $Package.Name ].Framework
            }
            If( $null -ne $Loadmanifest[ $Package.Name ].NativeDir ){
                $NativeDir = $Loadmanifest[ $Package.Name ].NativeDir
            }
        }
        
        $TargetFramework = $TargetFramework -as [NuGet.Frameworks.NuGetFramework]

        Write-Verbose "Package Detected: $($Package.Name)$( If( $Package.Version ) { " $( $Package.Version )"}) for $($TargetFramework.GetShortFolderName())"

        $nuspec = $bootstrapper.ReadNuspec( $Package.Source )
        
        $dependency_frameworks = ($nuspec.package.metadata.dependencies.group).TargetFramework -As [NuGet.Frameworks.NuGetFramework[]]
        $package_framework = $bootstrapper.Reducer.GetNearest( $TargetFramework, $dependency_frameworks )

        $dependencies = $nuspec.package.metadata.dependencies.group.Where({
            ($_.TargetFramework -As [Nuget.Frameworks.NuGetFramework]) -eq $package_framework
        }).Packages | Where-Object { $_ }

        $short_framework = If( $package_framework ){
            $package_framework.GetShortFolderName()
        } Else {
            $null
        }

        Write-Verbose "Package Framework: $short_framework"
        Write-Verbose "Dependencies Detected: $( $dependencies.Count )"

        If( ($dependencies.Count -gt 0) -and (-not ($SkipLib -and $SkipRuntimes)) ){
            $dependencies | ForEach-Object {
                Import-Package $_.Id -Version $_.VersionRange.MinVersion -TargetFramework $package_framework
            }
        }

        $dlls = @{}
        If(
            (-not $SkipLib) -and
            (Test-Path "$(Split-Path $Package.Source)\lib\$short_framework")
        ){
            Try {

                $dlls.lib = Resolve-Path "$(Split-Path $Package.Source)\lib\$short_framework\*.dll" -ErrorAction SilentlyContinue

            } Catch {
                Write-Host "Unable to find crossplatform dlls for $($Package.Name)"
                return
            }
        }

        If( $bootstrapper.graphs -and (-not $SkipRuntimes) ){
            If( Test-Path "$(Split-Path $Package.Source)\runtimes" ){
                $available_rids = Get-ChildItem "$(Split-Path $Package.Source)\runtimes" -Directory | Select-Object -ExpandProperty Name
                
                $scoreboards = [System.Collections.ArrayList]::new()
                $bootstrapper.graphs | ForEach-Object {
                    $scoreboards.Add(@{}) | Out-Null
                }

                $available_rids | ForEach-Object {
                    $available_rid = $_
                    for ($i = 0; $i -lt $bootstrapper.graphs.Count; $i++) {
                        $scoreboard = $scoreboards[$i]
                        $graph = $bootstrapper.graphs[$i]
                        $scoreboard[$available_rid] = $graph.IndexOf($available_rid)
                    }
                }

                $selected = ($scoreboards | ForEach-Object {
                    $_.GetEnumerator() |
                        Sort-Object -Property Value |
                        Select-Object -First 1
                } | Sort-Object -Property Value | Select-Object -First 1).Key

                If( Test-Path "$(Split-Path $Package.Source)\runtimes\$selected\lib\$short_framework" ){
                    Try {
                        $dlls.runtime = Resolve-Path "$(Split-Path $Package.Source)\runtimes\$selected\lib\$short_framework\*.dll" -ErrorAction SilentlyContinue
                    } Catch {
                        Write-Host "Unable to find dlls for $($Package.Name) for $($bootstrapper.runtime)"
                        return
                    }
                }
            }
        }

        if ( $dlls.lib -or $dlls.runtime ) {
            if( $dlls.lib ){
                $dlls.lib | ForEach-Object {
                    Try {
                        Add-Type -Path $_
                    } Catch {
                        Write-Host "Unable to load crossplatform dll for $($Package.Name)"
                        return
                    }
                }
            }
            if( $dlls.runtime ){
                $dlls.runtime | ForEach-Object {
                    Try {
                        If( $bootstrapper.TestNative( $_.ToString() ) ){
                            $bootstrapper.LoadNative( $_.ToString(), $NativeDir )   
                        } Else {
                            Add-Type -Path $_
                        }
                    } Catch {
                        Write-Host "Unable to load dll for $($Package.Name) for $($bootstrapper.runtime)"
                        return
                    }
                }
            }
        } else {
            Write-Host "Package $($Package.Name) does not need to be loaded for $package_framework"
            return
        }

        $PostInstallScript.Invoke( $Package, $Version, $Provider, $TargetFramework )
    }
}
<#
    .Synopsis
        Reads the nuspec of a NuGet/Nupkg package downloaded by PackageManagement

    .Description
        Provides a way to read the nuspec of a NuGet/Nupkg package downloaded by PackageManagement.

    .Parameter Name
        The name of the package to read.
        Alias: PackageName
        ParameterSetName: Managed (default)

    .Parameter Provider
        The name of the PackageManagement Provider to use. Defaults to 'NuGet' (consistent with Import-Package).
        Alias: ProviderName, PackageProvider
        ParameterSetName: Managed (default)

    .Parameter Version
        The version of the package to read. Defaults to the latest version.

    .Parameter Package
        The SoftwareIdentity object of the package to read (returned by Get-Package)
        ParameterSetName: Managed-Object
    
    .Parameter Path
        The path to the .nupkg file to import.
        Alias: PackagePath
        ParameterSetName: Unmanaged

    .Example
        Read-Package -Package 'NuGet.Frameworks'
        Read-Package -Package 'NuGet.Packaging'
#>
function Read-Package {
    [CmdletBinding(DefaultParameterSetName='Managed')]
    param(
        # Gets .nupkg from PackageManagement by name
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Managed',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Alias("PackageName")]
        [string] $Name,
        [Parameter(
            ParameterSetName='Managed',
            ValueFromPipeline=$true
        )]
        [string] $Version,
        [Parameter(
            ParameterSetName='Managed',
            ValueFromPipeline=$true
        )]

        # Gets .nupkg from PackageManagement by the SoftwareIdentity object
        [Alias("ProviderName","PackageProvider")]
        [string] $Provider = 'NuGet',
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Managed-Object',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Microsoft.PackageManagement.Packaging.SoftwareIdentity] $Package,

        # Gets .nupkg from the filesystem
        [Parameter(
            Mandatory=$true,
            ParameterSetName='Unmanaged',
            ValueFromPipeline=$true,
            Position=0
        )]
        [Alias("PackagePath")]
        [string] $Path
    )

    Process {
        $Path = if( $PSCmdlet.ParameterSetName -eq "Managed" ){
            (Get-Package $Name -RequiredVersion $Version -ProviderName $Provider -ErrorAction Stop).Source
        } elseif( $PSCmdlet.ParameterSetName -eq "Unmanaged" ){
            $Path
        } else {
            $Package.Source
        }
        $bootstrapper.ReadNuspec( $Path )
    }
}
If( ($bootstrapper.Runtime -match "^win") -and ($bootstrapper.System.Framework -eq ".NETCoreApp") ){
    Import-Package Microsoft.Windows.SDK.NET.Ref # Automatically fixes the missing WinRT functionality in PowerShell Core on Windows
}
Export-ModuleMember -Cmdlet Import-Package, Read-Package, Get-Dotnet -Function Import-Package, Read-Package, Get-Dotnet