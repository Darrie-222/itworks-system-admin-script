#requires -Version 5.1

<#
    system_admin.psm1

    Windows Server 2022 administration module for Mick and Macks Pies.

    Author:  Cooper Lane
    Company: ITWorks
    Version: 2.1
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


function Get-LogonDomainController {
<#
    .SYNOPSIS
    Returns the host name of a domain controller this client can reach.

    .OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    process {
        if (-not [string]::IsNullOrWhiteSpace($env:LOGONSERVER)) {
            $logonServer = $env:LOGONSERVER -replace '^\\\\', ''

            if (-not [string]::IsNullOrWhiteSpace($logonServer)) {
                Write-Verbose "Using the logon domain controller '$logonServer'."
                return $logonServer
            }
        }

        try {
            $currentDomain =
                [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $discovered = $currentDomain.FindDomainController().Name

            Write-Verbose "Discovered domain controller '$discovered'."
            return $discovered
        }
        catch {
            throw ("No domain controller could be identified for this client. Supply one " +
                   "with -DomainController. Underlying error: $($_.Exception.Message)")
        }
    }
}


function Import-DirectoryCsv {
<#
    .SYNOPSIS
    Reads a CSV on the client and checks it has the columns required.

    .PARAMETER Path
    Full path of the CSV file.

    .PARAMETER RequiredColumn
    Column headings that must be present.

    .OUTPUTS
    System.Object[]
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RequiredColumn
    )

    process {
        if (-not (Test-Path -Path $Path)) {
            throw "The CSV file '$Path' was not found."
        }

        $rows = @(Import-Csv -Path $Path)

        if ($rows.Count -eq 0) {
            throw "The CSV file '$Path' has headings but no rows."
        }

        $columns = $rows[0].PSObject.Properties.Name
        $missing = @($RequiredColumn | Where-Object { $columns -notcontains $_ })

        if ($missing.Count -gt 0) {
            throw ("The CSV file '$Path' is missing the column(s) " +
                   "'$($missing -join ', ')'. Columns found: '$($columns -join ', ')'.")
        }

        Write-Verbose "Read $($rows.Count) row(s) from '$Path'."
        return $rows
    }
}


function Get-CsvValue {
<#
    .SYNOPSIS
    Reads an optional column from a CSV row without failing when it is absent.

    .PARAMETER Row
    A row produced by Import-Csv.

    .PARAMETER Name
    Column name to read.

    .OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [psobject]$Row,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    process {
        if ($Row.PSObject.Properties.Name -contains $Name) {
            $value = $Row.$Name

            if ($null -ne $value) {
                return $value.ToString().Trim()
            }
        }

        return ''
    }
}


function Get-NetworkAddress {
<#
    .SYNOPSIS
    Returns the network address for an address and subnet mask.

    .PARAMETER IPAddress
    Any address within the network.

    .PARAMETER SubnetMask
    Subnet mask for the network.

    .OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [ipaddress]$IPAddress,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [ipaddress]$SubnetMask
    )

    process {
        $addressBytes = $IPAddress.GetAddressBytes()
        $maskBytes = $SubnetMask.GetAddressBytes()
        $networkBytes = New-Object 'System.Byte[]' 4

        for ($index = 0; $index -lt 4; $index++) {
            $networkBytes[$index] = $addressBytes[$index] -band $maskBytes[$index]
        }

        return ([ipaddress]$networkBytes).IPAddressToString
    }
}


function Resolve-TargetName {
<#
    .SYNOPSIS
    Turns an IP address into the host name remoting can authenticate to.

    .PARAMETER Target
    Host name or IP address supplied by the caller.

    .OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    process {
        $parsedAddress = [ipaddress]::None

        if (-not [ipaddress]::TryParse($Target, [ref]$parsedAddress)) {
            return $Target
        }

        try {
            $hostEntry = [System.Net.Dns]::GetHostEntry($Target)

            if (-not [string]::IsNullOrWhiteSpace($hostEntry.HostName)) {
                Write-Verbose "Resolved '$Target' to '$($hostEntry.HostName)'."
                return $hostEntry.HostName
            }
        }
        catch {
            Write-Verbose ("'$Target' could not be resolved to a name. A reverse lookup " +
                           "zone may be missing from DNS.")
        }

        return $Target
    }
}


function Write-LogEntry {
<#
    .SYNOPSIS
    Writes a timestamped entry to the activity log.

    .PARAMETER Message
    Description of the task being recorded.

    .PARAMETER LogPath
    Full path of the log file. Defaults to C:\myLogs\logs.txt.

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

    .PARAMETER ComputerName
    Name or IP address of the target server.

    .PARAMETER Credential
    Account used to connect. The user is prompted if this is omitted.

    .PARAMETER LogPath
    Full path of the activity log on the server.

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


function Connect-DomainComputer {
<#
    .SYNOPSIS
    Opens a PowerShell session to a computer in the domain.

    .PARAMETER ComputerName
    Name or IP address of the domain computer to connect to.

    .PARAMETER DomainController
    Host name of the domain controller used for the Active Directory checks and
    for logging. Defaults to the domain controller that authenticated this
    session. Give a host name, not the domain name: Kerberos matches a service
    principal name registered against a host, and the domain name has none.

    .PARAMETER Credential
    Account used to connect. Prompted for unless -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the domain controller.

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
        [ValidateNotNullOrEmpty()]
        [string]$DomainController,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        # The brief requires the client to be a domain member before it may
        # open sessions to other computers in the domain.
        $clientSystem = Get-CimInstance -ClassName Win32_ComputerSystem

        if (-not $clientSystem.PartOfDomain) {
            throw ("This computer is not a member of a domain, so it cannot open a session " +
                   "to a domain computer. Join it to the domain first.")
        }

        $clientName = $clientSystem.Name
        Write-Verbose "Client '$clientName' is a member of '$($clientSystem.Domain)'."

        if (-not $PSBoundParameters.ContainsKey('DomainController')) {
            $DomainController = Get-LogonDomainController
        }

        # Build the connection arguments once and reuse them for both sessions.
        $connectionSplat = @{}

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }
    }

    process {
        $controllerSession = New-ServerSession -ComputerName $DomainController @connectionSplat
        $targetSession = $null

        try {
            # --- Confirm the client is present in Active Directory ----------
            $directoryCheck = Invoke-OnServer -Session $controllerSession -ErrorAction Stop `
                -IncludeFunction @('Write-LogEntry') `
                -ArgumentList @($clientName, $ComputerName, $LogPath) -ScriptBlock {
                    param($client, $target, $logFilePath)

                    Import-Module -Name 'ActiveDirectory' -ErrorAction Stop

                    Write-LogEntry -Message "Checked $client is in Active Directory" `
                        -LogPath $logFilePath | Out-Null

                    $clientObject = Get-ADComputer -Filter "Name -eq '$client'" `
                        -ErrorAction SilentlyContinue

                    # The target may be given as an IP address, which has no
                    # name to match in the directory, so this is advisory only.
                    $targetObject = Get-ADComputer -Filter "Name -eq '$target'" `
                        -ErrorAction SilentlyContinue

                    [pscustomobject]@{
                        ClientInDirectory = [bool]$clientObject
                        TargetInDirectory = [bool]$targetObject
                        ClientLocation    = if ($clientObject) {
                                                $clientObject.DistinguishedName
                                            }
                                            else { $null }
                    }
                }

            if (-not $directoryCheck.ClientInDirectory) {
                throw ("'$clientName' has no computer object in Active Directory on " +
                       "'$DomainController'. The client must be added to the directory " +
                       "before it can open sessions to domain computers.")
            }

            Write-Verbose "'$clientName' found at $($directoryCheck.ClientLocation)."

            if (-not $directoryCheck.TargetInDirectory) {
                Write-Verbose ("'$ComputerName' was not matched by name in Active Directory. " +
                               "This is expected when connecting by IP address.")
            }

            # --- Open the session the caller asked for ----------------------
            $targetSession = New-ServerSession -ComputerName $ComputerName @connectionSplat

            Invoke-OnServer -Session $controllerSession -ErrorAction SilentlyContinue `
                -IncludeFunction @('Write-LogEntry') `
                -ArgumentList @($clientName, $ComputerName, $LogPath) -ScriptBlock {
                    param($client, $target, $logFilePath)

                    Write-LogEntry -Message "Opened a remote session from $client to $target" `
                        -LogPath $logFilePath | Out-Null
                } | Out-Null

            Write-Verbose "Session $($targetSession.Id) open to '$ComputerName'."
            return $targetSession
        }
        catch {
            if ($null -ne $targetSession) {
                Remove-ServerSession -Session $targetSession -Confirm:$false `
                    -ErrorAction SilentlyContinue
            }

            throw
        }
        finally {
            if ($null -ne $controllerSession) {
                Remove-ServerSession -Session $controllerSession -Confirm:$false `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}


function Add-OrganizationalUnit {
<#
    .SYNOPSIS
    Creates Organizational Units in Active Directory from a CSV file.

    .PARAMETER CsvPath
    Full path of the CSV file listing the units to create.

    .PARAMETER ComputerName
    Host name of the domain controller. Defaults to the one that authenticated
    this session.

    .PARAMETER Credential
    Account used to connect. Prompted for unless -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the domain controller.

    .EXAMPLE
    Add-OrganizationalUnit -CsvPath .\ous.csv -UseCurrentUser

    .EXAMPLE
    Add-OrganizationalUnit -CsvPath C:\ITWorks\ous.csv -Verbose

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
            $ComputerName = Get-LogonDomainController
        }

        $rows = Import-DirectoryCsv -Path $CsvPath -RequiredColumn @('Name')

        # Normalise every row on the client so the code running on the server
        # can rely on all three properties being present.
        $unitList = @(
            foreach ($row in $rows) {
                [pscustomobject]@{
                    Name        = (Get-CsvValue -Row $row -Name 'Name')
                    Path        = (Get-CsvValue -Row $row -Name 'Path') -replace ';', ','
                    Description = (Get-CsvValue -Row $row -Name 'Description')
                }
            }
        )

        $blank = @($unitList | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) })

        if ($blank.Count -gt 0) {
            throw "'$CsvPath' contains $($blank.Count) row(s) with an empty Name column."
        }
    }

    process {
        $shouldProcessText = "Create $($unitList.Count) Organizational Unit(s) from '$CsvPath'"

        if (-not $PSCmdlet.ShouldProcess($ComputerName, $shouldProcessText)) {
            return
        }

        $connectionSplat = @{ ComputerName = $ComputerName }

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }

        $results = Invoke-OnServer @connectionSplat -ErrorAction Stop `
            -IncludeFunction @('Write-LogEntry') `
            -ArgumentList @($unitList, $LogPath) -ScriptBlock {
                param($units, $logFilePath)

                Import-Module -Name 'ActiveDirectory' -ErrorAction Stop

                $domainRoot = (Get-ADDomain).DistinguishedName

                foreach ($unit in $units) {
                    $targetPath = $unit.Path

                    if ([string]::IsNullOrWhiteSpace($targetPath)) {
                        $targetPath = $domainRoot
                    }

                    $existing = Get-ADOrganizationalUnit -Filter "Name -eq '$($unit.Name)'" `
                        -SearchBase $targetPath -ErrorAction SilentlyContinue

                    if ($existing) {
                        [pscustomobject]@{
                            Name              = $unit.Name
                            Action            = 'Skipped'
                            DistinguishedName = $existing.DistinguishedName
                            Detail            = 'Already exists'
                        }

                        continue
                    }

                    try {
                        $newUnitParameters = @{
                            Name        = $unit.Name
                            Path        = $targetPath
                            ErrorAction = 'Stop'
                        }

                        if (-not [string]::IsNullOrWhiteSpace($unit.Description)) {
                            $newUnitParameters['Description'] = $unit.Description
                        }

                        $created = New-ADOrganizationalUnit @newUnitParameters -PassThru

                        Write-LogEntry -Message "Added Organizational Unit $($unit.Name)" `
                            -LogPath $logFilePath | Out-Null

                        [pscustomobject]@{
                            Name              = $unit.Name
                            Action            = 'Created'
                            DistinguishedName = $created.DistinguishedName
                            Detail            = ''
                        }
                    }
                    catch {
                        [pscustomobject]@{
                            Name              = $unit.Name
                            Action            = 'Failed'
                            DistinguishedName = ''
                            Detail            = $_.Exception.Message
                        }
                    }
                }
            }

        $created = @($results | Where-Object { $_.Action -eq 'Created' }).Count
        $failed = @($results | Where-Object { $_.Action -eq 'Failed' }).Count

        Write-Verbose "Created $created unit(s), $failed failure(s)."

        if ($failed -gt 0) {
            Write-Warning "$failed Organizational Unit(s) could not be created. See the Detail column."
        }

        return $results
    }
}


function Add-DomainUser {
<#
    .SYNOPSIS
    Creates Active Directory user accounts from a CSV file.

    .PARAMETER CsvPath
    Full path of the CSV file listing the staff to create.

    .PARAMETER ComputerName
    Host name of the domain controller. Defaults to the one that authenticated
    this session.

    .PARAMETER InitialPassword
    Password set on every new account. Prompted for if omitted.

    .PARAMETER ChangePasswordAtLogon
    Require each new user to set their own password at first sign in. On by
    default.

    .PARAMETER Credential
    Account used to connect. Prompted for unless -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the domain controller.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [System.Security.SecureString]$InitialPassword,

        [Parameter()]
        [bool]$ChangePasswordAtLogon = $true,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
            $ComputerName = Get-LogonDomainController
        }

        $requiredColumns = @('FirstName', 'LastName', 'SamAccountName', 'OU')
        $rows = Import-DirectoryCsv -Path $CsvPath -RequiredColumn $requiredColumns

        $userList = @(
            foreach ($row in $rows) {
                [pscustomobject]@{
                    FirstName      = (Get-CsvValue -Row $row -Name 'FirstName')
                    LastName       = (Get-CsvValue -Row $row -Name 'LastName')
                    SamAccountName = (Get-CsvValue -Row $row -Name 'SamAccountName')
                    OrganizationalUnit = (Get-CsvValue -Row $row -Name 'OU')
                    Description    = (Get-CsvValue -Row $row -Name 'Description')
                }
            }
        )

        # A SamAccountName longer than 20 characters is rejected by Active
        # Directory, so it is caught here with a message naming the offender.
        foreach ($user in $userList) {
            if ([string]::IsNullOrWhiteSpace($user.SamAccountName)) {
                throw "'$CsvPath' contains a row with an empty SamAccountName column."
            }

            if ($user.SamAccountName.Length -gt 20) {
                throw ("The account name '$($user.SamAccountName)' is " +
                       "$($user.SamAccountName.Length) characters. Active Directory allows " +
                       "a maximum of 20.")
            }
        }

        if (-not $PSBoundParameters.ContainsKey('InitialPassword')) {
            $InitialPassword = Read-Host -AsSecureString `
                -Prompt 'Initial password for the new accounts'
        }

        if ($null -eq $InitialPassword -or $InitialPassword.Length -eq 0) {
            throw 'An initial password is required to create accounts.'
        }
    }

    process {
        $shouldProcessText = "Create $($userList.Count) user account(s) from '$CsvPath'"

        if (-not $PSCmdlet.ShouldProcess($ComputerName, $shouldProcessText)) {
            return
        }

        $connectionSplat = @{ ComputerName = $ComputerName }

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }

        $results = Invoke-OnServer @connectionSplat -ErrorAction Stop `
            -IncludeFunction @('Write-LogEntry') `
            -ArgumentList @($userList, $InitialPassword, $ChangePasswordAtLogon, $LogPath) `
            -ScriptBlock {
                param($people, $accountPassword, $mustChangePassword, $logFilePath)

                Import-Module -Name 'ActiveDirectory' -ErrorAction Stop

                $domain = Get-ADDomain

                foreach ($person in $people) {
                    $accountName = $person.SamAccountName

                    $existing = Get-ADUser -Filter "SamAccountName -eq '$accountName'" `
                        -ErrorAction SilentlyContinue

                    if ($existing) {
                        [pscustomobject]@{
                            SamAccountName = $accountName
                            Action         = 'Skipped'
                            Location       = $existing.DistinguishedName
                            Detail         = 'Account already exists'
                        }

                        continue
                    }

                    $unitName = $person.OrganizationalUnit

                    $unit = Get-ADOrganizationalUnit -Filter "Name -eq '$unitName'" `
                        -ErrorAction SilentlyContinue

                    if (-not $unit) {
                        [pscustomobject]@{
                            SamAccountName = $accountName
                            Action         = 'Failed'
                            Location       = ''
                            Detail         = "Organizational Unit '$unitName' does not exist"
                        }

                        continue
                    }

                    try {
                        $displayName = "$($person.FirstName) $($person.LastName)".Trim()

                        $newUserParameters = @{
                            Name                  = $displayName
                            DisplayName           = $displayName
                            GivenName             = $person.FirstName
                            Surname               = $person.LastName
                            SamAccountName        = $accountName
                            UserPrincipalName     = "$accountName@$($domain.DNSRoot)"
                            Path                  = $unit.DistinguishedName
                            AccountPassword       = $accountPassword
                            Enabled               = $true
                            ChangePasswordAtLogon = $mustChangePassword
                            ErrorAction           = 'Stop'
                        }

                        if (-not [string]::IsNullOrWhiteSpace($person.Description)) {
                            $newUserParameters['Description'] = $person.Description
                        }

                        $created = New-ADUser @newUserParameters -PassThru

                        Write-LogEntry -Message 'Added a user to Domain' `
                            -LogPath $logFilePath | Out-Null

                        [pscustomobject]@{
                            SamAccountName = $accountName
                            Action         = 'Created'
                            Location       = $created.DistinguishedName
                            Detail         = ''
                        }
                    }
                    catch {
                        [pscustomobject]@{
                            SamAccountName = $accountName
                            Action         = 'Failed'
                            Location       = ''
                            Detail         = $_.Exception.Message
                        }
                    }
                }
            }

        $created = @($results | Where-Object { $_.Action -eq 'Created' }).Count
        $failed = @($results | Where-Object { $_.Action -eq 'Failed' }).Count

        Write-Verbose "Created $created account(s), $failed failure(s)."

        if ($failed -gt 0) {
            Write-Warning "$failed account(s) could not be created. See the Detail column."
        }

        return $results
    }
}


function New-DhcpScope {
<#
    .SYNOPSIS
    Configures the DHCP service and creates an address pool for the office.

    .PARAMETER ComputerName
    Host name of the server to configure. Defaults to the domain controller that
    authenticated this session.

    .PARAMETER ScopeName
    Label for the address pool.

    .PARAMETER StartRange
    First address handed out to clients.

    .PARAMETER EndRange
    Last address handed out to clients.

    .PARAMETER SubnetMask
    Subnet mask for the pool.

    .PARAMETER Router
    Default gateway given to clients. Omitted entirely when not supplied.

    .PARAMETER DnsServer
    DNS server given to clients. Defaults to the server being configured.

    .PARAMETER LeaseDurationDays
    How long a client keeps an address before renewing.

    .PARAMETER Credential
    Account used to connect. Prompted for unless -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the server.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$ScopeName = 'Mick and Macks Pies LAN',

        [Parameter()]
        [ValidateNotNull()]
        [ipaddress]$StartRange = '10.1.1.100',

        [Parameter()]
        [ValidateNotNull()]
        [ipaddress]$EndRange = '10.1.1.200',

        [Parameter()]
        [ValidateNotNull()]
        [ipaddress]$SubnetMask = '255.255.255.0',

        [Parameter()]
        [ipaddress]$Router,

        [Parameter()]
        [ipaddress]$DnsServer,

        [Parameter()]
        [ValidateRange(1, 30)]
        [int]$LeaseDurationDays = 8,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
            $ComputerName = Get-LogonDomainController
        }

        # Both ends of the range must sit on the same network, or the scope is
        # meaningless. Checking here keeps the failure local and quick.
        $startNetwork = Get-NetworkAddress -IPAddress $StartRange -SubnetMask $SubnetMask
        $endNetwork = Get-NetworkAddress -IPAddress $EndRange -SubnetMask $SubnetMask

        if ($startNetwork -ne $endNetwork) {
            throw ("The range $($StartRange.IPAddressToString) to " +
                   "$($EndRange.IPAddressToString) spans two networks " +
                   "($startNetwork and $endNetwork) under mask " +
                   "$($SubnetMask.IPAddressToString).")
        }

        $startValue = [uint32[]]$StartRange.GetAddressBytes()
        $endValue = [uint32[]]$EndRange.GetAddressBytes()

        for ($index = 0; $index -lt 4; $index++) {
            if ($startValue[$index] -lt $endValue[$index]) { break }

            if ($startValue[$index] -gt $endValue[$index]) {
                throw ("The start address $($StartRange.IPAddressToString) is higher than " +
                       "the end address $($EndRange.IPAddressToString).")
            }
        }

        $scopeId = $startNetwork
        Write-Verbose "Scope network address is $scopeId."
    }

    process {
        $shouldProcessText = "Configure DHCP and create the scope $scopeId"

        if (-not $PSCmdlet.ShouldProcess($ComputerName, $shouldProcessText)) {
            return
        }

        $connectionSplat = @{ ComputerName = $ComputerName }

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }

        $routerAddress = if ($PSBoundParameters.ContainsKey('Router')) {
                             $Router.IPAddressToString
                         }
                         else { '' }

        $dnsAddress = if ($PSBoundParameters.ContainsKey('DnsServer')) {
                          $DnsServer.IPAddressToString
                      }
                      else { '' }

        $argumentList = @(
            $scopeId,
            $ScopeName,
            $StartRange.IPAddressToString,
            $EndRange.IPAddressToString,
            $SubnetMask.IPAddressToString,
            $routerAddress,
            $dnsAddress,
            $LeaseDurationDays,
            $LogPath
        )

        $result = Invoke-OnServer @connectionSplat -ErrorAction Stop `
            -IncludeFunction @('Write-LogEntry') -ArgumentList $argumentList -ScriptBlock {
                param($scope, $label, $rangeStart, $rangeEnd, $mask, $gateway, $dns,
                      $leaseDays, $logFilePath)

                # --- Install the role if it is not already there -------------
                $dhcpFeature = Get-WindowsFeature -Name 'DHCP'
                $featureInstalled = $false

                if ($dhcpFeature.InstallState -ne 'Installed') {
                    $null = Install-WindowsFeature -Name 'DHCP' -IncludeManagementTools

                    # Creates the DHCP Administrators and DHCP Users groups.
                    $null = & netsh dhcp add securitygroups
                    Restart-Service -Name 'dhcpserver' -Force

                    $featureInstalled = $true
                }

                Import-Module -Name 'DhcpServer' -ErrorAction Stop

                Write-LogEntry -Message 'Checked current DHCP settings' `
                    -LogPath $logFilePath | Out-Null

                # --- Report what is already configured -----------------------
                $existingScopes = @(Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        '{0} ({1} - {2}) {3}' -f $_.ScopeId, $_.StartRange, $_.EndRange, $_.State
                    })

                # --- Authorise the server in Active Directory ----------------
                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                $serverFqdn = '{0}.{1}' -f $computerSystem.Name, $computerSystem.Domain

                $serverAddress = (Get-NetIPAddress -AddressFamily IPv4 |
                    Where-Object { $_.IPAddress -like ($scope -replace '\.\d+$', '.*') } |
                    Select-Object -First 1).IPAddress

                $alreadyAuthorised = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue |
                    Where-Object { $_.DnsName -eq $serverFqdn })

                if ($alreadyAuthorised.Count -eq 0 -and $serverAddress) {
                    Add-DhcpServerInDC -DnsName $serverFqdn -IPAddress $serverAddress `
                        -ErrorAction SilentlyContinue
                }

                # Clears the post-deployment task Server Manager would show.
                $rolePath = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'

                if (Test-Path -Path $rolePath) {
                    Set-ItemProperty -Path $rolePath -Name 'ConfigurationState' -Value 2 `
                        -ErrorAction SilentlyContinue
                }

                # --- Create the scope ----------------------------------------
                $scopeExists = Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction SilentlyContinue
                $scopeAction = 'Skipped'

                if (-not $scopeExists) {
                    $scopeParameters = @{
                        Name          = $label
                        StartRange    = $rangeStart
                        EndRange      = $rangeEnd
                        SubnetMask    = $mask
                        State         = 'Active'
                        LeaseDuration = ([timespan]::FromDays($leaseDays))
                        ErrorAction   = 'Stop'
                    }

                    $null = Add-DhcpServerv4Scope @scopeParameters
                    $scopeAction = 'Created'

                    Write-LogEntry -Message "Configured DHCP scope $scope" `
                        -LogPath $logFilePath | Out-Null
                }

                # --- Scope options -------------------------------------------
                $optionParameters = @{
                    ScopeId     = $scope
                    DnsDomain   = $computerSystem.Domain
                    ErrorAction = 'SilentlyContinue'
                }

                if ([string]::IsNullOrWhiteSpace($dns)) {
                    if ($serverAddress) { $optionParameters['DnsServer'] = $serverAddress }
                }
                else {
                    $optionParameters['DnsServer'] = $dns
                }

                if (-not [string]::IsNullOrWhiteSpace($gateway)) {
                    $optionParameters['Router'] = $gateway
                }

                Set-DhcpServerv4OptionValue @optionParameters

                $finalScope = Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction SilentlyContinue

                [pscustomobject]@{
                    ServerName       = $computerSystem.Name
                    RoleInstalled    = $featureInstalled
                    Authorised       = $true
                    ScopesBefore     = $existingScopes
                    ScopeId          = $scope
                    ScopeAction      = $scopeAction
                    ScopeState       = if ($finalScope) { $finalScope.State.ToString() }
                                       else { 'Unknown' }
                    Range            = '{0} - {1}' -f $rangeStart, $rangeEnd
                    DnsServerOption  = $optionParameters['DnsServer']
                    RouterOption     = if ([string]::IsNullOrWhiteSpace($gateway)) { 'not set' }
                                       else { $gateway }
                    ServiceStatus    = (Get-Service -Name 'dhcpserver').Status.ToString()
                }
            }

        if ($result.ScopesBefore.Count -eq 0) {
            Write-Verbose 'No DHCP pools existed on this server before this run.'
        }
        else {
            Write-Verbose "Pools already present: $($result.ScopesBefore -join '; ')"
        }

        return $result
    }
}


function Get-TopTenError {
<#
    .SYNOPSIS
    Collects the ten most recent system errors and writes them to a text file.

    .PARAMETER IPAddress
    IP address or host name of the computer to inspect. Defaults to the domain
    controller that authenticated this session.

    .PARAMETER OutputPath
    File on the target computer to write the report to.

    .PARAMETER MaximumEvents
    How many errors to collect.

    .PARAMETER Credential
    Account used to connect. Prompted for unless -UseCurrentUser is supplied.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the domain controller.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$IPAddress,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath = 'C:\myLogs\toptenerrors.txt',

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MaximumEvents = 10,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        $domainController = Get-LogonDomainController

        if (-not $PSBoundParameters.ContainsKey('IPAddress')) {
            $IPAddress = $domainController
        }

        # An IP address cannot be authenticated to with Kerberos, so it is
        # turned into the host name behind it wherever DNS can supply one.
        $targetName = Resolve-TargetName -Target $IPAddress

        $connectionSplat = @{}

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }
    }

    process {
        Write-Verbose "Collecting the last $MaximumEvents system errors from '$targetName'."

        $report = Invoke-OnServer -ComputerName $targetName @connectionSplat -ErrorAction Stop `
            -ArgumentList @($OutputPath, $MaximumEvents) -ScriptBlock {
                param($reportPath, $eventCount)

                $reportFolder = Split-Path -Path $reportPath -Parent

                if (-not (Test-Path -Path $reportFolder)) {
                    $null = New-Item -Path $reportFolder -ItemType Directory -Force
                }

                # Level 2 is Error in the Windows event schema.
                $filter = @{ LogName = 'System'; Level = 2 }

                $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $eventCount `
                    -ErrorAction SilentlyContinue)

                $entries = @(
                    $events | Select-Object -Property TimeCreated, Id, ProviderName,
                        LevelDisplayName, Message
                )

                $header = "Top $eventCount system errors on $env:COMPUTERNAME"
                $stamp = "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

                $header, $stamp, '' | Out-File -FilePath $reportPath -Encoding UTF8
                $entries | Format-List | Out-File -FilePath $reportPath -Encoding UTF8 -Append

                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    ErrorsFound  = $entries.Count
                    ReportPath   = $reportPath
                    Entries      = $entries
                }
            }

        $logMessage = "Retrieved top $MaximumEvents system errors from $($report.ComputerName)"

        Invoke-OnServer -ComputerName $domainController @connectionSplat `
            -ErrorAction SilentlyContinue -IncludeFunction @('Write-LogEntry') `
            -ArgumentList @($logMessage, $LogPath) -ScriptBlock {
                param($message, $logFilePath)

                Write-LogEntry -Message $message -LogPath $logFilePath | Out-Null
            } | Out-Null

        if ($report.ErrorsFound -eq 0) {
            Write-Verbose "No system errors were found on '$($report.ComputerName)'."
        }

        return $report
    }
}


function Register-DiskCleanupTask {
<#
    .SYNOPSIS
    Schedules a daily disk cleanup on a computer.

    .PARAMETER IPAddress
    IP address or host name of the computer to schedule the task on. Defaults to
    this computer.

    .PARAMETER At
    Time of day the task runs.

    .PARAMETER TaskName
    Name the task is registered under.

    .PARAMETER Credential
    Account used to connect to a remote computer. Ignored for the local machine.

    .PARAMETER UseCurrentUser
    Connect as the signed-in domain account instead of prompting.

    .PARAMETER LogPath
    Full path of the activity log on the domain controller.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$IPAddress = 'localhost',

        [Parameter(Position = 1)]
        [ValidateNotNull()]
        [datetime]$At = '06:00',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName = 'ITWorks Daily Disk Cleanup',

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [switch]$UseCurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath = $script:DefaultLogPath
    )

    begin {
        $localNames = @('localhost', '127.0.0.1', '.', $env:COMPUTERNAME)
        $isLocal = $localNames -contains $IPAddress

        # Kerberos cannot authenticate to a bare IP address, so a remote target
        # given as one is resolved to its host name first.
        $targetName = if ($isLocal) { $IPAddress }
                      else { Resolve-TargetName -Target $IPAddress }

        $connectionSplat = @{}

        if ($UseCurrentUser) {
            $connectionSplat['UseCurrentUser'] = $true
        }
        elseif ($PSBoundParameters.ContainsKey('Credential')) {
            $connectionSplat['Credential'] = $Credential
        }

        # The categories Disk Cleanup will act on. Chosen to remove only files
        # Windows can recreate, so nothing a user would miss is deleted.
        $cleanupCategories = @(
            'Temporary Files',
            'Temporary Internet Files',
            'Downloaded Program Files',
            'Thumbnail Cache',
            'Delivery Optimization Files',
            'Update Cleanup',
            'Windows Error Reporting Files'
        )

        $work = {
            param($taskLabel, $runTime, $categories)

            $cleanupTool = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cleanmgr.exe'

            if (-not (Test-Path -Path $cleanupTool)) {
                throw ("Disk Cleanup (cleanmgr.exe) is not installed on " +
                       "$env:COMPUTERNAME, so the task cannot be scheduled.")
            }

            # Writing StateFlags0001 is what the /sageset dialog does. Without
            # it, cleanmgr /sagerun:1 starts and immediately exits.
            $cachesRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
            $enabled = @()

            foreach ($category in $categories) {
                $categoryPath = Join-Path -Path $cachesRoot -ChildPath $category

                if (Test-Path -Path $categoryPath) {
                    New-ItemProperty -Path $categoryPath -Name 'StateFlags0001' -Value 2 `
                        -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

                    $enabled += $category
                }
            }

            $action = New-ScheduledTaskAction -Execute $cleanupTool -Argument '/sagerun:1'
            $trigger = New-ScheduledTaskTrigger -Daily -At $runTime

            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
                -LogonType ServiceAccount -RunLevel Highest

            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries

            $registerParameters = @{
                TaskName    = $taskLabel
                Action      = $action
                Trigger     = $trigger
                Principal   = $principal
                Settings    = $settings
                Description = 'Removes temporary files each morning. Created by ITWorks.'
                Force       = $true
                ErrorAction = 'Stop'
            }

            $registered = Register-ScheduledTask @registerParameters

            [pscustomobject]@{
                ComputerName      = $env:COMPUTERNAME
                TaskName          = $registered.TaskName
                State             = $registered.State.ToString()
                NextRunTime       = (Get-ScheduledTaskInfo -TaskName $taskLabel).NextRunTime
                CategoriesEnabled = $enabled
            }
        }
    }

    process {
        $timeText = $At.ToString('HH:mm')
        $shouldProcessText = "Register '$TaskName' to run daily at $timeText"

        if (-not $PSCmdlet.ShouldProcess($IPAddress, $shouldProcessText)) {
            return
        }

        $arguments = @($TaskName, $At, $cleanupCategories)

        if ($isLocal) {
            Write-Verbose "Registering '$TaskName' on this computer."
            $result = & $work @arguments
        }
        else {
            Write-Verbose "Registering '$TaskName' on '$targetName'."

            $result = Invoke-OnServer -ComputerName $targetName @connectionSplat `
                -ErrorAction Stop -ArgumentList $arguments -ScriptBlock $work
        }

        $logMessage = "Registered daily disk cleanup task on $($result.ComputerName)"

        Invoke-OnServer -ComputerName (Get-LogonDomainController) @connectionSplat `
            -ErrorAction SilentlyContinue -IncludeFunction @('Write-LogEntry') `
            -ArgumentList @($logMessage, $LogPath) -ScriptBlock {
                param($message, $logFilePath)

                Write-LogEntry -Message $message -LogPath $logFilePath | Out-Null
            } | Out-Null

        return $result
    }
}


Export-ModuleMember -Function 'Write-LogEntry',
                              'Test-ServerConnection',
                              'New-DomainController',
                              'Join-ComputerToDomain',
                              'Connect-DomainComputer',
                              'Add-OrganizationalUnit',
                              'Add-DomainUser',
                              'New-DhcpScope',
                              'Get-TopTenError',
                              'Register-DiskCleanupTask'
