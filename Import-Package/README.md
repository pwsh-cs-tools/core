# PowerShell C# Tools - Import-Package
Imports NuGet/Nupkg packages downloaded by PackageManagement

## Description
PackageManagement's default package providers (NuGet and PowerShellGet/Gallery) lack the ability to load their NuGet Packs into PowerShell.
- While PowerShellGallery Packages can be loaded with `Import-Module`, they import the packs using a module manifest, not the actual nuspec.

This module provides a `Import-Package` cmdlet for importing packages by the nuspec instead of the module manifest.

By offering the commands `Import-Package` and `Import-Module` separately, this module allows you to handle the C# dependencies (.nuspec) and PowerShell dependencies (.psd1) from the same pack file on their own. This is useful for dependency control. A couple of use cases for this feature:
- You want to rewrite an existing powershell module using the same C# dependencies, but you want to provide a different PowerShell API.
- You are using multiple PowerShell modules that depend on the same C# dependencies, and don't want to load the same C# dependencies multiple times.
- You want to inject your own C# dependencies into a PowerShell module.

## Syntax and Usage
```powershell
Import-Package `
    -Package <package_name> `
    -PackageProvider <package_provider(default:"NuGet")>`
    -Version <semver(default:latest)> `
    -TargetFramework <tfm(default:system-default)>
```
### Parameters
- Name:
  - The name of the package to import.
  - ParameterSetName: Managed (default)
- PackageProvider:
  - The name of the PackageManagement Provider to use.
  - ParameterSetName: Managed (default)
  - Default: 'NuGet'
    - Reason: PowerShellGallery modules can already be imported and handled with Import-Module.
- Version:
  - The version of the package to import.
  - ParameterSetName: Managed (default)
  - Default: latest version

- Package:
  - The SoftwareIdentity object of the package to import (returned by Get-Package)
  - ParameterSetName: Managed-Object

- Path
  - The path to the .nupkg file to import.
  - Alias: PackagePath
  - ParameterSetName: Unmanaged

- TargetFramework:
  - The target framework of the package to import.
  - Default: TFM of the current PowerShell session.

- Offline
  - Skip downloading the package from the package provider.
- SkipDependencies
  - Skip automatic dependency handling.

- CachePath:
  - The directory to place and load packages not provided by PackageManagement. These can be SemVer2 packages or packages provided with -Path
- NativePath:
  - The directory to place and load native dlls from. Defaults to the current directory.


### Examples
#### Import the Packs that this Module does:
```powershell
Import-Package -Package 'NuGet.Frameworks' -TargetFramework 'netstandard2.0'
Import-Package -Package 'Microsoft.NETCore.Platforms' -TargetFramework 'netstandard2.0'
```

## Note
This module is designed to be simplistic and cross-platform. In theory, it should be supported by every version of PowerShell. It only depends on being able to download and import NuGet.Frameworks and NuGet.Packaging for the .NET Standard 2.0 TFM (which every version of PowerShell should support).

If it isn't fully cross-platform, please open a ticket, so a patch can be explored