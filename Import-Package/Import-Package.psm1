# Initialize - Bootstraps the nuget type system
Write-Verbose "[Import-Package:Init] Initializing..."
$bootstrapper = & (Resolve-Path "$PSScriptRoot\packaging.ps1")
$loaded = @{
    "NuGet.Frameworks" = "netstandard2.0"
}
Write-Verbose "[Import-Package:Init] Initialized"

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
        A simplistic cmdlet for getting the target runtime of the current PowerShell session.

    .Description
        This cmdlet is used to get the target runtime of the current PowerShell session.
        It is used by Import-Package to determine which dlls to load from a NuGet package into the session.

    .Example
        Get-Runtime # Example Return: win10-x64
#>

function Get-Runtime {
    [CmdletBinding()]
    param()

    Process {
        $bootstrapper.runtime
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

    .Parameter Offline
        Skip downloading the package from the package provider.

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
            - TempPath: The directory to load native dlls from and/or copy packages provided by path.
                - This is the recommended way to place native dlls for a specific package.
    
    .Parameter TempPath
        The directory to place and load native dlls from. Defaults to the current directory.
        Recommended to be used in conjunction with Loadmanifest.

    .Notes
        You can set DIS_AUTOUPDATE_IMPORTS to 1 as an environment variable (or to $true as a global variable) to disable automatic update the Import-Package cmdlet's dependencies.

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
        
        [switch] $Offline,
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
        [string] $TempPath = (& {
            $parent = [System.IO.Path]::GetTempPath()
            [string] $name = [System.Guid]::NewGuid()
            New-Item -ItemType Directory -Path (Join-Path $parent $name)
            # Resolve-Path "."
        })
    )

    Process {
        If( $PSCmdlet.ParameterSetName -eq "Managed-Object" ){
            Write-Verbose "[Import-Package:ParameterSet] Managed Object"
        } Else {

            if( $PSCmdlet.ParameterSetName -eq "Managed" ){

                $continue = if(
                    $Loadmanifest -and `
                    $Loadmanifest[ $Name ]
                ){
                    if(
                        (
                            ($Loadmanifest[ $Name ].Skip.GetType() -eq [bool] ) -and `
                            $Loadmanifest[ $Name ].Skip
                        ) -or `
                        (
                            $Loadmanifest[ $Name ].Skip -and `
                            $Loadmanifest[ $Name ].Skip.Lib -and `
                            $Loadmanifest[ $Name ].Skip.Runtimes
                        )
                    ){
                        Write-Verbose "[Import-Package:Loading] Skipping $Name"
                        return
                    }
    
                    if( $Loadmanifest[ $Name ].Path ){
                        $Path = $Loadmanifest[ $Name ].Path
                    }
                    -not( $Path )
    
                } Else {
                    -not( $Path )
                }
    
                if( $continue ){
                    Write-Verbose "[Import-Package:ParameterSet] Managed"
    
                    $_package = Get-Package $Name -ProviderName NuGet -ErrorAction SilentlyContinue
                    $latest = Try {
                        If( $Version ){
                            $Version
                        } ElseIf( $Offline ){
                            $_package.Version
                        } Else {
                            $bootstrapper.GetLatest( $Name )
                        }
                    } Catch { $_package.Version }
    
                    if( (-not $_package) -or ($_package.Version -ne $latest) ){
                        $_package = Try {
                            Get-Package $Name -RequiredVersion $latest -ProviderName NuGet -ErrorAction Stop
                        }
                        Catch {    
                            Try {
                                Write-Verbose "[Import-Package:Downloading] Downloading $Name $latest"
                                Install-Package $Name `
                                    -ProviderName NuGet `
                                    -RequiredVersion $latest `
                                    -SkipDependencies `
                                    -Force `
                                    -ErrorAction Stop | Out-Null
                            } Catch {
                                Install-Package $Name `
                                    -ProviderName NuGet `
                                    -RequiredVersion $latest `
                                    -SkipDependencies `
                                    -Scope CurrentUser `
                                    -Force | Out-Null
                            }
                            Get-Package $Name -RequiredVersion $latest -ProviderName NuGet -ErrorAction Stop
                        }
                    }
                    $Package = $_package
                }
            }
            
            if( $PSCmdlet.ParameterSetName -eq "Unmanaged" -or $Path ){
    
                if(
                    $Loadmanifest -and `
                    $Loadmanifest[ $Name ]
                ){
                    if(
                        (
                            (
                                ($Loadmanifest[ $Name ].Skip.GetType() -eq [bool] ) -and `
                                $Loadmanifest[ $Name ].Skip
                            ) -or `
                            (
                                $Loadmanifest[ $Name ].Skip -and `
                                $Loadmanifest[ $Name ].Skip.Lib -and `
                                $Loadmanifest[ $Name ].Skip.Runtimes
                            )
                        )
                    ){
                        Write-Verbose "[Import-Package:Loading] Skipping $Name"
                        return
                    }
                    
                    if( $Path -ne $Loadmanifest[ $Name ].Path ){
                        $Path = $Loadmanifest[ $Name ].Path
                    }
                }
    
                Write-Verbose "[Import-Package:ParameterSet] Unmanaged"
    
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
    
                # Unpack the package to the TempPath temporary directory
                [System.IO.Compression.ZipFile]::ExtractToDirectory( $Path, "$TempPath")
                # Copy the nupkg to the temporary directory
                Copy-Item -Path $Path -Destination "$TempPath" -Force
    
                $_package | Add-Member `
                    -MemberType NoteProperty `
                    -Name Source `
                    -Value "$TempPath\$(Split-Path $Path -Leaf)" `
                    -Force
                $_package
    
                $Package = $_package
            }
        }

        If( $Package ){
            Write-Verbose "[Import-Package:Detection] Detected package $($Package.Name)$( If( $Package.Version ) { " $( $Package.Version )"})"
        } Else {
            Write-Error "[Import-Package:Detection] Unable to find package $Name"
        }

        if( $Loadmanifest -and $Loadmanifest[ $Package.Name ] ){
            If( $null -ne $Loadmanifest[ $Package.Name ].Skip ){
                If( $Loadmanifest[ $Package.Name ].Skip.GetType() -eq [bool] ){
                    $SkipLib = $Loadmanifest[ $Package.Name ].Skip
                    $SkipRuntimes = $Loadmanifest[ $Package.Name ].Skip
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
            If( $null -ne $Loadmanifest[ $Package.Name ].TempPath ){
                $TempPath = $Loadmanifest[ $Package.Name ].TempPath
            }
        }
        
        $TargetFramework = $TargetFramework -as [NuGet.Frameworks.NuGetFramework]

        Write-Verbose "[Import-Package:Parsing] Parsing package $($Package.Name)$( If( $Package.Version ) { " $( $Package.Version )"}) for $($TargetFramework.GetShortFolderName())..."

        $nuspec = $bootstrapper.ReadNuspec( $Package.Source )
        
        $nuspec_id = $nuspec.package.metadata.id.ToString()
        $dependency_frameworks = ($nuspec.package.metadata.dependencies.group).TargetFramework -As [NuGet.Frameworks.NuGetFramework[]]
        If( $dependency_frameworks ){
            $package_framework = $bootstrapper.Reducer.GetNearest( $TargetFramework, $dependency_frameworks )
    
            $dependencies = ($nuspec.package.metadata.dependencies.group | Where-Object {
                ($_.TargetFramework -as [NuGet.Frameworks.NuGetFramework]).ToString() -eq $package_framework.ToString()
            }).dependency | Where-Object { $_ } | ForEach-Object {
                $version = $_.version
                $out = @{
                    "id" = $_.id
                    "version" = (& {
                        $parsed = @{
                            MinVersion = $null
                            MaxVersion = $null
                            MinVersionInclusive = $null
                            MaxVersionInclusive = $null
                        }
                        $versions = $version.Split( ',' )
                        if( $versions.Count -eq 1 ){
                            if( $versions -match "[\[\(]" ){
                                $parsed.MinVersion = $versions[0].TrimStart( '[', '(' ).TrimEnd( ']', ')' )
                                $parsed.MinVersionInclusive = $versions[0].StartsWith( '[' )
                            } else {
                                $parsed.MinVersion = $versions[0]
                                $parsed.MinVersionInclusive = $true
                            }
                        } else {
                            if( $versions[0] -and ($versions[0] -match "[\[\(]") ){
                                $parsed.MinVersion = $versions[0].TrimStart( '[', '(' )
                                $parsed.MinVersionInclusive = $versions[0].StartsWith( '[' )
                            } else {
                                $parsed.MinVersion = $versions[0]
                                $parsed.MinVersionInclusive = $true
                            }
                            if( $versions[1] -and ($versions[1] -match "[\]\)]") ){
                                $parsed.MaxVersion = $versions[1].TrimEnd( ']', ')' )
                                $parsed.MaxVersionInclusive = $versions[1].EndsWith( ']' )
                            } else {
                                $parsed.MaxVersion = $versions[1]
                                $parsed.MaxVersionInclusive = $true
                            }
                        }
                        If( $parsed.MaxVersion -and $parsed.MaxVersionInclusive ){
                            $parsed.MaxVersion
                        } ElseIf ( $parsed.MinVersion -and $parsed.MinVersionInclusive ){
                            $parsed.MinVersion
                        } Else {
                            # Warn user that exclusive versions are not yet supported, and prompt user for a version
                            Write-Warning "[Import-Package:Parsing] Exclusive versions are not yet supported."
                            Read-Host "- Please specify a version for $out - range: $($_.version)"
                        }
                    })
                }
                $out
            }
    
            $short_framework = If( $package_framework ){
                $package_framework.GetShortFolderName()
            } Else {
                $null
            }
        } else {
            $package_framework = $TargetFramework
            $dependencies = @()
            $short_framework = $TargetFramework.GetShortFolderName()
        }

        Write-Verbose "[Import-Package:Traversing] Selecting $short_framework for $($Package.Name)"
        Write-Verbose "[Import-Package:Traversing] Found Dependencies: $( $dependencies.Count )"

        If( ($dependencies.Count -gt 0) -and (-not ($SkipLib -and $SkipRuntimes)) ){
            $dependencies | ForEach-Object {
                If( $loaded[ $_.id ] ){
                    Write-Verbose "- [$($Package.Name)] Dependency $($_.id) already loaded"
                } Else {
                    Write-Verbose "- [$($Package.Name)] Loading $($_.id) - $($_.Version)"
                    If( $Offline ){
                        Import-Package $_.id -Version $_.Version -TargetFramework $package_framework -Offline
                    } Else {
                        Import-Package $_.id -Version $_.Version -TargetFramework $package_framework
                    }
                    Write-Verbose "- [$($Package.Name)] $($_.id) Loaded"
                }
            }
        }

        $dlls = @{}
        If(
            (-not $SkipLib) -and
            (Test-Path "$(Split-Path $Package.Source)\lib\$short_framework")
        ){
            Try {

                $dlls.lib = Resolve-Path "$(Split-Path $Package.Source)\lib\$short_framework\*.dll"

            } Catch {
                Write-Verbose "[Import-Package:Traversing] Unable to find crossplatform dlls for $($Package.Name)"
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
                        Where-Object { $_.Value -ne -1 } |
                        Sort-Object -Property Value |
                        Select-Object -First 1
                } | Where-Object { $_ } | Sort-Object -Property Value | Select-Object -First 1).Key

                If( $selected -and (Test-Path "$(Split-Path $Package.Source)\runtimes\$selected") ){
                    Write-Verbose "[Import-Package:Traversing] Found $selected folder in $($Package.Name) package"
                    Try {
                        $dlls.runtime = Resolve-Path "$(Split-Path $Package.Source)\runtimes\$selected\native\*.dll" -ErrorAction SilentlyContinue
                        Write-Verbose "[Import-Package:Traversing] Found $($dlls.runtime.Count) native dlls for $($Package.Name) for $selected"
                        if( $dlls.runtime.count -gt 1 ){
                            $dlls.runtime = $dlls.runtime -as [System.Collections.ArrayList]
                        } Elseif( $dlls.runtime.count ){
                            $_runtime = $dlls.runtime[0]
                            $dlls.runtime = [System.Collections.ArrayList]::new()
                            $dlls.runtime.Add( $_runtime ) | Out-Null
                        } Else {
                            $dlls.runtime = [System.Collections.ArrayList]::new()
                        }
                        Write-Verbose "[Import-Package:Traversing] Found $((Resolve-Path "$(Split-Path $Package.Source)\runtimes\$selected\lib\$short_framework\*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
                            $dlls.runtime.Add( $_ ) | Out-Null
                            $true
                        }).Count) native dlls for $($Package.Name) for $selected specific to $short_framework"
                        If( $dlls.runtime.Count -eq 0){
                            Write-Verbose "[Import-Package:Traversing] No native dlls for $short_framework found in $selected for $($Package.Name)"
                            $dlls.runtime = $null
                        }
                    } Catch {
                        Write-Verbose "[Import-Package:Traversing] Unable to find dlls for $($Package.Name) for $($bootstrapper.runtime)"
                        return
                    }
                }
            }
        }

        if ( $dlls.lib -or $dlls.runtime ) {
            $loaded[ $nuspec_id ] = $short_framework
            if( $dlls.lib ){
                $dlls.lib | ForEach-Object {
                    $dll = $_
                    Try {
                        Import-Module $_ -ErrorAction Stop
                    } Catch {
                        Write-Error "[Import-Package:Loading] Unable to load 'lib' dll ($($dll | Split-Path -Leaf)) for $($Package.Name)`n$($_.Exception.Message)`n"
                        $_.Exception.GetBaseException().LoaderExceptions | ForEach-Object { Write-Host $_.Message }
                        return
                    }
                }
            }
            if( $dlls.runtime ){
                $dlls.runtime | ForEach-Object {
                    $dll = $_
                    Try {
                        If( $bootstrapper.TestNative( $_.ToString() ) ){
                            Write-Verbose "[Import-Package:Loading] $_ is a native dll for $($Package.Name)"
                            Write-Verbose "- Moving to '$TempPath'"
                            $bootstrapper.LoadNative( $_.ToString(), $TempPath )   
                        } Else {
                            Write-Verbose "[Import-Package:Loading] $_ is not native, but is a platform-specific dll for $($Package.Name)"
                            Import-Module $_
                        }
                    } Catch {
                        Write-Error "[Import-Package:Loading] Unable to load 'runtime' dll ($($dll | Split-Path -Leaf)) for $($Package.Name) for $($bootstrapper.runtime)`n$($_.Exception.Message)`n"
                        return
                    }
                }
            }
        } else {
            Write-Verbose "[Import-Package:Loading] Package $($Package.Name) does not need to be loaded for $package_framework"
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
    # Automatically fixes the missing WinRT functionality in PowerShell Core on Windows
    If( ($global:DIS_AUTOUPDATE_IMPORTS -eq $true ) -or ( $env:DIS_AUTOUPDATE_IMPORTS -eq 1 ) ){
        Import-Package "Microsoft.Windows.SDK.NET.Ref" -Offline
    } Else {
        Import-Package "Microsoft.Windows.SDK.NET.Ref"
    }
}
Export-ModuleMember -Function @(
    "Import-Package",
    "Read-Package",
    "Get-Dotnet",
    "Get-Runtime"
)