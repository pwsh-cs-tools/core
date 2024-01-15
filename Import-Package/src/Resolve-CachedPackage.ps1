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
            $Options.Name = (Split-Path $Options.Source -Leaf)

            # Unpack the package to the TempPath temporary directory
            [System.IO.Compression.ZipFile]::ExtractToDirectory( $Options.Source.ToString(), $Options.TempPath.ToString() )
            # Copy the nupkg to the temporary directory as well
            Copy-Item -Path $Options.Source.ToString() -Destination $Options.TempPath.ToString() -Force

            $Options.Source = Join-Path $Options.TempPath.ToString() (Split-Path $Options.Source -Leaf)
        }
    }
}