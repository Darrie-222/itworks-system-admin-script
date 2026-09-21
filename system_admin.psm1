#requires -Version 5.1

<#
    system_admin.psm1

    Windows Server 2022 administration module for Mick and Macks Pies.

    Author:  Cooper Lane
    Company: ITWorks
    Version: 1.5
#>

Set-StrictMode -Version Latest

# Load the remoting helper that lives alongside this module.
$executeOnServerPath = Join-Path -Path $PSScriptRoot -ChildPath 'ExecuteOnServer.psm1'

if (-not (Test-Path -Path $executeOnServerPath)) {
    throw ("ExecuteOnServer.psm1 was not found in '$PSScriptRoot'. Both module files must " +
           "sit in the same folder.")
}

# Imported globally so that the helper functions are available at the prompt as
# well as inside this module. Without -Global they would resolve for the
# functions below but not for anyone typing Invoke-OnServer directly.
Import-Module -Name $executeOnServerPath -Force -Global -ErrorAction Stop


# Default location of the activity log on the target server.
$script:DefaultLogPath = 'C:\myLogs\logs.txt'


function Write-LogEntry {
<#
    .SYNOPSIS
    Writes a timestamped entry to the activity log.

    .PARAMETER Message
    Description of the task being recorded.

    .PARAMETER LogPath
    Full path of the log file. Defaults to C:\myLogs\logs.txt.

    .EXAMPLE
    Write-LogEntry -Message 'Checked if Domain Controller exists'

    .OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = 'C:\myLogs\logs.txt'
    )

    process {
        $logFolder = Split-Path -Path $LogPath -Parent

        if (-not (Test-Path -Path $logFolder)) {
            $null = New-Item -Path $logFolder -ItemType Directory -Force
        }

        $timeStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logLine = '{0} - {1}' -f $timeStamp, $Message

        Add-Content -Path $LogPath -Value $logLine -Encoding UTF8

        Write-Verbose $logLine
        return $logLine
    }
}


function Test-ServerConnection {
<#
    .SYNOPSIS
    Confirms the client can reach the server, run code on it, and write to its log.

    .DESCRIPTION
    Runs a short block of code on the target server which records an entry in the
    activity log and reports the server name, operating system, and the line that
    was just written. Use this before any other task, and whenever something is
    not behaving as expected.

    .PARAMETER ComputerName
    Name or IP address of the target server.

    .PARAMETER Credential
    Account used to connect. The user is prompted if this is omitted.

    .PARAMETER LogPath
    Full path of the activity log on the server.

    .EXAMPLE
    Test-ServerConnection -ComputerName 10.1.1.10

    .EXAMPLE
    Test-ServerConnection -ComputerName 10.1.1.10 -Verbose

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Position = 1)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        Write-Verbose "Testing the connection to '$ComputerName'."

        $remoteWork = {
            param($logFilePath)

            Write-LogEntry -Message 'Test function executed successfully' -LogPath $logFilePath |
                Out-Null

            [pscustomobject]@{
                ServerName      = $env:COMPUTERNAME
                OperatingSystem = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
                ServerTime      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                LogPath         = $logFilePath
                LastLogEntry    = Get-Content -Path $logFilePath -Tail 1
            }
        }
    }

    process {
        $invokeParameters = @{
            ComputerName    = $ComputerName
            ScriptBlock     = $remoteWork
            ArgumentList    = @($LogPath)
            IncludeFunction = @('Write-LogEntry')
            ErrorAction     = 'Stop'
        }

        if ($PSBoundParameters.ContainsKey('Credential')) {
            $invokeParameters['Credential'] = $Credential
        }

        try {
            $testResult = Invoke-OnServer @invokeParameters
        }
        catch {
            throw "Connection test against '$ComputerName' failed. $($_.Exception.Message)"
        }

        if ($null -eq $testResult) {
            throw "Connection test against '$ComputerName' returned no result."
        }

        Write-Verbose "Server '$($testResult.ServerName)' answered at $($testResult.ServerTime)."
        return $testResult
    }
}


function New-DomainController {
<#
    .SYNOPSIS
    Promotes a Windows Server 2022 machine to a domain controller.

    .PARAMETER ComputerName
    Name or IP address of the server to promote.

    .PARAMETER DomainName
    Fully qualified name of the domain to create.

    .PARAMETER NetbiosName
    Short NetBIOS name for the domain. Maximum 15 characters.

    .PARAMETER Credential
    Local administrator account on the target server. Prompted for if omitted.

    .PARAMETER SafeModePassword
    Directory Services Restore Mode password. Prompted for if omitted.

    .PARAMETER NoRestart
    Complete the promotion but leave the server running. The promotion is not
    finished until the server is restarted manually.

    .PARAMETER LogPath
    Full path of the activity log on the server.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Position = 1)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}$')]
        [string]$DomainName = 'CLmicksandmacks.local',

        [Parameter()]
        [ValidateLength(1, 15)]
        [string]$NetbiosName = 'CLMICKSANDMACKS',

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [System.Security.SecureString]$SafeModePassword,

        [Parameter()]
        [switch]$NoRestart,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('Credential')) {
            $Credential = Get-Credential -Message "Administrator account on $ComputerName"
        }

        if ($null -eq $Credential) {
            throw 'Administrator credentials are required to promote a domain controller.'
        }

        if (-not $PSBoundParameters.ContainsKey('SafeModePassword')) {
            $SafeModePassword = Read-Host -AsSecureString `
                -Prompt 'Directory Services Restore Mode (DSRM) password'
        }

        if ($null -eq $SafeModePassword -or $SafeModePassword.Length -eq 0) {
            throw 'A Directory Services Restore Mode password is required.'
        }
    }

    process {
        $session = New-ServerSession -ComputerName $ComputerName -Credential $Credential

        try {
            # --- Step 1: find out what the server currently is --------------
            $checkParameters = @{
                Session         = $session
                IncludeFunction = @('Write-LogEntry')
                ArgumentList    = @($LogPath)
                ErrorAction     = 'Stop'
                ScriptBlock     = {
                    param($logFilePath)

                    Write-LogEntry -Message 'Checked if Domain Controller exists' `
                        -LogPath $logFilePath | Out-Null

                    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                    $adFeature = Get-WindowsFeature -Name 'AD-Domain-Services'

                    [pscustomobject]@{
                        ComputerName  = $env:COMPUTERNAME
                        DomainRole    = [int]$computerSystem.DomainRole
                        Domain        = $computerSystem.Domain
                        PartOfDomain  = [bool]$computerSystem.PartOfDomain
                        FeatureState  = $adFeature.InstallState.ToString()
                    }
                }
            }

            $currentState = Invoke-OnServer @checkParameters

            # DomainRole 4 and 5 are backup and primary domain controllers.
            if ($currentState.DomainRole -ge 4) {
                Write-Warning ("'$($currentState.ComputerName)' is already a domain controller " +
                               "for '$($currentState.Domain)'. No changes made.")
                return $currentState
            }

            if ($currentState.PartOfDomain) {
                throw ("'$($currentState.ComputerName)' is a member of the domain " +
                       "'$($currentState.Domain)'. Remove it from that domain before creating " +
                       "a new forest.")
            }

            $shouldProcessText = "Promote to domain controller for '$DomainName'"

            if (-not $PSCmdlet.ShouldProcess($ComputerName, $shouldProcessText)) {
                return $currentState
            }

            # --- Step 2: install the role and create the forest -------------
            Write-Verbose "Promoting '$ComputerName'. This takes several minutes."

            $promoteParameters = @{
                Session         = $session
                IncludeFunction = @('Write-LogEntry')
                ArgumentList    = @($DomainName, $NetbiosName, $SafeModePassword, $LogPath)
                ErrorAction     = 'Stop'
                ScriptBlock     = {
                    param($domain, $netbios, $safeModeSecret, $logFilePath)

                    Write-LogEntry -Message 'Promote Server to a Domain Controller' `
                        -LogPath $logFilePath | Out-Null

                    $featureResult = Install-WindowsFeature -Name 'AD-Domain-Services' `
                        -IncludeManagementTools

                    Import-Module -Name 'ADDSDeployment' -ErrorAction Stop

                    $forestParameters = @{
                        DomainName                    = $domain
                        DomainNetbiosName             = $netbios
                        SafeModeAdministratorPassword = $safeModeSecret
                        InstallDns                    = $true
                        DomainMode                    = 'WinThreshold'
                        ForestMode                    = 'WinThreshold'
                        NoRebootOnCompletion          = $true
                        Force                         = $true
                    }

                    $forestResult = Install-ADDSForest @forestParameters

                    [pscustomobject]@{
                        FeatureInstalled = [bool]$featureResult.Success
                        PromotionStatus  = $forestResult.Status.ToString()
                        PromotionMessage = $forestResult.Message
                    }
                }
            }

            $promotionResult = Invoke-OnServer @promoteParameters

            # --- Step 3: restart to finish the promotion --------------------
            $restarted = $false

            if (-not $NoRestart) {
                Write-Verbose "Restarting '$ComputerName' to complete the promotion."

                # Restart-Computer cannot reliably restart the machine that is
                # hosting the current remote session, so the restart is scheduled
                # with shutdown.exe instead. The command returns straight away and
                # the session drops a few seconds later, which is expected.
                $restartOutcome = Invoke-Command -Session $session -ErrorAction SilentlyContinue `
                    -ScriptBlock {
                        $null = & shutdown.exe /r /t 5 /f /c 'Completing domain controller promotion'
                        $LASTEXITCODE
                    }

                if ($null -eq $restartOutcome) {
                    Write-Warning ("The restart could not be confirmed on '$ComputerName'. " +
                                   "Check the server and restart it manually if it is still up.")
                }
                elseif ($restartOutcome -eq 0) {
                    $restarted = $true
                    Write-Verbose "Restart scheduled on '$ComputerName'."
                }
                else {
                    Write-Warning ("The restart command failed on '$ComputerName' with exit " +
                                   "code $restartOutcome. Restart the server manually to " +
                                   "complete the promotion.")
                }
            }

            return [pscustomobject]@{
                ComputerName     = $currentState.ComputerName
                DomainName       = $DomainName
                NetbiosName      = $NetbiosName
                FeatureInstalled = $promotionResult.FeatureInstalled
                PromotionStatus  = $promotionResult.PromotionStatus
                PromotionMessage = $promotionResult.PromotionMessage
                Restarting       = $restarted
            }
        }
        finally {
            if ($null -ne $session) {
                Remove-ServerSession -Session $session -Confirm:$false `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}


function Join-ComputerToDomain {
<#
    .SYNOPSIS
    Joins a computer to the domain, working from the domain controller.

    .PARAMETER ComputerName
    Name or IP address of the domain controller to work from.

    .PARAMETER TargetComputer
    Name or IP address of the computer being joined to the domain.

    .PARAMETER DomainName
    Domain to join the target computer to.

    .PARAMETER Credential
    Domain administrator account, used to connect to the domain controller and
    to authorise the join. Prompted for if omitted.

    .PARAMETER LocalCredential
    Administrator account local to the target computer. Prompted for if omitted.

    .PARAMETER NoRestart
    Join the computer but leave it running. The join is not complete until the
    target computer restarts.

    .PARAMETER LogPath
    Full path of the activity log on the server.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetComputer,

        [Parameter(Position = 2)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}$')]
        [string]$DomainName = 'CLmicksandmacks.local',

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [System.Management.Automation.PSCredential]$LocalCredential,

        [Parameter()]
        [switch]$NoRestart,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('Credential')) {
            $Credential = Get-Credential -Message "Domain administrator for $DomainName"
        }

        if ($null -eq $Credential) {
            throw 'Domain administrator credentials are required to join a computer.'
        }

        if (-not $PSBoundParameters.ContainsKey('LocalCredential')) {
            $LocalCredential = Get-Credential -Message "Local administrator on $TargetComputer"
        }

        if ($null -eq $LocalCredential) {
            throw "Local administrator credentials for '$TargetComputer' are required."
        }
    }

    process {
        $session = New-ServerSession -ComputerName $ComputerName -Credential $Credential

        try {
            # --- Step 1: confirm the target is reachable from the server ----
            $reachParameters = @{
                Session         = $session
                IncludeFunction = @('Write-LogEntry')
                ArgumentList    = @($TargetComputer, $LogPath)
                ErrorAction     = 'Stop'
                ScriptBlock     = {
                    param($target, $logFilePath)

                    Write-LogEntry -Message "Checked computer $target is contactable" `
                        -LogPath $logFilePath | Out-Null

                    # Port 135 is the RPC endpoint mapper used by the join itself,
                    # so this proves more than an ICMP echo would.
                    $rpcTest = Test-NetConnection -ComputerName $target -Port 135 `
                        -WarningAction SilentlyContinue

                    [pscustomobject]@{
                        Target       = $target
                        PingSucceeded = [bool]$rpcTest.PingSucceeded
                        RpcReachable  = [bool]$rpcTest.TcpTestSucceeded
                        RemoteAddress = $rpcTest.RemoteAddress.IPAddressToString
                    }
                }
            }

            $reachability = Invoke-OnServer @reachParameters

            if (-not $reachability.RpcReachable) {
                throw ("'$TargetComputer' did not answer on TCP port 135 from " +
                       "'$ComputerName', so the domain join cannot proceed. Enable the " +
                       "'Windows Management Instrumentation (WMI)' firewall rules on the " +
                       "target computer and try again.")
            }

            Write-Verbose "'$TargetComputer' answered on port 135. Proceeding with the join."

            $shouldProcessText = "Join to domain '$DomainName'"

            if (-not $PSCmdlet.ShouldProcess($TargetComputer, $shouldProcessText)) {
                return $reachability
            }

            # --- Step 2: join the computer to the domain --------------------
            $joinParameters = @{
                Session         = $session
                IncludeFunction = @('Write-LogEntry')
                ErrorAction     = 'Stop'
                ArgumentList    = @($TargetComputer, $DomainName, $Credential,
                                    $LocalCredential, $LogPath)
                ScriptBlock     = {
                    param($target, $domain, $domainCredential, $localCredential, $logFilePath)

                    Write-LogEntry -Message 'Joined computer to Domain' `
                        -LogPath $logFilePath | Out-Null

                    $addParameters = @{
                        ComputerName    = $target
                        DomainName      = $domain
                        Credential      = $domainCredential
                        LocalCredential = $localCredential
                        Force           = $true
                        PassThru        = $true
                        ErrorAction     = 'Stop'
                    }

                    try {
                        $joinResult = Add-Computer @addParameters
                    }
                    catch {
                        $detail = $_.Exception.Message

                        if ($detail -match 'Access is denied') {
                            throw ("'$target' refused the local account supplied. It reached " +
                                   "the computer but was not granted administrative rights. " +
                                   "On a workgroup computer this is normally remote UAC token " +
                                   "filtering: set LocalAccountTokenFilterPolicy to 1 on " +
                                   "'$target', or supply its built-in Administrator account. " +
                                   "Check the credential is entered as '$target\<account>'. " +
                                   "Original error: $detail")
                        }

                        throw "The domain join failed on '$target'. $detail"
                    }

                    [pscustomobject]@{
                        Target       = $target
                        Domain       = $domain
                        HasSucceeded = [bool]$joinResult.HasSucceeded
                    }
                }
            }

            $joinOutcome = Invoke-OnServer @joinParameters

            if (-not $joinOutcome.HasSucceeded) {
                throw "The domain join reported failure for '$TargetComputer'."
            }

            # --- Step 3: restart the target to complete the join ------------
            $restarted = $false

            if (-not $NoRestart) {
                Write-Verbose "Restarting '$TargetComputer' to complete the join."

                $restartParameters = @{
                    Session      = $session
                    ErrorAction  = 'SilentlyContinue'
                    ArgumentList = @($TargetComputer, $LocalCredential)
                    ScriptBlock  = {
                        param($target, $localCredential)

                        try {
                            Restart-Computer -ComputerName $target -Credential $localCredential `
                                -Force -ErrorAction Stop
                            $true
                        }
                        catch {
                            $false
                        }
                    }
                }

                $restarted = [bool](Invoke-OnServer @restartParameters)

                if (-not $restarted) {
                    Write-Warning ("'$TargetComputer' was joined to '$DomainName' but could " +
                                   "not be restarted automatically. Restart it manually to " +
                                   "complete the join.")
                }
            }

            return [pscustomobject]@{
                TargetComputer = $TargetComputer
                DomainName     = $DomainName
                RemoteAddress  = $reachability.RemoteAddress
                RpcReachable   = $reachability.RpcReachable
                JoinSucceeded  = $joinOutcome.HasSucceeded
                Restarting     = $restarted
            }
        }
        finally {
            if ($null -ne $session) {
                Remove-ServerSession -Session $session -Confirm:$false `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}


Export-ModuleMember -Function 'Write-LogEntry',
                              'Test-ServerConnection',
                              'New-DomainController',
                              'Join-ComputerToDomain'
