# Custom function to convert SemVer string to a comparable object
# Using this over Automation.SemanticVersion, since Automation.SemanticVersion only works in pwsh 7.2+
function ConvertTo-SemVerObject( [string]$semVerString ) {

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
    
# Custom comparison function for SemVer
function Compare-SemVerObject($x, $y) {
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