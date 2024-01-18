function Build-PackageData {
    param(
        [Parameter(Mandatory)]
        $Bootstrapper,

        [Parameter(Mandatory)]
        [ValidateSet("Object","Install","File")]
        [string] $From,
        [Parameter(Mandatory)]
        $Options
    )
    
    $Defaults = @{
        "Name" = "Undefined"
        "Version" = "Undefined"
        "Source" = "Undefined"
        "CachePath" = "Undefined"
        "NativePath" = "Undefined"
        "Offline" = $false
        "Stable" = $true
        "Unmanaged" = $false
    }

    $Options = If( @($Options).Count -gt 1 ){
        $temp_options = @{}
        $Options | ForEach-Object {
            $iter_options = $_
            $Defaults.Keys | ForEach-Object {
                $temp_options[ $_ ] = If( $iter_options[ $_ ] ){
                    $iter_options[ $_ ] 
                } Elseif( $Defaults[ $_ ].ToString() -ne "Undefined") {
                    $Defaults[ $_ ]
                }
            }
        }

        $temp_options
    } Else {
        $temp_options = @{}
        $Defaults.Keys | ForEach-Object {
            $temp_options[ $_ ] = If( $Options[ $_ ] ){
                $Options[ $_ ] 
            } Elseif( $Defaults[ $_ ].ToString() -ne "Undefined") {
                $Defaults[ $_ ]
            }
        }

        $temp_options
    }

    Resolve-CachedPackage -From $From -Options $Options -Bootstrapper $Bootstrapper

    $Out = @{}

    $default_keys = $Defaults.Keys | ForEach-Object { $_ }

    $default_keys | ForEach-Object {
        If( "$($Defaults[ $_ ])" -eq "Undefined" ){
            $Out[ $_ ] = $Null
        }
        $Out[ $_ ] = $Options[ $_ ]
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

        $version_mismatch = -not( $nuspec_version -like "$($Out.Version)*" )
        $names_mismatch = $nuspec_id -ne $Out.Name

        If( $names_available -and $versions_available ){
            If( $version_mismatch ){
                If( $Out.Unmanaged ){
                    $Out.Version = $nuspec_version
                } Else {
                    Throw "[Import-Package:Preparation] Version mismatch for $( $Out.Name )"
                    return
                }
            }

            If( $names_mismatch ){
                If( $Out.Unmanaged ){
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
        $out_dependencies.Agnostic = $Bootstrapper.ParseVersOnDeps( $Out.XML.package.metadata.dependencies.dependency )
    } Catch {}
    Try{
        $out_dependencies.ByFramework = & {
            $by_framework = @{}
            $Out.XML.package.metadata.dependencies.group | ForEach-Object {
                $group = $_

                $by_framework[ $group.TargetFramework.ToString() ] = $Bootstrapper.ParseVersOnDeps( $group.dependency )
            }
            $by_framework
        }
    } Catch {}

    If( $out_dependencies.Keys.Count ){
        $Out.Dependencies = $out_dependencies
    }

    <#
        Output Object Keys:
        - NativePath
        - Unmanaged
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

    If(@(
        $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent,
        ($VerbosePreference -ne 'SilentlyContinue')
    ) -contains $true ){
        Write-Host
        Write-Verbose "[Import-Package:Preparation] Parsed data for package $( $Out.Name ):"
        $Out.GetEnumerator() | Sort-Object @{Expression={$_.Name}; Ascending=$true} | Sort-Object {
            $type = If( -not [string]::IsNullOrWhiteSpace( $_.Value ) ){ $_.Value.GetType().ToString() }
            # Assign a sort order based on type
            switch ($type) {
                'System.Management.Automation.SwitchParameter' { return 3 }
                'System.Boolean' { return 2 }
                default { return 1 }
            }
        } | ForEach-Object {
            If( -not [string]::IsNullOrEmpty( $_.Value ) -and (@(
                [System.Management.Automation.SwitchParameter],
                [bool]
            ) -contains $_.Value.GetType()) ){
                If( $_.Value ){
                    Write-Host "-" $_.Key ":" "$($_.Value)" -ForegroundColor Green
                } Else {
                    Write-Host "-" $_.Key ":" "$($_.Value)" -ForegroundColor Red
                }
            } Elseif( $_.Value ) {
                Write-Host "-" $_.Key ":" "$($_.Value)"
            } Else {
                Write-Host "-" $_.Key ":" "$($_.Value)" -ForegroundColor Red
            }
        }
        Write-Host
    }

    $Out
}