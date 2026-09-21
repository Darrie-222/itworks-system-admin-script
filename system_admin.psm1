#requires -Version 5.1

<#
    system_admin.psm1

    Windows Server 2022 administration module for Mick and Macks Pies.

    The module is imported and run on the CLIENT workstation. Each function
    sends its work to the target server over PowerShell remoting using the
    helper functions in ExecuteOnServer.psm1, and every action is recorded in
    an activity log held on the server.

    Author:  Cooper Lane
    Company: ITWorks
    Version: 1.2
#>

Set-StrictMode -Version Latest

# Load the remoting helper that lives alongside this module.
$executeOnServerPath = Join-Path -Path $PSScriptRoot -ChildPath 'ExecuteOnServer.psm1'

if (-not (Test-Path -Path $executeOnServerPath)) {
    throw ("ExecuteOnServer.psm1 was not found in '$PSScriptRoot'. Both module files must " +
           "sit in the same folder.")
}

Import-Module -Name $executeOnServerPath -Force -ErrorAction Stop


# Default location of the activity log on the target server.
$script:DefaultLogPath = 'C:\myLogs\logs.txt'


function Write-LogEntry {
<#
    .SYNOPSIS
    Writes a timestamped entry to the activity log.

    .DESCRIPTION
    Appends one line to the activity log in the form 'yyyy-MM-dd HH:mm:ss - message'.
    The containing folder is created if it does not already exist.

    This function is designed to run ON THE SERVER. It is sent into the remote
    session by the other functions in this module rather than being called
    directly from the client.

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

    .DESCRIPTION
    Installs the Active Directory Domain Services role on the target server and
    promotes it to the first domain controller of a new forest, then restarts it.

    The server is inspected first. If it is already a domain controller the
    function reports that and stops rather than attempting a second promotion.
    A server that is a member of an existing domain is rejected, because a new
    forest cannot be created on a domain member.

    Administrator credentials and the Directory Services Restore Mode password
    are prompted for at run time and are never written to disk.

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

    .EXAMPLE
    New-DomainController -ComputerName 10.1.1.10

    .EXAMPLE
    New-DomainController -ComputerName 10.1.1.10 -NoRestart -Verbose

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


Export-ModuleMember -Function 'Write-LogEntry',
                              'Test-ServerConnection',
                              'New-DomainController'
