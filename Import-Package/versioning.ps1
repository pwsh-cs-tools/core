param(
    [parameter(Mandatory = $true)]
    [psobject]
    $Exported
)

# Semantic Versioning
& {
    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name ParseSemVer `
        -Value {

            param( [string] $semVerString )

            $semVerParts = $semVerString -split '[-\+]'
            If( $semVerParts.Count -gt 2 ){
                $semVerParts = @(
                    $semVerParts[0],
                    (($semVerParts | Select-Object -Skip 1) -join "-")
                )
            }
            $versionParts = $semVerParts[0] -split '\.'
        
            $versionParts = $versionParts | ForEach-Object {
                [int]$_
            }
        
            # Convert main version parts to integers
            $major = $versionParts[0]
            $minor = $versionParts[1]
            $patch = $versionParts[2]
            $legacyPrerelease = If( $versionParts.Count -gt 3 ){
                $versionParts[3..($versionParts.Length-1)]
            }
        
            $preRelease = $null
            if ($semVerParts.Length -gt 1) {
                $preRelease = $semVerParts[1]
            }
        
            # Create a custom object
            New-Object PSObject -Property @{
                Major = $major
                Minor = $minor
                Patch = $patch
                LegacyPrerelease = $legacyPrerelease
                PreRelease = $preRelease
                Original = $semVerString
            }
            
        }
    
    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name CompareSemVers `
        -Value {
            param( $x, $y )
            if ($x.Major -ne $y.Major) {
                return $x.Major - $y.Major
            }
            if ($x.Minor -ne $y.Minor) {
                return $x.Minor - $y.Minor
            }
            if ($x.Patch -ne $y.Patch) {
                return $x.Patch - $y.Patch
            }
            if ($x.LegacyPrerelease -and $y.LegacyPrerelease){
                $max_length = [Math]::Max(
                    $x.LegacyPrerelease.Count,
                    $y.LegacyPrerelease.Count
                )
                for ($i = 0; $i -lt $max_length; $i++) {
                    $xlp = $x.LegacyPrerelease[ $i ]
                    $ylp = $y.LegacyPrerelease[ $i ]
                    If( $null -eq $xlp ){
                        return 1
                    }
                    If( $null -eq $ylp ){
                        return -1
                    }
                    If( $xlp -ne $ylp ){
                        return $xlp - $ylp
                    }
                }
            }
            # Handle pre-release comparison
            if ($x.PreRelease -and $y.PreRelease) {
                return [string]::Compare($x.PreRelease, $y.PreRelease)
            }
            if ($x.PreRelease) {
                return -1
            }
            if ($y.PreRelease) {
                return 1
            }
            return 0
        }
}

# NuGet APIs
& {
    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name APIs `
        -Value (& {
            $apis = Invoke-WebRequest https://api.nuget.org/v3/index.json
            ConvertFrom-Json $apis
        })

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name SearchLatest `
        -Value {
            param( $Name )
            $resource = $this.APIs.resources | Where-Object {
                ($_."@type" -eq "SearchQueryService") -and
                ($_.comment -like "*(primary)*")
            }
            $id = $resource."@id"

            $results = Invoke-WebRequest "$id`?q=packageid:$Name&prerelease=false&take=1"
            $results = ConvertFrom-Json $results

            If( $Name -eq $results.data[0].id ){
                $results.data[0].version
            } else {
                Write-Warning "Unable to find latest version of $Name via NuGet Search API"
            }
        }

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name GetAllVersions `
        -Value {
            param( $Name )
            $resource = $this.APIs.resources | Where-Object {
                $_."@type" -eq "PackageBaseAddress/3.0.0"
            }
            $id = $resource."@id"

            $versions = @(
                $id,
                $Name,
                "/index.json"
            ) -join ""

            $versions = Invoke-WebRequest $versions
            (ConvertFrom-Json $versions).versions
        }

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name GetPreRelease `
        -Value {
            param( $Name, $Wanted )

            $versions = $this.GetAllVersions( $Name )

            If( $Wanted ){
                $out = $versions | Where-Object {
                    $_ -eq $Wanted
                }
                If( $out ){
                    $out
                } Else {
                    $versions | Select-Object -last 1
                }
            } Else {
                $versions | Select-Object -last 1
            }
        }

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name GetStable `
        -Value {
            param( $Name, $Wanted )
            
            $version = $this.GetAllVersions( $Name ) | Where-Object {
                $parsed = $this.ParseSemVer( $_ )

                -not( $parsed.PreRelease <# -or $parsed.LegacyPrerelease #> )
            } | Where-Object {
                If( $Wanted ){
                    $_ -eq $Wanted
                } Else {
                    $true
                }
            } | Select-Object -Last 1

            If( $version ){
                $version
            } else {
                # if this is the case, Import-Package will default to GetPrerelease
                Write-Warning "Unable to find stable version of $Name$( If( $Wanted ){ " under version $Wanted" } )"
            }
        }
}

# NuGet Version Ranges
& {
    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name ParseVersOnDeps `
        -Value {
            param(
                $Dependencies
            )
        
            $Dependencies | Where-Object { $_ } | ForEach-Object {
                $version = $_.version
                $Out = @{
                    "Name" = $_.id
                    "Version" = (& {
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
                            Write-Warning "[Import-Package:Preparation] Exclusive version ranges are not yet supported."
                        }
                    })
                }
                $Out
            }
        }
}