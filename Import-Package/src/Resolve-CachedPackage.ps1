function Resolve-CachedPackage {
    param(
        [Parameter(Mandatory)]
        $Bootstrapper,

        [Parameter(Mandatory)]
        [ValidateSet("Object","Install","File")]
        [string] $From,
        [Parameter(Mandatory)]
        $Options
    )

    switch( $From ){
        "Object" {}
        "Install" {

            # Check desired version against PackageManagement's local cache
            # Check desired version against NuGet (both stable and prerelease)
            
            # **Fallback** to internal local cache.
            <#
                **Reasoning:

                PackageManagement is to be prioritized. The purpose of this module is not to reproduce the efforts of PackageManagement
                - Import-Package's purpose is to patch in features that you would expect PackageManagement (PM) to include.
                
                One such feature is that at this time, PM's Install-Package doesn't support SemVer 2 while NuGet's Install-Package does.
                So, any package not installable by PM will be installed by Import-Package to an internal cache directory.
                - The reason for not using NuGet's Install-Package is that NuGet may or may not be installed on the target system.

                Additionally, any package imported using the -Path parameter will be cached here.

                The Import-Package module is also designed in such a way that if PM were to update from SemVer 1 to SemVer 2,
                PM packages will still be prioritized. In the long run, this will help reduce Import-Package's file bloat.
            #>
            
            $versions = @{}
            $versions.wanted = $Options.Version
            $versions.pm = @{}

            # Check for a locally installed version from PackageManagement (pm)
            # Also, cache the pm package in memory for faster loading, if it is available
            $pm_package = Get-Package $Options.Name -RequiredVersion (& {
                # Scripting the -RequiredVersion parameter is more performant than several calls to Get-Package
                If( [string]::IsNullOrWhiteSpace( $versions.wanted ) ){
                    $null
                } Else {
                    $versions.wanted.ToString()
                }
            }) -ProviderName NuGet -ErrorAction SilentlyContinue

            $versions.pm.local = $pm_package.Version

            If( -not $Options.Offline ){
                # Check for the upstream version (from NuGet)

                If( $Options.Stable ){
                    $versions.pm.upstream = Try {
                        $Bootstrapper.GetLatest( $Options.Name )
                    } Catch {}
                }

                # If Options.Stable was false or an upstream stable version could not be found, try for a prerelease version
                If( [string]::IsNullOrWhiteSpace( "$( $versions.pm.upstream )" ) ){
                    $versions.pm.upstream = Try {
                        $Bootstrapper.GetPreRelease( $Options.Name, $versions.wanted )
                    } Catch {}

                    # If a prerelease was selected ensure $Options.Stable gets forced to false
                    If( -not [string]::IsNullOrWhiteSpace( "$( $versions.pm.upstream )" ) ){
                        $Options.Stable = $false
                    }
                }
            }

            $versions.cached = @{}; & {
                $root = $Options.CachePath

                $cached_packages = Join-Path $root "*"
                $cached_packages = Resolve-Path $cached_packages
                $cached_packages = Split-Path $cached_packages -Leaf

                # Get all cached packages with the same name
                $candidate_packages = $cached_packages | Where-Object {
                    "$_" -like "$( $Options.Name )*"
                }

                If( $candidate_packages ){

                    # Get all versions in the directory
                    $candidate_versions = $candidate_packages | ForEach-Object {
                        # Exact replace (.Replace()) followed by regex-replace (-replace)
                        $out = "$_".Replace( $Options.Name, "" ) -replace "^\.",""
                        If( $out -eq $versions.wanted ){
                            $versions.cached.local = $out
                        }
                        $out
                    }
    
                    $candidate_versions = [string[]] $candidate_versions

                    [Array]::Sort[string]( $candidate_versions, [System.Comparison[string]]({
                        param($x, $y)
                        $x = ConvertTo-SemVerObject $x
                        $y = ConvertTo-SemVerObject $y
    
                        Compare-SemVerObject $x $y
                    }))

                    If( -not $versions.cached.local ){
                        $versions.cached.local = $candidate_versions | Select-Object -Last 1
                    }
    
                    If(@(
                        $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent,
                        ($VerbosePreference -ne 'SilentlyContinue')
                    ) -contains $true ){
                        Write-Host
                        Write-Verbose "[Import-Packge:Preparation] Detected cached packages for $( $Options.Name ) for versions:"
                        $candidate_versions | ForEach-Object {
                            If( $_ -eq $versions.cached.local ){
                                Write-Host ">" $_ -ForegroundColor Green
                            } Else {
                                Write-Host "-" $_
                            }
                        }
                        Write-Host
                        Write-Host "> = either latest or selected version in cache" -ForegroundColor Green
                        Write-Host
                    }
                }
            }

            # At this point we have checked both the PM and Cached Packages for the desired version
            # We have also selected the latest from each in the case that the desired version was not found

            $no_local = -not (& {
                $versions.pm.local -or $versions.cached.local
            })
            $no_upstream = -not (& {
                $versions.pm.upstream
            })

            $versions.best = @{}
            If( -not $no_local ){
                $versions.best.local = & {
                    If( $versions.wanted ){
                        switch( $versions.wanted ){
                            $versions.pm.local { "pm"; break; }
                            $versions.cached.local { "cached" }
                        }
                    } Elseif( $versions.pm.local ){
                        "pm"
                    } Elseif( $versions.cached.local ){
                        "cached"
                    }
                }
            }
            If( -not $no_upstream ){
                $versions.best.upstream = & {
                    "pm"
                }
            }

            If(@(
                $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent,
                ($VerbosePreference -ne 'SilentlyContinue')
            ) -contains $true ){
                Write-Host
                Write-Verbose "[Import-Packge:Preparation] Version control data for $( $Options.Name ):"

                Write-Host "Wanted version:" $versions.wanted -ForegroundColor (& {
                    If( $versions.wanted ){
                        "Green"
                    } Else {
                        "DarkGray"
                    }
                })
                Write-Host
                Write-Host "No upstream:" $no_upstream -ForegroundColor Cyan "(if -offline is used, this should be True)"
                Write-Host "No local:" $no_local -ForegroundColor Cyan
                Write-Host
                Write-Host "Best local source:" $versions.best.local
                Write-Host "Best upstream source:" $versions.best.upstream
                Write-Host
                Write-Host "Cached version:" $versions.cached.local -ForegroundColor (& {
                    If( $versions.best.local -eq "cached" ){
                        "Green"
                    } Else {
                        "DarkGray"
                    }
                })
                Write-Host "PM version:" $versions.pm.local -ForegroundColor (& {
                    If( $versions.best.local -eq "pm" ){
                        "Green"
                    } Else {
                        "DarkGray"
                    }
                })
                Write-Host "Upstream version:" $versions.pm.upstream -ForegroundColor (& {
                    If( $no_upstream ){
                        "DarkGray"
                    } Else {
                        "Magenta"
                    }
                })
                Write-Host
            }
            
            $install_condition = -not( $no_upstream ) -and (& {
                $no_local -or (& {
                    $best_upstream = $versions[ $versions.best.upstream ].upstream
                    $best_local = $versions[ $versions.best.local ].local

                    $best_upstream -ne $best_local
                })
            })

            $Options.Source = If( $install_condition ){
                If( $Options.Stable ){
                    Write-Verbose "[Import-Package:Preparation] Installing $( $Options.Name ) $( $versions[ $versions.best.upstream ].upstream )"
                    Try {
                        Install-Package $Options.Name `
                            -ProviderName NuGet `
                            -RequiredVersion $versions[ $versions.best.upstream ].upstream `
                            -SkipDependencies `
                            -Force `
                            -ErrorAction Stop | Out-Null
                    } Catch {
                        Install-Package $Options.Name `
                            -ProviderName NuGet `
                            -RequiredVersion $versions[ $versions.best.upstream ].upstream `
                            -SkipDependencies `
                            -Scope CurrentUser `
                            -Force | Out-Null
                    }

                    # Error check it and return it:
                    $pm_package = Get-Package $Options.Name -RequiredVersion $versions[ $versions.best.upstream ].upstream -ProviderName NuGet -ErrorAction Stop
                    If( $pm_package ){
                        $Options.Version = $versions[ $versions.best.upstream ].upstream

                        $pm_package.Source
                    } Else {
                        throw "[Import-Package:Preparation] Autoinstall of $( $Options.Name ) $( $versions[ $versions.best.upstream ].upstream ) failed."
                    }
                } Else {
                    $Options.Version = $versions[ $versions.best.upstream ].upstream
                    $package_name = "$( $Options.Name ).$( $Options.Version )"
                    
                    $output_path = Join-Path $Options.CachePath "$package_name" "$package_name.nupkg"

                    Try{
                        Resolve-Path $output_path -ErrorAction Stop
                    } Catch {
                        $resource = $bootstrapper.APIs.resources| Where-Object {
                            $_."@type" -eq "PackageBaseAddress/3.0.0"
                        }
                        $id = $resource."@id"

                        $url = @(
                            $id,
                            $Options.Name, "/",
                            $Options.Version, "/",
                            $package_name, ".nupkg"
                        ) -join ""

                        If(@(
                            $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent,
                            ($VerbosePreference -ne 'SilentlyContinue')
                        ) -contains $true ){
                            Write-Verbose "[Import-Package:Preparation] Installed $( $Options.Name ) $( $Options.Version ) from:"
                            Write-Host "-" $url -ForegroundColor Cyan
                            Write-Host
                        }

                        New-Item (Split-Path $output_path) -Force -ItemType Directory | Out-Null
                        Invoke-WebRequest -Uri $url -OutFile $output_path -ErrorAction Stop | Out-Null
                        [System.IO.Compression.ZipFile]::ExtractToDirectory( $output_path, (Split-Path $output_path), $true ) | Out-Null

                        $output_path
                    }
                }
            } Elseif( -not( $no_local ) ){
                $Options.Version = $versions[ $versions.best.local ].local

                If( $versions.best.local -eq "cached" ){
                    $package_name = "$( $Options.Name ).$( $Options.Version )"
                    Join-Path $Options.CachePath "$package_name" "$package_name.nupkg"
                } Else {
                    $pm_package.Source
                }
            } Else {
                throw "[Import-Package:Preparation] Could not retrieve any packages for $( $Options.Name )"
            }
        }
        "File" {
            $Options.Unmanaged = $true
            $Options.Offline = $true

            # This needs to be corrected by the .nuspec, if it is specified in the nuspec
            # Additionally, if the version is specifed in the .nuspec, it needs to be provided here
            $Options.Name = (Split-Path $Options.Source -LeafBase)

            $cache = Join-Path $Options.CachePath $Options.Name

            # Unpack the package to the cache directory
            If( -not( Test-Path $cache ) ){
                [System.IO.Compression.ZipFile]::ExtractToDirectory( $Options.Source.ToString(), $cache.ToString() )
            }

            $cache_nupkg = Join-Path $cache (Split-Path $Options.Source -Leaf)

            # Copy the nupkg to the cache directory as well
            If( -not( Test-Path $cache_nupkg ) ){
                Copy-Item -Path $Options.Source.ToString() -Destination $cache -Force
            }

            $Options.Source = $cache_nupkg.ToString()
        }
    }
}