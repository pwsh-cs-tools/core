$internals = @{}
$threads = [hashtable]::Synchronized( @{} )
Try { Add-Type -AssemblyName "WindowsBase" } Finally {}

function Set-DispatcherFactory {
    [CmdletBinding()]
    param(
        [type] $ReturnType = (& {
            Try {
                [System.Windows.Threading.Dispatcher]
            } Catch {
                Try {
                    [Avalonia.Threading.Dispatcher]
                } Catch {}
            }
        }),
        [scriptblock] $Factory = (&{
            switch ($ReturnType.ToString()) {
                "System.Windows.Threading.Dispatcher" {            
                    {
                        # For WPF, we don't need to create an App as the encapsulating PowerShell runspace is already an App
                        [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                        [System.Windows.Threading.Dispatcher]::Run() | Out-Null
                    }
                }
                "Avalonia.Threading.Dispatcher" {
                    {
                        $App = @{}
                        & {
                            $builder = [Avalonia.AppBuilder]::Configure[Avalonia.Application]()
                            $builder = [Avalonia.AppBuilderDesktopExtensions]::UsePlatformDetect( $builder )
                    
                            $App.Lifetime = [Avalonia.Controls.ApplicationLifetimes.ClassicDesktopStyleApplicationLifetime]::new()
                            $App.Lifetime.ShutdownMode = [Avalonia.Controls.ShutdownMode]::OnExplicitShutdown
                        
                            $builder = $builder.SetupWithLifetime( $App.Lifetime )
                        
                            # Return early
                            $App.Instance = $builder.Instance
                        }
                    
                        # Return the UI thread dispatcher
                        [Avalonia.Threading.Dispatcher]::UIThread
                        $App.TokenSource = [System.Threading.CancellationTokenSource]::new()
                    
                        [Avalonia.Controls.DesktopApplicationExtensions]::Run( $App.Instance, $App.TokenSource.Token ) | Out-Null
            
                    }
                }
                Default {}
            }
        })
    )
    Process {
        If( $null -eq $ReturnType ){
            Write-Error "Neither WPF or Avalonia appear to be properly loaded. Please provide a return type!"
        } Else {
            If( $null -eq $Factory ){ 
                Write-Error "ReturnType is not a WPF or Avalonia Dispatcher. Please provide a factory scriptblock!"
            } Else {
                $internals.dispatcher_class = $ReturnType
                $internals.factory_script = $Factory
            }
        }
    }
}

Set-DispatcherFactory

function New-DispatchThread{
    param(
        [string] $ThreadName = "Thread",
        [hashtable] $SessionProxies = @{},
        [scriptblock] $Factory = $internals.factory_script
    )

    If( !$ThreadName.Length ){ $ThreadName = "Thread" }
    
    # Thread name generator
    $ThreadName = & {

        $i = $threads.Keys |
            Where-Object { $_ -match "^$ThreadName-\d+$" } |
            Select-String -Pattern "\d+" |
            ForEach-Object { $_.Matches.Value } |
            Sort-Object -Descending |
            Select-Object -First 1

        $i = [int]$i
        $suffix = If( $i ){ "-$( $i+1 )" } Else {
            If( $threads.Keys -contains $ThreadName ){ "-2" } Else { "" }
        }
        
        "$ThreadName" + "$suffix"
    }

    $SessionProxies = [hashtable]::Synchronized( $SessionProxies )
    # May want to rewrite this as a (Get-Module).Invoke() call
    $SessionProxies.Threads = $threads
    $SessionProxies.ThreadName = $ThreadName
    $SessionProxies.Factory = $Factory
    $SessionProxies.DispatcherClass = $internals.dispatcher_class

    $runspace = [runspacefactory]::CreateRunspace( $Host )
    $runspace.ApartmentState = "STA"
    $runspace.Name = $ThreadName
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
            ThreadName = $ThreadName
            Thread = $powershell
            Completed = $false
        }
        $threads[ $ThreadName ] = $thread_controller
        
        # Pre-emptively return the thread controller
        $thread_controller
        $InitTask = $powershell.BeginInvoke()
        # Wait for the thread to initialize
        While( !$InitTask.IsCompleted -and ![bool]( $thread_controller.psobject.Properties.Name -match "Dispatcher" )){
            Start-Sleep -Milliseconds 100
        }

        $thread_controller | Add-Member -MemberType ScriptMethod -Name "Dispose" -Value {
            $thread_controller = $threads[ $this.ThreadName ]
        
            # $thread_controller.Sessions.Values.Dispose()
        
            If( $thread_controller.Dispatcher ){
                If( $thread_controller.Dispatcher.GetType().ToString() -eq "System.Windows.Threading.Dispatcher" ){
                    $thread_controller.Dispatcher.InvokeShutdown()
                } Else {
                    $thread_controller.Invoke({ $Lifetime.Shutdown() }) # Invoke Avalonia Shutdown
                }
            }
            
            While( !$thread_controller.Completed ){
                Start-Sleep -Milliseconds 100
            }
        
            $thread_controller.Thread.Runspace.Close()
            $thread_controller.Thread.Runspace.Dispose()
            $thread_controller.Thread.Dispose()
        
            $thread_controller.PSObject.Properties.Remove( "Dispatcher" )
            $thread_controller.PSObject.Properties.Remove( "Thread" )
            $thread_controller.PSObject.Properties.Remove( "Completed" )
        
            $threads.Remove( $this.ThreadName )
        } -Force
    
        If( $thread_controller.Dispatcher ){
            $thread_controller | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                param(
                    [parameter(Mandatory = $true)]
                    [scriptblock] $Action,
                    [bool] $Sync = $false
                )
            
                $Action = [scriptblock]::Create( $Action.ToString() )
            
                $output = New-Object PSObject
                $output | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { "" } -Force

                $output | Add-Member -MemberType NoteProperty -Name "Dispatcher" -Value $null -Force

                If( $Sync ){
                    # May need to replace with GetMethod("InvokeAsync").MakeGenericMethod([Object[]])
                    $Result = ($this.Dispatcher.GetType().GetMethods() |
                        Where-Object {
                            $Params = $null
                            If( $_.IsGenericMethod -and ( $_.Name -eq "InvokeAsync" )){
                                $Params = $_.GetParameters()
                                If( $Params.Count -eq 1 ){
                                    -not( $Params[0].ParameterType.ToString() -like "*.Task*" )
                                } Else {
                                    $false
                                }
                            } Else {
                                $false
                            }
                        }).MakeGenericMethod([Object[]]).Invoke( $this.Dispatcher, @([System.Func[Object[]]]$Action) )
                    # $Result = $this.Dispatcher.InvokeAsync[Object[]]( $Action )
                    If ( $Result.Dispatcher.Task ){ # WPF InvokeAsync returns a DispatcherOperation object
                        $output.Dispatcher = $Result.Dispatcher
                        $Result = $Result.Task.GetAwaiter().GetResult()
                    } Else { # Avalonia InvokeAsync returns a Task object
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
                    $Result = ($this.Dispatcher.GetType().GetMethods() |
                        Where-Object {
                            $Params = $null
                            If( $_.IsGenericMethod -and ( $_.Name -eq "InvokeAsync" )){
                                $Params = $_.GetParameters()
                                If( $Params.Count -eq 1 ){
                                    -not( $Params[0].ParameterType.ToString() -like "*.Task*" )
                                } Else {
                                    $false
                                }
                            } Else {
                                $false
                            }
                        }).MakeGenericMethod([Object[]]).Invoke( $this.Dispatcher, @([System.Func[Object[]]]$Action) )
                    If ( $Result.Dispatcher ){ # WPF InvokeAsync returns a DispatcherOperation object
                        $output.Dispatcher = $Result.Dispatcher
                        $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $Result.Task
                    } Else { # Avalonia InvokeAsync returns a Task object
                        $output.Dispatcher = $this.Dispatcher
                        $output | Add-Member -MemberType NoteProperty -Name "Result" -Value $Result
                    }
                    $output | Add-Member -MemberType ScriptMethod -Name "ToString" -Value { $this.Result.ToString() } -Force
                }
                
                $output | Add-Member -MemberType NoteProperty -Name "ThreadName" -Value $this.ThreadName -Force
                $output | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                    param(
                        [parameter(Mandatory = $true)]
                        [scriptblock] $Action,
                        [bool] $Sync = $false
                    )
                
                    $Threads[ $this.ThreadName ].Invoke( $Action, $Sync )
                } -Force

                $output
            } -Force
        }
        # At this point, the thread controller has already been returned
    }
}

# Export-ModuleMember -Function New-DispatchThread -Cmdlet New-DispatchThread
Export-ModuleMember `
    -Function @(
        "New-DispatchThread",
        "Set-DispatcherFactory"
    ) -Cmdlet @(
        "New-DispatchThread",
        "Set-DispatcherFactory"
    )