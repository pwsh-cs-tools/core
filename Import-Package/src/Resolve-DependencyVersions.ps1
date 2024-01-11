function Resolve-DependencyVersions {
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