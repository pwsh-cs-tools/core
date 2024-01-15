& {
    Add-Type -AssemblyName System.Runtime # Useful for RID detection
    Add-Type -AssemblyName System.IO.Compression.FileSystem # Useful for reading nupkg/zip files

    # Exported methods and properties
    $Exported = New-Object psobject

    $Exported | Add-Member `
        -MemberType NoteProperty `
        -Name APIs `
        -Value (& {
            $apis = Invoke-WebRequest https://api.nuget.org/v3/index.json
            ConvertFrom-Json $apis
        })

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name GetLatest `
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
        -Name ReadNuspec `
        -Value {
            param(
                [parameter(Mandatory = $true)]
                [string]
                $Path
            )
            $nupkg = [System.IO.Compression.ZipFile]::OpenRead( $path )

            $nupkg_name = $Path | Split-Path -LeafBase

            $nuspecs = ($nupkg.Entries | Where-Object { $_.FullName -match "^[^\/\\]*.nuspec" })

            $nuspec = $nuspecs | Where-Object {
                $nuspec_name = $_.FullName | Split-Path -LeafBase
                $out = @(
                    ($nupkg_name -like "$nuspec_name.*"),
                    ($nupkg_name -like "$nuspec_name")
                )
                $out -contains $true
            }

            If ( -not( $nuspec ) ){
                $nuspec = $nuspecs | Select-Object -First 1
                If( $nuspec ){
                    Write-Warning "Improper .nuspec used for $nupkg_name`: $( $nuspec.FullName )"
                } Else {
                    Throw ".nuspec file not found for $nupkg_name`!"
                    return
                }
            }
            
            $stream = $nuspec.Open()
            $reader = New-Object System.IO.StreamReader( $stream )

            [xml]($reader.ReadToEnd())

            $reader.Close()
            $stream.Close()
            $nupkg.Dispose()
        }

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name Load `
        -Value {
            param(
                [string] $Path,
                [bool] $Partial = $false
            )

            # todo: add handling of native/unmanaged assemblies

            try {

                $AddTypeParams = @{
                    # PassThru = $false
                }
    
                if( $Partial ) {
                    $AddTypeParams.AssemblyName = $Path
                } elseif ( Test-Path $Path ) {
                    $AddTypeParams.Path = $Path
                } else {
                    Write-Host "Unable to load $Path"
                    return
                }

                Add-Type @AddTypeParams
                
            } catch { Write-Host "Unable to load $Path" }
        }

    $Exported | Add-Member `
        -MemberType ScriptMethod `
        -Name Init `
        -Value {
            $Loaded = Try {
                [NuGet.Frameworks.FrameworkConstants+FrameworkIdentifiers]
            } Catch {
                $false
            }
            If( -not( $Loaded )){
                $load_order = [System.Collections.ArrayList]::new()
                $load_order.Add( "NuGet.Frameworks" ) | Out-Null

                # Loop init
                $i = 0
                $package_name = ""

                # Caching for performance
                $package_table = @{}

                while( $i -lt $load_order.count ){
                    $package_name = $load_order[$i]
                    If( -not( $package_table.ContainsKey( $package_name ) ) ){
                        $package = Get-Package $package_name -ProviderName NuGet -ErrorAction SilentlyContinue
                        $latest = Try {
                            If( ($global:DIS_AUTOUPDATE_IMPORTS -eq $true ) -or ( $env:DIS_AUTOUPDATE_IMPORTS -eq 1 ) ){
                                $package.Version
                            } Else {
                                $this.GetLatest( $package_name )
                            }
                        } Catch { $package.Version }

                        if( (-not $package) -or ($package.Version -ne $latest) ){
                            Try {
                                Install-Package $package_name `
                                    -ProviderName NuGet `
                                    -RequiredVersion $latest `
                                    -SkipDependencies `
                                    -Force `
                                    -ErrorAction Stop | Out-Null
                            } Catch {        
                                Install-Package $package_name `
                                    -ProviderName NuGet `
                                    -RequiredVersion $latest `
                                    -SkipDependencies `
                                    -Scope CurrentUser `
                                    -Force | Out-Null
                            }

                            $package = Get-Package $package_name -ProviderName NuGet -ErrorAction Stop
                        }

                        $package_table[ $package_name ] = $package.Source.ToString()

                        $dependencies = ($this.ReadNuspec( $package.Source ).package.metadata.dependencies.group | Where-Object { $_.targetframework -eq "netstandard2.0" }).dependency | Where-Object { $_.id }

                        foreach( $dependency in $dependencies ){
                            $load_order.Add( $dependency.id ) | Out-Null
                        }
                    } else {
                        $oldindex = $load_order.IndexOf( $package_name )
                        $load_order.RemoveAt( $oldindex )
                        $load_order.Add( $package_name )
                    }

                    $i += 1
                }

                $this | Add-Member `
                    -MemberType NoteProperty `
                    -Name Dependencies `
                    -Value ($load_order | Select-Object -Unique)

                [array]::Reverse( $this.Dependencies )

                $this.Dependencies | ForEach-Object {
                    $package_source = $package_table[ $_ ]
                    $dll = Resolve-Path "$(Split-Path $package_source -ErrorAction SilentlyContinue)\lib\netstandard2.0\$_.dll" -ErrorAction SilentlyContinue
                    $this.Load( $dll )
                }

                $this | Add-Member `
                    -MemberType NoteProperty `
                    -Name Reducer `
                    -Value ([NuGet.Frameworks.FrameworkReducer]::new())

                $this | Add-Member `
                    -MemberType NoteProperty `
                    -Name Frameworks `
                    -Value @{}
                [NuGet.Frameworks.FrameworkConstants+FrameworkIdentifiers].DeclaredFields | ForEach-Object {
                    $this.Frameworks[$_.Name] = $_.GetValue( $null )
                }

                $this | Add-Member `
                    -MemberType NoteProperty `
                    -Name System `
                    -Value (& {
                        $runtime = [System.Runtime.InteropServices.RuntimeInformation, mscorlib]::FrameworkDescription
                        $version = $runtime -split " " | Select-Object -Last 1
                        $framework_name = ($runtime -split " " | Select-Object -SkipLast 1) -join " "
                    
                        If( $framework_name -eq ".NET Framework" ) {
                            $framework_name = "Net"
                        } else {
                            $framework_name = "NETCoreApp"
                        }
                    
                        "$($this.Frameworks[ $framework_name ]),Version=v$version" -as [NuGet.Frameworks.NuGetFramework]
                    })
                    
                # RuntimeIdentifier Handling
                Try {
                    & "$PSScriptRoot/platforms.ps1" $this | Out-Null
                } Catch { }

                # Native/Unmanaged assemblies
                Try {
                    $this | Add-Member `
                        -MemberType ScriptMethod `
                        -Name LoadNative `
                        -Value (& {
                            Add-Type -MemberDefinition @"
[DllImport("kernel32")]
public static extern IntPtr LoadLibrary(string path);
[DllImport("libdl")]
public static extern IntPtr dlopen(string path, int flags);
"@ -Namespace "_Native" -Name "Loaders"
                            
                            {
                                param( $Path, $CopyTo )
                                If( $CopyTo ){
                                    Write-Verbose "Loading native dll from path '$CopyTo' (copied from '$Path')."
                                    Copy-Item $Path $CopyTo -Force -ErrorAction SilentlyContinue | Out-Null
                                    $Path = "$CopyTo\$($Path | Split-Path -Leaf)"
                                } Else {
                                    Write-Verbose "Loading native dll from path '$Path'."
                                }
                                $lib_handle = [System.IntPtr]::Zero

                                If( [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) ){
                                    $lib_handle = [_Native.Loaders]::LoadLibrary( $Path )
                                } else {
                                    $lib_handle = [_Native.Loaders]::dlopen( $Path, 0 )
                                }

                                If( $lib_handle -eq [System.IntPtr]::Zero ){
                                    Throw "Unable to load $Path"
                                }

                                # BUG: Leaky handle
                                $lib_handle
                            }
                        })
                    
                    $this | Add-Member `
                        -MemberType ScriptMethod `
                        -Name TestNative `
                        -Value {
                            param( $Path )
                            try {
                                [Reflection.AssemblyName]::GetAssemblyName($Path) | Out-Null
                                return $false
                            } catch {
                                return $true
                            }
                        }
                        
                } Catch {}
            }
            $this
        }
    $Exported.Init()
} # | % { $global:Test = $_ }