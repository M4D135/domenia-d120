#requires -Version 5.1
<# DEV entry point kept for the documented command lines. The installer itself ships in PROD and DEV as
   wad\Support\INSTALLER-MISE-A-JOUR.ps1 (FI-06); this file only forwards the same parameters to it.
   Examples :
     .\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia' -WhatIf
     .\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
     .\INSTALLER-MISE-A-JOUR.ps1 -Install -Destination 'C:\Domenia'
     .\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination 'C:\Domenia'
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium',DefaultParameterSetName='Update')]
param(
    [Parameter(Mandatory,ParameterSetName='Update')]
    [Parameter(Mandatory,ParameterSetName='Install')]
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')]
    [string]$Destination,
    [Parameter(Mandatory,ParameterSetName='Install')][switch]$Install,
    [Parameter(Mandatory,ParameterSetName='Restore')][string]$RestoreBackup,
    [Parameter(Mandatory,ParameterSetName='RestoreLatest')][switch]$RestoreLatest,
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$Package='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][string]$QualificationReport='',
    [Parameter(ParameterSetName='Update')][Parameter(ParameterSetName='Install')][switch]$RequireQualification,
    [Parameter(ParameterSetName='Install')][ValidateSet('Demander','Oui','Non')][string]$Shortcuts='Demander'
)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'wad\Support\INSTALLER-MISE-A-JOUR.ps1') @PSBoundParameters
