# Initialize - Bootstraps the nuget type system
Write-Verbose "[Import-Package:Init] Initializing..."
$bootstrapper = & (Resolve-Path "$PSScriptRoot\packaging.ps1")
$global:loaded = @{
    "NuGet.Frameworks" = "netstandard2.0"
}

. "$PSScriptRoot\src\Resolve-DependencyVersions.ps1";
. "$PSScriptRoot\src\Build-PackageData.ps1"

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
    
    .Parameter TempPath
        The directory to place and load native dlls from. Defaults to the current directory.

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
        [Alias("PackagePath","Source")]
        [string] $Path,
        
        [switch] $Offline,

        [string] $TempPath = (& {
            $parent = [System.IO.Path]::GetTempPath()
            [string] $name = [System.Guid]::NewGuid()
            New-Item -ItemType Directory -Path (Join-Path $parent $name)
            # Resolve-Path "."
        })
    )

    Process {
        $PackageData = Switch( $PSCmdlet.ParameterSetName ){
            "Managed-Object" {
                Write-Verbose "[Import-Package:ParameterSet] Managed Object"

                Build-PackageData -From "Object" -Options @( $Package, @{
                    "TempPath" = $TempPath
                }) -Bootstrapper $bootstrapper
            }
            "Managed" {
                Write-Verbose "[Import-Package:ParameterSet] Managed"

                Build-PackageData -From "Install" -Options @{
                    "TempPath" = $TempPath

                    "Offline" = $Offline # If true, do not install
                    
                    "Name" = $Name
                    "Version" = $Version
                } -Bootstrapper $bootstrapper
            }
            "Unmanaged" {
                Write-Verbose "[Import-Package:ParameterSet] Unmanaged"

                Build-PackageData -From "File" -Options @{
                    "TempPath" = $TempPath

                    "Source" = $Path
                } -Bootstrapper $bootstrapper
            }
        }

        If( $PackageData ){
            Write-Verbose "[Import-Package:Preparation] Package $($PackageData.Name)$( If( $PackageData.Version ) { " $( $PackageData.Version ) successfully read"})"
        } Else {
            Write-Host "[Import-Package:Preparation] Package $($PackageData.Name) was skipped!"
        }

        Write-Verbose "[Import-Package:Framework-Handling] Selecting best available framework from package $($PackageData.Name)"

        $TargetFramework = $TargetFramework -as [NuGet.Frameworks.NuGetFramework]

        $TargetFramework = & {
            If( $PackageData.Frameworks ){
                $parsed_frameworks = $PackageData.Frameworks | ForEach-Object {
                    # $PackageData.Frameworks is in ShortFolderName (or TFM) format, it needs to be converted
                    [NuGet.Frameworks.NuGetFramework]::Parse( $_ )
                }
                $nearest_framework = Switch( $parsed_frameworks.Count ){
                    0 { $TargetFramework } # Fallback to the user provided one
                    1 { 
                        $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]@( $parsed_frameworks ) )
                    }
                    default {
                        $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]$parsed_frameworks )
                    }
                }
                If( $nearest_framework ){
                    $nearest_framework
                } Else {
                    $TargetFramework
                }
            } Elseif ( $PackageData.RID_Frameworks ){
                $parsed_frameworks = $PackageData.RID_Frameworks | ForEach-Object {
                    # $PackageData.RID_Frameworks is in ShortFolderName (or TFM) format, it needs to be converted
                    [NuGet.Frameworks.NuGetFramework]::Parse( $_ )
                }
                $nearest_framework = Switch( $parsed_frameworks.Count ){
                    0 { $TargetFramework } # Fallback to the user provided one
                    1 {
                        $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]@( $parsed_frameworks ))
                    }
                    default {
                        $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]$parsed_frameworks )
                    }
                }
                If( $nearest_framework ){
                    $nearest_framework
                } Else {
                    $TargetFramework
                }
            } Else {
                # Fallback to the user provided one
                $TargetFramework
            }
        }

        $target_rid_framework = If( -not $PackageData.Frameworks ){
            $TargetFramework
        } Elseif ( $PackageData.RID_Frameworks ){
            $parsed_frameworks = $PackageData.RID_Frameworks | ForEach-Object {
                # $PackageData.RID_Frameworks is in ShortFolderName (or TFM) format, it needs to be converted
                [NuGet.Frameworks.NuGetFramework]::Parse( $_ )
            }
            $nearest_framework = Switch( $parsed_frameworks.Count ){
                0 { $TargetFramework } # Fallback to the user provided one
                1 { 
                    $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]@( $parsed_frameworks ) )
                }
                default {
                    $bootstrapper.Reducer.GetNearest( $TargetFramework, [NuGet.Frameworks.NuGetFramework[]]$parsed_frameworks )
                }
            }
            If( $nearest_framework ){
                $nearest_framework
            } Else {
                $TargetFramework
            }
        } Else {
            $TargetFramework
        }
        If( -not $target_rid_framework ){
            Write-Host $PackageData.Name $PackageData.Frameworks.Count $PackageData.RID_Frameworks.Count; pause
            $target_rid_framework = $TargetFramework
        }
        
        Write-Verbose "[Import-Package:Framework-Handling] Selected OS-agnostic framework $TargetFramework"
        Write-Verbose "[Import-Package:Framework-Handling] Selected OS-specific framework $target_rid_framework"

        If( $PackageData.Dependencies -and -not $Offline ){
            Write-Verbose "[Import-Package:Dependency-Handling] Loading dependencies for $( $PackageData.Name )"
            If( $PackageData.Dependencies.Agnostic ){
                $package_framework = $TargetFramework
                $PackageData.Dependencies.Agnostic | ForEach-Object {
                    If( $loaded[ $_.Name ] ){
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) $($_.Name) already loaded"
                    } Else {
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) Loading $($_.Name) - $($_.Version) (Framework $( $package_framework.GetShortFolderName() ))"
                        If( $Offline ){
                            Import-Package $_.Name -Version $_.Version -TargetFramework $package_framework -Offline
                        } Else {
                            Import-Package $_.Name -Version $_.Version -TargetFramework $package_framework
                        }
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) $($_.Name) Loaded"
                    }
                }
            }
            If( $PackageData.Dependencies.ByFramework ){
                $package_framework = & {
                    $parsed_frameworks = $PackageData.Dependencies.ByFramework.Keys -as [NuGet.Frameworks.NuGetFramework[]]
                    $selected_framework = $bootstrapper.Reducer.GetNearest( $TargetFramework, $parsed_frameworks )
                    $unparsed_selected_framework = $PackageData.Dependencies.ByFramework.Keys | Where-Object {
                        ([NuGet.Frameworks.NuGetFramework] $_).ToString() -eq ($selected_framework).ToString()
                    }
                    
                    $unparsed_selected_framework
                }
                $PackageData.Dependencies.ByFramework[ $package_framework ] | ForEach-Object {
                    If( $loaded[ $_.Name ] ){
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) $($_.Name) already loaded"
                    } Else {
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) Loading $($_.Name) - $($_.Version) (Framework $( ([NuGet.Frameworks.NuGetFramework]$package_framework).GetShortFolderName() ))"
                        If( $Offline ){
                            Import-Package $_.Name -Version $_.Version -TargetFramework $package_framework -Offline
                        } Else {
                            Import-Package $_.Name -Version $_.Version -TargetFramework $package_framework
                        }
                        Write-Verbose "[Import-Package:Dependency-Handling] ($($PackageData.Name) Dependency) $($_.Name) Loaded"
                    }
                }
            }
        }

        $dlls = @{
            "lib" = [System.Collections.ArrayList]::new()
        }
        Write-Verbose "[Import-Package:Loading] Locating OS-agnostic dlls"
        $short_folder_name = $TargetFramework.GetShortFolderName()
        If( Test-Path "$(Split-Path $PackageData.Source)\lib" ){
            Write-Verbose "[Import-Package:Loading] Locating OS-agnostic framework-agnostic dlls"
            Try {
                $agnostic_dlls = Resolve-Path "$(Split-Path $PackageData.Source)\lib\*.dll" -ErrorAction Stop
                Switch( $agnostic_dlls.Count ){
                    0 {}
                    1 { $dlls.lib.Add( $agnostic_dlls ) | Out-Null }
                    default { $dlls.lib.AddRange( $agnostic_dlls ) | Out-Null }
                }
                Write-Verbose "[Import-Package:Loading] Found $( $dlls.lib.Count ) OS-agnostic framework-agnostic dlls"
            } Catch {
                Write-Verbose "[Import-Package:Loading] Unable to find OS-agnostic framework-agnostic dlls for $($PackageData.Name)"
                return
            }
            If( Test-Path "$(Split-Path $PackageData.Source)\lib\$short_folder_name" ){
                Write-Verbose "[Import-Package:Loading] Locating OS-agnostic dlls for $short_folder_name"
                Try {
                    $framework_dlls = Resolve-Path "$(Split-Path $PackageData.Source)\lib\$short_folder_name\*.dll" -ErrorAction Stop
                    Switch( $framework_dlls.Count ){
                        0 {}
                        1 { $dlls.lib.Add( $framework_dlls ) | Out-Null }
                        default { $dlls.lib.AddRange( $framework_dlls ) | Out-Null }
                    }
                    Write-Verbose "[Import-Package:Loading] Found $( $dlls.lib.Count ) OS-agnostic dlls for $short_folder_name"
                } Catch {
                    Write-Verbose "[Import-Package:Loading] Unable to find OS-agnostic dlls for $($PackageData.Name) for $short_folder_name"
                    return
                }
            }
        }

        Write-Verbose "[Import-Package:Loading] Locating OS-specific dlls"
        $short_folder_name = $target_rid_framework.GetShortFolderName()
        If( Test-Path "$(Split-Path $PackageData.Source)\runtimes\$( $PackageData.RID )" ){
            $dlls.runtime = [System.Collections.ArrayList]::new()
            Try {
                $native_dlls = Resolve-Path "$(Split-Path $PackageData.Source)\runtimes\$( $PackageData.RID )\native\*.dll" -ErrorAction Stop
                Switch( $native_dlls.Count ){
                    0 {}
                    1 { $dlls.runtime.Add( $native_dlls ) | Out-Null }
                    default { $dlls.runtime.AddRange( $native_dlls ) | Out-Null }
                }
                Write-Verbose "[Import-Package:Loading] Found $( $native_dlls.Count ) OS-specific native dlls"
            } Catch {
                Write-Verbose "[Import-Package:Loading] Unable to find OS-specific native dlls for $($PackageData.Name) on $($bootstrapper.runtime)"
                return
            }
            If( Test-Path "$(Split-Path $PackageData.Source)\runtimes\$( $PackageData.RID )\lib\$short_folder_name" ){
                Try {
                    $lib_dlls = Resolve-Path "$(Split-Path $PackageData.Source)\runtimes\$( $PackageData.RID )\lib\$short_folder_name\*.dll" -ErrorAction Stop
                    Switch( $lib_dlls.Count ){
                        0 {}
                        1 { $dlls.runtime.Add( $lib_dlls ) | Out-Null }
                        default { $dlls.runtime.AddRange( $lib_dlls ) | Out-Null }
                    }
                    Write-Verbose "[Import-Package:Loading] Found $( $lib_dlls.Count ) OS-specific managed dlls"
                } Catch {
                    Write-Verbose "[Import-Package:Loading] Unable to find OS-specific managed dlls for $($PackageData.Name) on $($bootstrapper.runtime)"
                    return
                }
            }
        }

        $loaded[ $PackageData.Name ] = @(
            $TargetFramework.GetShortFolderName(),
            $target_rid_framework.GetShortFolderName()
        )

        if ( $dlls.lib -or $dlls.runtime ) {
            if( $dlls.lib ){
                $dlls.lib | ForEach-Object {
                    $dll = $_
                    Try {
                        Import-Module $_ -ErrorAction Stop
                    } Catch {
                        Write-Error "[Import-Package:Loading] Unable to load 'lib' dll ($($dll | Split-Path -Leaf)) for $($PackageData.Name)`n$($_.Exception.Message)`n"
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
                            Write-Verbose "[Import-Package:Loading] $_ is a native dll for $($PackageData.Name)"
                            Write-Verbose "- Moving to '$TempPath'"
                            $bootstrapper.LoadNative( $_.ToString(), $TempPath ) | ForEach-Object { Write-Verbose "[Import-Package:Loading] Dll retunrned leaky handle $_"}   
                        } Else {
                            Write-Verbose "[Import-Package:Loading] $_ is not native, but is a OS-specific dll for $($PackageData.Name)"
                            Import-Module $_
                        }
                    } Catch {
                        Write-Error "[Import-Package:Loading] Unable to load 'runtime' dll ($($dll | Split-Path -Leaf)) for $($PackageData.Name) for $($bootstrapper.runtime)`n$($_.Exception.Message)`n"
                        return
                    }
                }
            }
        } else {
            Write-Warning "[Import-Package:Loading] $($PackageData.Name) is not needed for $( $bootstrapper.Runtime )`:$($TargetFramework.GetShortFolderName())"
            return
        }
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