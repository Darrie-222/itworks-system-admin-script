#requires -Version 5.1

<#
    ExecuteOnServer.psm1

    Remote execution helper for the Mick and Macks Pies server build.

    Author:  Cooper Lane
    Company: ITWorks
    Version: 1.1
#>

Set-StrictMode -Version Latest


function New-ServerSession {
<#
    .SYNOPSIS
    Opens a PowerShell remoting session to a target server.

    .PARAMETER ComputerName
    Name or IP address of the target server.

    .PARAMETER Credential
    Credentials used to authenticate. If omitted the user is prompted, unless
    -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Authenticate as the account already signed in, rather than prompting. Only
    useful once both machines are members of the same domain, where Kerberos
    can carry the signed-in identity across.

    .OUTPUTS
    System.Management.Automation.Runspaces.PSSession
#>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Position = 1)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser
    )

    begin {
        Write-Verbose "Preparing a remote session to '$ComputerName'."
    }

    process {
        if (-not $UseCurrentUser -and -not $PSBoundParameters.ContainsKey('Credential')) {
            $Credential = Get-Credential -Message "Enter administrator credentials for $ComputerName"
        }

        if (-not $UseCurrentUser -and $null -eq $Credential) {
            throw "No credentials were supplied for '$ComputerName'. Cannot continue."
        }

        try {
            $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        }
        catch {
            throw ("WinRM did not answer on '$ComputerName'. Check the server is powered on, " +
                   "that PowerShell remoting is enabled, and that this client trusts it. " +
                   "Underlying error: $($_.Exception.Message)")
        }

        $sessionParameters = @{
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }

        if (-not $UseCurrentUser) {
            $sessionParameters['Credential'] = $Credential
        }

        try {
            $newSession = New-PSSession @sessionParameters
        }
        catch {
            throw "Could not open a session to '$ComputerName'. $($_.Exception.Message)"
        }

        Write-Verbose "Session $($newSession.Id) opened to '$ComputerName'."
        return $newSession
    }
}


function Export-FunctionToSession {
<#
    .SYNOPSIS
    Copies the definition of a locally loaded function into a remote session.

    .PARAMETER Session
    An open PSSession to push the function into.

    .PARAMETER Name
    One or more names of functions currently loaded on the client.
#>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    process {
        foreach ($functionName in $Name) {
            try {
                $localFunction = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
            }
            catch {
                throw "Function '$functionName' is not loaded on this client, so it cannot be exported."
            }

            $definition = "function $($localFunction.Name) {`n$($localFunction.Definition)`n}"

            Invoke-Command -Session $Session -ScriptBlock ([scriptblock]::Create($definition))
            Write-Verbose "Exported '$functionName' into session $($Session.Id)."
        }
    }
}


function Invoke-OnServer {
<#
    .SYNOPSIS
    Runs a block of code on a target server over PowerShell remoting.

    .PARAMETER ComputerName
    Name or IP address of the target server. Ignored when -Session is supplied.

    .PARAMETER ScriptBlock
    The code to execute on the server.

    .PARAMETER ArgumentList
    Values passed positionally into the script block as $args.

    .PARAMETER Credential
    Credentials used when this function has to create its own session.

    .PARAMETER UseCurrentUser
    Authenticate as the account already signed in instead of prompting. Applies
    only when this function creates its own session.

    .PARAMETER IncludeFunction
    Names of local functions to recreate inside the session before running.

    .PARAMETER Session
    An already open PSSession to reuse instead of creating a new one.

    .OUTPUTS
    System.Object
#>
    [CmdletBinding(DefaultParameterSetName = 'ByComputerName')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ByComputerName')]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory = $true, ParameterSetName = 'BySession')]
        [ValidateNotNull()]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList = @(),

        [Parameter(ParameterSetName = 'ByComputerName')]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(ParameterSetName = 'ByComputerName')]
        [switch]$UseCurrentUser,

        [Parameter()]
        [string[]]$IncludeFunction = @()
    )

    begin {
        $sessionWasCreatedHere = $false

        if ($PSCmdlet.ParameterSetName -eq 'BySession') {
            $activeSession = $Session
        }
        else {
            $connectionParameters = @{ ComputerName = $ComputerName }

            if ($UseCurrentUser) {
                $connectionParameters['UseCurrentUser'] = $true
            }
            elseif ($PSBoundParameters.ContainsKey('Credential')) {
                $connectionParameters['Credential'] = $Credential
            }

            $activeSession = New-ServerSession @connectionParameters
            $sessionWasCreatedHere = $true
        }
    }

    process {
        if ($activeSession.State -ne 'Opened') {
            throw ("The session to '$($activeSession.ComputerName)' is in state " +
                   "'$($activeSession.State)' and cannot be used.")
        }

        if ($IncludeFunction.Count -gt 0) {
            Export-FunctionToSession -Session $activeSession -Name $IncludeFunction
        }

        $invokeParameters = @{
            Session     = $activeSession
            ScriptBlock = $ScriptBlock
            ErrorAction = 'Stop'
        }

        if ($ArgumentList.Count -gt 0) {
            $invokeParameters['ArgumentList'] = $ArgumentList
        }

        try {
            Invoke-Command @invokeParameters
        }
        catch {
            Write-Error ("Remote execution on '$($activeSession.ComputerName)' failed: " +
                         "$($_.Exception.Message)")
        }
    }

    end {
        if ($sessionWasCreatedHere -and $null -ne $activeSession) {
            Write-Verbose "Closing session $($activeSession.Id)."
            Remove-PSSession -Session $activeSession -ErrorAction SilentlyContinue
        }
    }
}


function Remove-ServerSession {
<#
    .SYNOPSIS
    Closes a remoting session opened by New-ServerSession.

    .PARAMETER Session
    The session to close.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    process {
        if ($PSCmdlet.ShouldProcess($Session.ComputerName, 'Close remote session')) {
            Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
            Write-Verbose "Session to '$($Session.ComputerName)' closed."
        }
    }
}


Export-ModuleMember -Function 'New-ServerSession',
                              'Export-FunctionToSession',
                              'Invoke-OnServer',
                              'Remove-ServerSession'
