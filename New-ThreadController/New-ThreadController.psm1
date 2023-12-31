$internals = @{}
$threads = [hashtable]::Synchronized( @{} )
Try {
    Add-Type `
    -TypeDefinition (Get-Content `
        -Path "$PSScriptRoot\ThreadExtensions.cs" `
        -Raw) | Out-Null
} Catch {
    throw [System.Exception]::new( "Failed to load ThreadExtensions.cs!", $_.Exception )
}
Try { Add-Type -AssemblyName "WindowsBase" } Catch {}

<#
    .Synopsis
        A simplistic cmdlet for getting all wrapped threads generated by this module.

    .Description
        This cmdlet is used to get all wrapped threads generated by this module.

    .Example
        (Get-Threads).47 # Gets the thread controller for the thread with the ManagedThreadId of 47
#>
function Get-Threads {
    [CmdletBinding()]
    param()

    Process {
        $threads
    }
}

# Internal function for getting the InvokeAsync method
function Get-Invoker{
    param(
        [Parameter(Mandatory = $true)]
        [type] $Type
    )
    $Type.GetMethods() |
        Where-Object {
            $Params = $null
            If( $_.IsGenericMethod -and ( $_.Name -eq "InvokeAsync" )){
                $Params = $_.GetParameters()
                If( $Params.Count -eq 1 ){
                    -not( $Params[0].ParameterType.ToString() -like "*.Task*" ) -and `
                    $Params[0].ParameterType.ToString() -like "*.Func*"
                } Else {
                    $false
                }
            } Else {
                $false
            }
        }
}

function Update-DispatcherFactory {
    [CmdletBinding()]
    param(
        [type] $ReturnType = (& {
            Try {
                [System.Windows.Threading.Dispatcher]
            } Catch {
                Try {
                    [ThreadExtensions.Dispatcher]
                } Catch {
                    # a default factory for avalonia is no longer provided, but code to support using one is still maintained

                    # [Avalonia.Threading.Dispatcher] 
                }
            }
        }),
        [scriptblock] $Factory = (&{
            switch ($ReturnType.ToString()) {
                "System.Windows.Threading.Dispatcher" {            
                    {
                        # For WPF, we don't need to create an App as the encapsulating PowerShell runspace is already an App
                        $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

                        <#
                        # WPF's dispatcher is not pausible, so using a token like we do for ThreadExtensions is not possible
                        # - the following script instead shuts down the dispatcher when the token is cancelled

                        $ThreadController | Add-Member `
                            -MemberType NoteProperty `
                            -Name "CancellationTokenSource" `
                            -Value ([System.Threading.CancellationTokenSource]::new())

                        $ThreadController.CancellationTokenSource.Token.Register(([scriptblock]::Create(@(
                            "`$_name = $ThreadName",
                            {
                                $ThreadController = $Threads[ $_name ]
                                $ThreadController.Dispose()
                            }.ToString()
                        ) -join "`n")))
                        #>

                        $Dispatcher
                        [System.Windows.Threading.Dispatcher]::Run() | Out-Null
                    }
                }
                "ThreadExtensions.Dispatcher" {
                    {
                        $Dispatcher = [ThreadExtensions.Dispatcher]::new()
                        
                        $ThreadController | Add-Member `
                            -MemberType NoteProperty `
                            -Name "CancellationTokenSource" `
                            -Value ([System.Threading.CancellationTokenSource]::new())

                        $Dispatcher
                        $Dispatcher.Run( $ThreadController.CancellationTokenSource.Token )
                    }
                }
                "Avalonia.Threading.Dispatcher" {
                    Write-Warning "Support for Avalonia's dispatcher has been dropped! Please provide your own dispatcher factory scriptblock!"
                }
            }
        })
    )
    Process {
        If( ($null -eq $ReturnType) -or -not (Get-Invoker $ReturnType) ){
            Write-Error "ReturnType is not a supported Dispatcher. Please provide a dispatcher with an InvokeAsync<TReturn>( Func<TReturn> ) method!"
        } Else {
            If( $null -eq $Factory ){ 
                Write-Error "ReturnType does not have a default factory! Please provide a factory scriptblock!"
            } Else {
                $internals.dispatcher_class = $ReturnType
                $internals.factory_script = $Factory
            }
        }
    }
}

Update-DispatcherFactory

function New-ThreadController{
    param(
        [string] $Name,
        [hashtable] $SessionProxies = @{},
        [scriptblock] $Factory = $internals.factory_script
    )

    $guid = $null
    if(
        (-not $Name) -or `
        ($Name.Trim() -eq "") -or `
        ($Name -eq "Anonymous")
    ){
        $guid = ((New-Guid).ToString().ToUpper() -replace "-", "")
        If( $Name -eq "Anonymous" ){
            $Name = "Anonymous-$guid"
            $guid = $null
        } Else {
            $Name = "BadThread-$guid"
        }
    }

    if( $threads[ $Name ] ){
        throw [System.ArgumentException]::new( "Named thread $Name already exists!", "Name" )
    }

    $SessionProxies = [hashtable]::Synchronized( $SessionProxies )
    # May want to rewrite this as a (Get-Module).Invoke() call
    $SessionProxies.Threads = $threads
    If( $guid ){
        $SessionProxies.guid = $guid
    }
    $SessionProxies.ThreadName = $Name
    $SessionProxies.Factory = $Factory
    $SessionProxies.DispatcherClass = $internals.dispatcher_class

    $runspace = [runspacefactory]::CreateRunspace( $Host )
    $runspace.ApartmentState = "STA"
    $runspace.Name = $Name
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open() | Out-Null

    foreach( $proxy in $SessionProxies.GetEnumerator() ){
        $runspace.SessionStateProxy.PSVariable.Set( $proxy.Name, $proxy.Value )
    }

    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $powershell.AddScript([scriptblock]::Create({
        # May want to rewrite this as a (Get-Module).Invoke() call
        $ThreadController = $Threads[ $ThreadName ]
        $ThreadController | Add-Member `
            -MemberType NoteProperty `
            -Name "Id" `
            -Value ([System.Threading.Thread]::CurrentThread.ManagedThreadId)

        If( $guid ){
            $ThreadName = "ManagedThreadId-$( $ThreadController.Id.ToString() )"
            $ThreadController.Name = $ThreadName
            $ThreadController.PowerShell.Runspace.Name = $ThreadName
            $Threads[ $ThreadName ] = $ThreadController
            $Threads.Remove( "BadThread-$guid" )
            $guid = $null
        }

        Invoke-Command -ScriptBlock ([scriptblock]::Create( "$(
            $Factory.ToString()
            $Factory = $null
        )")) | ForEach-Object {
            If( $_.GetType() -eq $DispatcherClass ){
                Add-Member -InputObject $ThreadController -MemberType NoteProperty -Name "Dispatcher" -Value $_ -Force
            } Else {
                Write-Warning "Dispatcher type incorrect!`nExpected: $DispatcherClass`nGot: $($_.GetType())"
            }
            $DispatcherClass = $null
        }
        $DispatcherClass = $null

        $ThreadController.Completed = $true
    }.ToString())) | Out-Null
    
    & {
    
        $thread_controller = New-Object PSObject -Property @{
            Name = $Name
            PowerShell = $powershell
            Completed = $false
        }
        $threads[ $Name ] = $thread_controller
        
        # Pre-emptively return the thread controller
        $thread_controller
        $InitTask = $powershell.BeginInvoke()
        # Wait for the thread to initialize
        While( !$InitTask.IsCompleted -and ![bool]( $thread_controller.psobject.Properties.Name -match "Dispatcher" )){
            Start-Sleep -Milliseconds 100
        }

        $thread_controller | Add-Member -MemberType ScriptMethod -Name "Dispose" -Value {
            $thread_controller = $threads[ $this.Name ]
        
            # $thread_controller.Sessions.Values.Dispose()
        
            If( $thread_controller.CancellationTokenSource ){
                $thread_controller.CancellationTokenSource.Cancel()
                $thread_controller.CancellationTokenSource.Dispose()
            }

            If( $thread_controller.Dispatcher ){
                If( $thread_controller.Dispatcher.InvokeShutdown ){
                    $thread_controller.Dispatcher.InvokeShutdown()
                }
                If( $thread_controller.Dispatcher.Dispose ){
                    $thread_controller.Dispatcher.Dispose()
                }
            }
            
            While( !$thread_controller.Completed ){
                Start-Sleep -Milliseconds 100
            }
        
            $thread_controller.PowerShell.Runspace.Close()
            $thread_controller.PowerShell.Runspace.Dispose()
            $thread_controller.PowerShell.Dispose()
        
            $thread_controller.PSObject.Properties.Remove( "Dispatcher" )
            $thread_controller.PSObject.Properties.Remove( "Thread" )
        
            $threads.Remove( $this.Name )
        } -Force
    
        If( $thread_controller.Dispatcher ){
            $thread_controller | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                param(
                    [parameter(Mandatory = $true)]
                    $Action,
                    [bool] $Sync = $false
                )

                if( $Action.GetType().Name -eq "ScriptBlock" ){
                    $Action = [scriptblock]::Create( $Action.ToString() )
                } Elseif( $Action.GetType().Name -eq "String" ){
                    Try {
                        $Action = [scriptblock]::Create( $Action )
                    } Catch {
                        throw [System.ArgumentException]::new( "Action must be a ScriptBlock or Valid ScriptBlock String!", "Action" )
                    }
                } Else {
                    throw [System.ArgumentException]::new( "Action must be a ScriptBlock or Valid ScriptBlock String!", "Action" )
                }
            
                $output = New-Object PSObject
                $output | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { "" } -Force

                $output | Add-Member -MemberType NoteProperty -Name "Dispatcher" -Value $null -Force

                $Result = Try {
                    (Get-Invoker $this.Dispatcher.GetType()).
                        MakeGenericMethod([Object[]]).
                        Invoke(
                            $this.Dispatcher,
                            @( [System.Func[Object[]]]$Action )
                        )
                } Catch {
                    throw "Problem with Get-Invoker call: $_"
                }

                If( $null -eq $Result ){
                    throw "Problem with Get-Invoker call: Result is null!"
                }

                Try {
                    If( $Sync ){
                        # $Result = $this.Dispatcher.InvokeAsync[Object[]]( $Action )
                        If ( $Result.GetType().Name -eq "DispatcherOperation" ){ # DispatcherOperation object
                            $output.Dispatcher = $Result.Dispatcher
                            If( $Result.Task ){ # WPF DispatcherOperation object
                                $Result = $Result.Task.GetAwaiter().GetResult()
                            } Else { # Avalonia DispatcherOperation object
                                $Result = $Result.GetTask().GetAwaiter().GetResult()
                            }
                        } Else { # Task object
                            $output.Dispatcher = $this.Dispatcher
                            $Result = $Result.GetAwaiter().GetResult()
                        }
                        If( $null -ne $Result ){
                            $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $null -Force
                            If( $Result.Count -eq 1 ){
                                $output.Result = $Result[0]
                            } Else {
                                $output.Result = $Result
                            }
                            $output | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { $this.Result.ToString() } -Force
                        }
                    } Else {
                        # $Result = $this.Dispatcher.InvokeAsync( $Action )
                        If ( $Result.GetType().Name -like "*DispatcherOperation*" ){ # DispatcherOperation object
                            $output.Dispatcher = $Result.Dispatcher
                            If( $Result.Task ){ # WPF DispatcherOperation object
                                $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $Result.Task
                            } Else { # Avalonia DispatcherOperation object
                                $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $Result.GetTask()
                            }
                        } Else { # Task object
                            $output.Dispatcher = $this.Dispatcher
                            $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $Result
                        }
                        $output | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { $this.Result.ToString() } -Force
                    }
                } Catch {
                    throw "Problem with parsing output: $_"
                }
                
                $output | Add-Member -MemberType NoteProperty -Name "Name" -Value $this.Name -Force
                $output | Add-Member -MemberType NoteProperty -Name "Id" -Value $this.Id -Force
                $output | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                    param(
                        [parameter(Mandatory = $true)]
                        $Action,
                        [bool] $Sync = $false
                    )

                    switch ($Action.GetType().Name) {
                        "ScriptBlock" {}
                        "String" {}
                        default {
                            throw [System.ArgumentException]::new( "Action must be a ScriptBlock or String!", "Action" )
                        }
                    }
                
                    Try {
                        $Threads[ $this.Name ].Invoke( $Action, $Sync )
                    } Catch {
                        if( $_.Exception.Message -like "*null-valued expression*" ){
                            throw [System.Exception]::new( "Thread controller does not exist or was disposed!", $_.Exception )
                        } Else {
                            throw $_
                        }
                    }
                } -Force

                $output
            } -Force
        }
        # At this point, the thread controller has already been returned
    }
}

function Async {
    param(
        [parameter(Mandatory = $true)]
        $Action,
        $Thread,
        [switch] $Sync
    )

    $dispose = If( $null -eq $Thread ){
        $Thread = "Anonymous"
        $true
    } Else {
        $false
    }

    If( $Thread.GetType() -eq [string] ){
        if( $Threads[ $Thread ] ){
            $Thread = $threads[ $Thread ]
        } Else {
            $Thread = New-ThreadController -Name $Thread
        }
    } Else {
        $Thread = $threads[ $Thread.Name ]
    }
    
    if( $null -eq $Thread ){
        throw [System.ArgumentException]::new( "Thread must be a new or existing Thread Name or an Existing ThreadController!", "Thread" )
    }

    switch ($Action.GetType().Name) {
        "ScriptBlock" {}
        "String" {}
        default {
            throw [System.ArgumentException]::new( "Action must be a ScriptBlock or String!", "Action" )
        }
    }

    Try {
        $Thread.Invoke( $Action, $Sync )
    } Catch {
        if( $_.Exception.Message -like "*null-valued expression*" ){
            throw [System.Exception]::new( "Thread controller does not exist or was disposed!", $_.Exception )
        } Else {
            throw $_
        }
    }
    
    If( $dispose ){
        $Thread.Dispose()
    }
}

Export-ModuleMember -Function @(
    "New-ThreadController",
    "Update-DispatcherFactory",
    "Get-Threads",
    "Async"
)