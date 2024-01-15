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

            # Check desired version against internal local cache
            # Check desired version against PackageManagement's local cache
            # Check desired version against NuGet (both stable and prerelease)

            $package_attempts = @{}

            $package_attempts.local_latest = Get-Package $Options.Name -ProviderName NuGet -ErrorAction SilentlyContinue

            $version_available = Try{
                If( $Options.Version ){
                    $Options.Version
                } Elseif( $Options.Offline ) {
                    $package_attempts.local_latest.Version
                } Else {
                    $Bootstrapper.GetLatest( $Options.Name )
                }
            } Catch {
                $package_attempts.local_latest.Version
            }

            $install_conditions = @(
                (-not $package_attempts.local_latest), # Package not Installed
                ($package_attempts.local_latest.Version -ne $version_available ) # Package either not up to date, or isn't required version
            )

            if( $install_conditions ){

                $version_wanted = $version_available # For the purpose of self-documenting code

                $package_attempts.local_corrected_ver = Try {
                    
                    # Check if the wanted version exists in the old version cache
                    Get-Package $Options.Name -RequiredVersion $version_wanted -ProviderName NuGet -ErrorAction Stop
                }
                Catch {

                    # If it doesn't install it:
                    Write-Verbose "[Import-Package:Preparation] Installing $( $Options.Name ) $version_wanted"
                    Try {
                        Install-Package $Options.Name `
                            -ProviderName NuGet `
                            -RequiredVersion $version_wanted `
                            -SkipDependencies `
                            -Force `
                            -ErrorAction Stop | Out-Null
                    } Catch {
                        Install-Package $Options.Name `
                            -ProviderName NuGet `
                            -RequiredVersion $version_wanted `
                            -SkipDependencies `
                            -Scope CurrentUser `
                            -Force | Out-Null
                    }

                    # Error check it and return it:
                    Get-Package $Options.Name -RequiredVersion $version_wanted -ProviderName NuGet -ErrorAction Stop
                }
            }

            If( $package_attempts.local_corrected_ver ){
                $Options.Version = $package_attempts.local_corrected_ver.Version
                $Options.Source = $package_attempts.local_corrected_ver.Source
            } Else {
                $Options.Version = $package_attempts.local_latest.Version
                $Options.Source = $package_attempts.local_latest.Source
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