ITWorks - system_admin

PowerShell module for configuring and administering a Windows Server 2022 domain controller for Mick and Macks Pies.

Written for ITWorks as part of TAFE SA unit ICTNWK428 Create scripts for networking, Assessment 2.

Purpose

Mick and Macks Pies lost its systems administrator and is left with an office manager who has limited Windows Server experience. This module reduces each common administration task to a single command, run from the office workstation and executed on the server over PowerShell remoting.

Every action is written to an activity log on the server at C:\myLogs\logs.txt.

Files
File	Purpose
system_admin.psm1	The administration functions.
ExecuteOnServer.psm1	Remoting helper. Opens the session and ships code to the server.
ous.csv	Organizational Units to create.
users.example.csv	Template for the staff import. The real users.csv is not tracked.
map_share.ps1	Logon script deployed by Group Policy to map drive S.

Passwords are not held in any CSV. Add-DomainUser prompts once for an initial password and sets every new account to require a change at first sign in.

Requirements
Windows 11 client and Windows Server 2022 target
PowerShell 5.1 or later
PowerShell remoting enabled on the server
Execution policy set to RemoteSigned on the client
Usage
powershell
Set-Location C:\ITWorks\system-admin
Import-Module .\ExecuteOnServer.psm1 -Force
Import-Module .\system_admin.psm1 -Force

Test-ServerConnection -ComputerName 10.1.1.10 -Verbose
Functions
Function	Status
Write-LogEntry	Complete
Test-ServerConnection	Complete
New-DomainController	Complete
New-ServerSession	Complete (in ExecuteOnServer.psm1)
Join-ComputerToDomain	Complete
Connect-DomainComputer	Complete
Add-OrganizationalUnit	Complete
Add-DomainUser	Complete
New-DhcpScope	Complete
Get-TopTenError	Complete
Register-DiskCleanupTask	Complete
map_share.ps1 (Group Policy)	Complete
Standards

Code follows ITWorks_PowerShell_Coding_Standards: four-space indentation, One True Brace Style, lines under 115 characters, approved PowerShell verbs, PascalCase function names, camelCase private variables, and comment-based help on every function.

Author

Cooper Lane, ITWorks
