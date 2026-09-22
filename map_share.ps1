#requires -Version 5.1

<#
    .SYNOPSIS
    Maps the Mick and Macks Pies shared folder to a drive letter.

    .PARAMETER SharePath
    Full network path of the shared folder.

    .PARAMETER DriveLetter
    Drive letter to connect the share to.

    .NOTES
    Author:  Cooper Lane
    Company: ITWorks
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SharePath = '\\MMPIES-SRV1\mickandmacks_share',

    [Parameter(Position = 1)]
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$DriveLetter = 'S',

    [Parameter(Position = 2)]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $env:TEMP -ChildPath 'map_share.log')
)

begin {
    function Write-MapLog {
        param([string]$Message)

        $line = '{0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message

        try {
            Add-Content -Path $LogPath -Value $line -ErrorAction Stop
        }
        catch {
            # A logon script must never interrupt the user. If the record
            # cannot be written there is nothing useful left to do about it.
        }

        Write-Verbose $line
    }

    $letter = $DriveLetter.ToUpper()
}

process {
    Write-MapLog -Message "Mapping $letter to $SharePath for $env:USERNAME"

    # The share may not answer yet if the network is still coming up at logon.
    if (-not (Test-Path -Path $SharePath)) {
        Write-MapLog -Message "$SharePath could not be reached. No drive was mapped."
        return
    }

    $existingDrive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue

    if ($existingDrive) {
        if ($existingDrive.DisplayRoot -eq $SharePath) {
            Write-MapLog -Message "$letter is already mapped to $SharePath. Nothing to do."
            return
        }

        Write-MapLog -Message ("$letter is mapped to $($existingDrive.DisplayRoot). " +
                               "Replacing it.")

        try {
            Remove-PSDrive -Name $letter -Force -ErrorAction Stop
        }
        catch {
            Write-MapLog -Message "Could not release $letter. $($_.Exception.Message)"
            return
        }
    }

    try {
        $driveParameters = @{
            Name        = $letter
            PSProvider  = 'FileSystem'
            Root        = $SharePath
            Persist     = $true
            Scope       = 'Global'
            ErrorAction = 'Stop'
        }

        $null = New-PSDrive @driveParameters
        Write-MapLog -Message "$letter mapped to $SharePath successfully."
    }
    catch {
        Write-MapLog -Message "Mapping $letter failed. $($_.Exception.Message)"
    }
}
