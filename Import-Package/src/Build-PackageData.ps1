function Build-PackageData {
    param(
        [Parameter(Mandatory)]
        $Bootstrapper,

        [Parameter(Mandatory)]
        [ValidateSet("Object","Install","File")]
        [string] $From,
        [Parameter(Mandatory)]
        $Options,
        $Manifest # Unused will have to be worked out at a later date
        <#
            The purpose of the manifest will be to modify how Install-Package handles Importing
            
            May need to account for skipping, special conditions, and possibly postload scripts

            There have been 3 considerations for where this manifest will be sourced from:
            - a .nupkg's .psd1 file
            - a .nupkg's .nuspec file
            - possibly a separate .json or .ps1 file
        #>
    )
    $Out = @{
        "Name" = "Undefined"
        "Version" = "Undefined"
        "Source" = "Undefined"
        "TempPath" = "Undefined"
        "Offline" = $false
    }

    $Options = If( $Options.Count -gt 1 ){
        $temp_options = @{}
        $Options | ForEach-Object {
            $iter_options = $_
            $Out.Keys | ForEach-Object {
                $temp_options[ $_ ] = $iter_options[ $_ ] 
            }
        }

        $temp_options
    } Else {
        $Options
    }

    # For now, this option will be universal - this may or may not change
    $Out.TempPath = $Options.TempPath
    $Out.Offline = [bool] $Options.Offline

    switch( $From ){
        "Object" {
            $out_keys = $Out.Keys | % { $_ }

            $out_keys | ForEach-Object {
                $Out[ $_ ] = $Options[ $_ ]
            }
        }
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

            $out_keys = $Out.Keys | % { $_ }

            $out_keys | ForEach-Object {
                $Out[ $_ ] = $Options[ $_ ]
            }
        }
        "File" {
            # This needs to be corrected by the .nuspec, if it is specified in the nuspec
            # Additionally, if the version is specifed in the .nuspec, it needs to be provided here
            $Out.Name = (Split-Path $Options.Source -Leaf)

            # Unpack the package to the TempPath temporary directory
            [System.IO.Compression.ZipFile]::ExtractToDirectory( $Options.Source.ToString(), $Options.TempPath.ToString() )
            # Copy the nupkg to the temporary directory as well
            Copy-Item -Path $Options.Source.ToString() -Destination $Options.TempPath.ToString() -Force

            $Out.Source = @(
                $Options.TempPath.ToString(),
                (Split-Path $Options.Source -Leaf)
            ) -join "\"
        }
    }

    $out_keys = $Out.Keys | % { $_ }

    $out_keys | ForEach-Object {
        If( $Out[ $_ ] -eq "Undefined" ){
            $Out[ $_ ] = $Null
        }
    }

    <#
        If Manifest and skipping logic gets implemented, the skipping logic:
        - may occur further up in the function
        - should not occur after the .Source check below
    #>

    If( -not( Test-Path $Out.Source ) ){
        Write-Error "[Import-Package:Preparation] Unable to find package $( $Out.Name )"
        return
    }

    Write-Verbose "[Import-Package:Preparation] Reading package $( $Out.Name )$( If( $Out.Version ) { " $( $Out.Version )"})"

    $Out.XML = $Bootstrapper.ReadNuspec( $Out.Source )

    Write-Verbose "[Import-Package:Preparation] Validating .nuspec for $( $Out.Name )..."
    & {
        $nuspec_id = $Out.XML.package.metadata.id.ToString()
        $nuspec_version = $Out.XML.package.metadata.version.ToString()

        $versions_available = $nuspec_version -and $Out.Version
        $names_available = $nuspec_id -and $Out.Name

        $version_mismatch = $nuspec_version -ne $Out.Version
        $names_mismatch = $nuspec_id -ne $Out.Name

        If( $names_available -and $versions_available ){
            If( $version_mismatch -and (-not $Unmanaged) ){
                Throw "[Import-Package:Preparation] Version mismatch for $( $Out.Name )"
                return
            } Else {
                $Out.Version = $nuspec_version # For most cases these will already be equal, but for unmanaged it isn't
            }

            If( $names_mismatch ){
                If( $Unmanaged ){
                    Write-Warning "[Import-Package:Preparation] Package $( $Out.Name ).nupkg has a nuspec with the name $nuspec_id. Changing name..."
                    $Out.Name = $nuspec_id
                } Else {
                    Throw "[Import-Package:Preparation] Package $( $Out.Name ).nupkg has a .nuspec with the invalid ID $nuspec_id."
                    return
                }
            }
        }
    }

    Write-Verbose "[Import-Package:Preparation] Checking for OS-specific files"
    If( Test-Path "$(Split-Path $Out.Source )\runtimes" ){
        $available_rids = Get-ChildItem "$(Split-Path $Out.Source )\runtimes" -Directory | Select-Object -ExpandProperty Name
        $Out.RIDs = $available_rids
    
        $rid = $Bootstrapper.graphs | ForEach-Object {
            <#
                A big problem with selecting a package RID is that there maybe:
                - multiple RID graphs
                - multiple RIDs on each graph
                - multiple RIDs in the nupkg (we will call these available_rids)
    
                The earlier an RID occurs on a RID graph,
                  the more representative it is of the host operating system
                
                - for example, for a Windows 10 x64 graph:
                  - "win10-x64" will typically be the first element 
                  - "win", "any", and "base" will be at the end of the graph
    
                To determine which available_rid is correct,
                  we need to check how early on the graphs they are.
    
                To do that, we iterate over each graph,
                  and record the index of each available_rid as they occur on said graph:
            #>
    
            $index_table = @{}
            $graph = $_
    
            $available_rids | ForEach-Object {
                $i = $graph.IndexOf( $_ )
                If( $i -ne -1 ){
                    # If they don't exist on the graph, we don't record them
                    $index_table[ $_ ] = $i
                }
            }
    
            # for each available_rid that was found on the graph,
            #   we return the one (as a key(rid)-value(index) pair) with the lowest index:
            $index_table.GetEnumerator() | Sort-Object -Property Value | Select-Object -First 1 # this will return null, if it wasn't found on the current graph
        } | Sort-Object -Property Value | Select-Object -First 1 # then we return the lowest kv-pair for all graphs
         
        If( Test-Path "$(Split-Path $Out.Source)\runtimes\$( $rid.Key )" ){
            Write-Verbose "[Import-Package:Preparation] Found $( $Out.Name ) runtime files for this platform ($( $rid.Key ))."
            $Out.RID = $rid.Key
            Write-Verbose "[Import-Package:Preparation] Checking the OS-specific files for framework-specific files..."
            Try{
                $rid_libs = Get-ChildItem "$(Split-Path $Out.Source )\runtimes\$( $rid.Key )\lib" -Directory -ErrorAction Stop | Select-Object -ExpandProperty Name
                $Out.RID_Frameworks = $rid_libs
            } Catch {}
        }
    }

    Write-Verbose "[Import-Package:Preparation] Checking OS-agnostic framework-specific files..."

    Try{
        $Out.Frameworks = Get-ChildItem "$( Split-Path $Out.Source )\lib" -Directory -ErrorAction Stop | Select-Object -ExpandProperty Name
    } Catch {}

    Write-Verbose "[Import-Package:Preparation] Reading dependencies..."
    $out_dependencies = @{}

    Try {
        $out_dependencies.Agnostic = Resolve-DependencyVersions $Out.XML.package.metadata.dependencies.dependency
    } Catch {}
    Try{
        $out_dependencies.ByFramework = & {
            $by_framework = @{}
            $Out.XML.package.metadata.dependencies.group | ForEach-Object {
                $group = $_

                $by_framework[ $group.TargetFramework.ToString() ] = Resolve-DependencyVersions $group.dependency
            }
            $by_framework
        }
    } Catch {}

    If( $out_dependencies.Keys.Count ){
        $Out.Dependencies = $out_dependencies
    }

    <#
        Output Object Keys:
        - TempPath
        - Offline

        - Name
        - Version
        - Source

        - XML # the nuspec as parsed XML

        - RIDs (if applicable) # Available RIDS in package
        - RID (if applicable) # The RID best-suiting the OS. This is set here, because it can't be selected by the user
        - RID_Frameworks (if applicable) # Any framework folders for the above RID

        - Frameworks # Platform agnostic framework folders

        - Dependencies
          - Agnostic
          - ByFramework
    #>

    $Out
}