$Sessions = [hashtable]::Synchronized( @{} )

$ThreadController | Add-Member -MemberType ScriptMethod -Name "Session" -Value {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $ScriptBlock,
        [bool] $Sync = $false
    )

    switch ($ScriptBlock.GetType().Name) {
        "ScriptBlock" {}
        "String" {
            Try{
                [scriptblock]::Create( $ScriptBlock ) | Out-Null
            } Catch {
                throw [System.ArgumentException]::new( "ScriptBlock must be a ScriptBlock or Valid ScriptBlock String!", "ScriptBlock" )
            }
        }
        default {
            throw [System.ArgumentException]::new( "ScriptBlock must be a ScriptBlock or String!", "ScriptBlock" )
        }
    }

    $Action = @(
        "`$session_name = `"$Name`"",
        "`$script_block = { $ScriptBlock }",
        {
            If( $Sessions.ContainsKey( $session_name ) ){
                $Session = $Sessions[ $session_name ]
            } Else {

                $Session = New-Object -TypeName PSObject -Property @{
                    Name = $session_name
                    Module = New-Module -ScriptBlock ([scriptblock]::Create(@(
                        "`$SessionName = `"$session_name`"",
                        { $SessionTable = @{} }.ToString()
                        "Export-ModuleMember"
                    ) -join "`n")) -Name $session_name
                }

                $Session | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                    param(
                        [Parameter(Mandatory = $true)]
                        $ScriptBlock
                    )

                    If( $ScriptBlock.GetType().Name -eq "ScriptBlock" ){
                        $ScriptBlock = [scriptblock]::Create( $ScriptBlock.ToString() )
                    } Elseif( $ScriptBlock.GetType().Name -eq "String" ){
                        Try {
                            $ScriptBlock = [scriptblock]::Create( $ScriptBlock )
                        } Catch {
                            throw [System.ArgumentException]::new( "Session.Invoke() ScriptBlock must be a ScriptBlock or Valid ScriptBlock String!", "Action" )
                        }
                    } Else {
                        throw [System.ArgumentException]::new( "Session.Invoke() ScriptBlock must be a ScriptBlock or Valid ScriptBlock String!", "Action" )
                    }

                    $this.Module.Invoke( $ScriptBlock )
                }

                $Session | Add-Member -MemberType NoteProperty -Name "ThreadController" -Value $ThreadController -Force
                $Session | Add-Member -MemberType ScriptProperty -Name "SessionTable" -Value {
                    $this.ThreadController.Dispatcher.VerifyAccess()
                    $this.Invoke({ $SessionTable })
                }

                $Sessions.Add( $session_name, $Session ) | Out-Null
            }

            $session_name = $null

            $Session.Invoke( $script_block, $Sync )
        }.ToString()
    ) -join "`n"

    $output = $this.Invoke( $Action, $Sync )
    
    $output | Add-Member `
        -MemberType NoteProperty `
        -Name "Session" `
        -Value $Name `
        -Force
    
    $output | Add-Member `
        -MemberType ScriptMethod `
        -Name "Invoke" `
        -Value {
            param(
                [parameter(Mandatory = $true)]
                $ScriptBlock,
                [bool] $Sync = $false
            )

            switch ($ScriptBlock.GetType().Name) {
                "ScriptBlock" {}
                "String" {}
                default {
                    throw [System.ArgumentException]::new( "ScriptBlock must be a ScriptBlock or String!", "ScriptBlock" )
                }
            }
        
            Try {
                $this.ThreadController.Session( $this.Session, $Action, $Sync )
            } Catch {
                if( $_.Exception.Message -like "*null-valued expression*" ){
                    throw [System.Exception]::new( "Thread controller does not exist or was disposed!", $_.Exception )
                } Else {
                    throw $_
                }
            }
        } -Force

    $output
}