#requires -Version 5.1
# Definition-only bootstrap, dot-sourced in the caller's scope.
# No window, timer, credential validation, database or network operation here.
# The list is closed: extra scripts beside these files are never auto-loaded.

function Get-DomeniaRuntimeModulePlan {
    @(
        [pscustomobject]@{ File='Domenia-Selection.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaObjectReadIdentity',
            'Get-DomeniaSelectionContext',
            'Test-DomeniaSameSelectionContext',
            'Test-DomeniaSelectionLoadCurrent',
            'Get-DomeniaObjectResultGuid',
            'Assert-DomeniaObjectResultIdentity',
            'Get-DomeniaObjectCacheKey',
            'Update-DomeniaSelectionReadUi',
            'Clear-DomeniaPreloadSelection',
            'Enter-DomeniaSelectionContext',
            'Restore-DomeniaRefusedSelection',
            'Retry-DomeniaSelectedObjectRead',
            'Initialize-DomeniaSelectionPreload'
        ) }
        [pscustomobject]@{ File='Domenia-Embedded.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaEmbeddedHost',
            'Get-DomeniaSurfaceRecord',
            'Register-DomeniaSurfaceReady',
            'Register-DomeniaSurfaceKeys',
            'Get-DomeniaOwningDialog',
            'Set-DomeniaSurfaceResult',
            'Get-DomeniaLogicalControls',
            'Set-DomeniaEmbeddedTheme',
            'Show-DomeniaEmbeddedWindow',
            'Get-DomeniaEmbeddedLookupCode',
            'Complete-DomeniaEmbeddedLookup',
            'Fail-DomeniaEmbeddedLookup',
            'Show-DomeniaInlinePicker',
            'Select-DomeniaRelationsUser',
            'Get-DomeniaEmbeddedContext',
            'New-DomeniaFileRequest',
            'Get-DomeniaEmbeddedPathCode',
            'Complete-DomeniaEmbeddedPath',
            'Fail-DomeniaEmbeddedPath',
            'Show-DomeniaInlineFilePicker'
        ) }
        [pscustomobject]@{ File='Domenia-Relations.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaRelationsState',
            'Set-DomeniaRelationsSelection',
            'Set-DomeniaRelationsGridSelection',
            'Get-DomeniaRelationsSubject',
            'Get-DomeniaRelationsIdentity',
            'Test-DomeniaRelationsCurrent',
            'Get-DomeniaRelationsSelectedLinks',
            'Get-DomeniaRelationsActiveGrid',
            'Update-DomeniaRelationsActions',
            'Refresh-DomeniaRelationViews',
            'Invoke-DomeniaRelationsTick',
            'Save-DomeniaRelationConfirmations',
            'Complete-DomeniaRelationsSearch',
            'Fail-DomeniaRelationsSearch',
            'Start-DomeniaRelationsSearch',
            'Stop-DomeniaRelationsSearch',
            'Use-DomeniaRelationCandidate',
            'Initialize-DomeniaRelationsUi',
            'Start-DomeniaRelationComputerSearch',
            'Test-DomeniaRelationManualState',
            'Complete-DomeniaRelationComputerSearch',
            'Fail-DomeniaRelationComputerSearch',
            'Set-DomeniaRelationPendingAssociation',
            'Request-DomeniaRelationManualAssociation',
            'Cancel-DomeniaRelationAssociation',
            'Confirm-DomeniaRelationAssociation',
            'Complete-DomeniaRelationAssociationVerify',
            'Fail-DomeniaRelationAssociationVerify',
            'Get-DomeniaRelationsWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-UX.UI.ps1'; DotSource=$true; Functions=@(
            'Import-DomeniaUxHelpCatalogue',
            'Get-DomeniaUxHelpEntry',
            'Get-DomeniaUxControlHelpText',
            'Show-DomeniaUxControlHelp',
            'Initialize-DomeniaUxControlHelp',
            'Initialize-DomeniaUxWindowHelp',
            'Restore-DomeniaUxBaseToolTip',
            'Get-DomeniaUxRouteNames',
            'Invoke-DomeniaUxRoute',
            'Sync-DomeniaUxNavigation',
            'Update-DomeniaUxProfileVisibility',
            'Update-DomeniaUxLayout',
            'Switch-DomeniaUxHelp',
            'Switch-DomeniaUxLog',
            'Initialize-DomeniaUxShell',
            'Set-DomeniaUxPalette',
            'ConvertTo-DomeniaUxFlag',
            'Get-DomeniaUxLayoutPlan',
            'Save-DomeniaUxLayoutSettings',
            'Switch-DomeniaUxSidebar',
            'Update-DomeniaUxSidebar',
            'Get-DomeniaUxOuDisplay',
            'Update-DomeniaUxOuScope',
            'Copy-DomeniaUxOuPath',
            'Initialize-DomeniaUxLoginPresentation'
        ) }
        [pscustomobject]@{ File='Domenia-Experience.Model.ps1'; DotSource=$false; Functions=@(
            'ConvertTo-SuiteFlag',
            'ConvertTo-SuiteNumber',
            'ConvertTo-DomeniaExperienceSettings',
            'Get-SuiteDesign',
            'Get-SuitePalette',
            'Test-DomeniaExperienceRow',
            'Test-DomeniaExperienceCanCancel',
            'Get-DomeniaExperienceTaskRow',
            'Find-SuiteLiteralText'
        ) }
        [pscustomobject]@{ File='Domenia-Experience.UI.ps1'; DotSource=$false; Functions=@(
            'Get-DomeniaExperienceVisibleRows',
            'Get-DomeniaExperienceExportRows',
            'Open-DomeniaExperienceActivity',
            'Update-DomeniaExperienceCancelState',
            'Stop-DomeniaExperienceSelectedRead',
            'Update-DomeniaExperienceActivity',
            'Update-DomeniaExperienceIdentity',
            'Apply-DomeniaExperienceDensity',
            'Apply-DomeniaExperienceLogReading',
            'Find-DomeniaExperienceLog',
            'Set-DomeniaExperienceJournalLayout',
            'Save-DomeniaExperiencePreferences',
            'Initialize-DomeniaExperience',
            'Update-DomeniaExperienceCapsLock',
            'Switch-DomeniaExperienceLoginTheme',
            'Initialize-DomeniaExperienceLogin'
        ) }
        [pscustomobject]@{ File='Domenia-Support.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaSupportFieldNames',
            'ConvertTo-DomeniaSupportText',
            'New-DomeniaSupportSnapshot',
            'Get-DomeniaSupportField',
            'Get-DomeniaSupportInt64',
            'New-DomeniaSupportFinding',
            'Get-DomeniaSupportFindings',
            'Compare-DomeniaSupportSnapshots',
            'Get-DomeniaSupportIncidentRules',
            'Get-DomeniaSupportIncidentHints',
            'New-DomeniaSupportIncident',
            'Add-DomeniaSupportBoundedItem',
            'Test-DomeniaSupportLiteralMatch',
            'New-DomeniaSupportReport',
            'ConvertTo-DomeniaSupportHtml'
        ) }
        [pscustomobject]@{ File='Domenia-Support.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaSupportSessionKey',
            'Reset-DomeniaSupportSession',
            'Sync-DomeniaSupportSession',
            'Set-DomeniaSupportObjectSource',
            'Add-DomeniaSupportIncidentFromLog',
            'Get-DomeniaSupportCurrentSnapshot',
            'Update-DomeniaSupportAnalysis',
            'Update-DomeniaSupportComparison',
            'Set-DomeniaSupportCapture',
            'Add-DomeniaSupportPin',
            'Open-DomeniaSupportPin',
            'Update-DomeniaSupportIncidents',
            'Update-DomeniaSupportView',
            'New-DomeniaSupportUiReport',
            'Export-DomeniaSupportHtml',
            'Stop-DomeniaSupportUi',
            'Initialize-DomeniaSupportUi'
        ) }
        [pscustomobject]@{ File='Domenia-Live.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLiveHash',
            'Get-DomeniaLiveField',
            'Set-DomeniaLiveRowValue',
            'New-DomeniaLiveResultRow',
            'ConvertTo-DomeniaLiveSnapshot',
            'Get-DomeniaLiveObjectKey',
            'ConvertTo-DomeniaLiveObservation',
            'Get-DomeniaLiveObservationView',
            'Test-DomeniaLiveIdentity',
            'Get-DomeniaLivePresenceView',
            'Test-DomeniaPresenceMatch',
            'Get-DomeniaLiveProbeCode',
            'Get-DomeniaLiveCacheCode'
        ) }
        [pscustomobject]@{ File='Domenia-Live.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLiveIdentitySignal',
            'Initialize-DomeniaLive',
            'Reset-DomeniaLiveIdentity',
            'Stop-DomeniaLiveSearch',
            'Stop-DomeniaLiveProbes',
            'Stop-DomeniaLive',
            'Test-DomeniaLiveSearchActive',
            'Begin-DomeniaLiveSearch',
            'Complete-DomeniaLiveSearch',
            'Fail-DomeniaLiveSearch',
            'Stop-DomeniaLiveJob',
            'Update-DomeniaLiveFilter',
            'Set-DomeniaLiveObservationOnRow',
            'Add-DomeniaLiveRow',
            'Clear-DomeniaLiveProbeIntent',
            'Test-DomeniaLiveProbeIntent',
            'Select-DomeniaLiveResult',
            'Request-DomeniaLiveProbe',
            'Request-DomeniaLiveSelectedProbe',
            'Request-DomeniaLiveRecheck',
            'Merge-DomeniaLiveLinkMemory',
            'Complete-DomeniaLivePresence',
            'Complete-DomeniaLiveProbe',
            'Fail-DomeniaLiveProbe',
            'Complete-DomeniaLiveCache',
            'Fail-DomeniaLiveCache',
            'Get-DomeniaLiveWorkerCount',
            'Get-DomeniaLiveDatabasePath',
            'Start-DomeniaLiveBackgroundWork',
            'Invoke-DomeniaLiveTick'
        ) }
        [pscustomobject]@{ File='Domenia-Access.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaAccessFailureKind',
            'Get-DomeniaAccessScope',
            'Get-DomeniaRetryCredential',
            'Set-DomeniaRetryWorkerContext',
            'Test-DomeniaSecretDenied',
            'Set-DomeniaSecretDenied',
            'Test-DomeniaAccessBusyWrite',
            'Request-DomeniaAccessRecovery',
            'Update-DomeniaAccessButton',
            'Test-DomeniaAccessSessionCurrent',
            'Show-DomeniaAlternateCredential',
            'Invoke-DomeniaAccessRecovery',
            'Initialize-DomeniaAccess',
            'Inspect-DomeniaAccessResult'
        ) }
        [pscustomobject]@{ File='Domenia-Continuity.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaStateMap',
            'ConvertTo-DomeniaColumnLayout',
            'ConvertTo-DomeniaTreeBookmark',
            'Get-DomeniaChangeWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-Continuity.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaGridColumnKey',
            'Register-DomeniaGridLayout',
            'Save-DomeniaGridLayout',
            'Get-DomeniaTreeContextKey',
            'Get-DomeniaRealizedTreeNodes',
            'Save-DomeniaTreeBookmark',
            'Start-DomeniaTreeBookmarkRestore',
            'Invoke-DomeniaTreeBookmarkRestore',
            'Invoke-DomeniaRestoredOuSearch',
            'Complete-DomeniaObjectChanges',
            'Fail-DomeniaObjectChanges',
            'Invoke-DomeniaObjectChanges',
            'Initialize-DomeniaContinuity'
        ) }
        [pscustomobject]@{ File='Domenia-Guard.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStructuredError',
            'Get-DomeniaLinkFingerprint',
            'ConvertTo-DomeniaLinkRecord',
            'Get-DomeniaDraftFieldMap',
            'ConvertTo-DomeniaSavedSearch',
            'Get-DomeniaPercentile'
        ) }
        [pscustomobject]@{ File='Domenia-Accounts.Async.ps1'; DotSource=$true; Functions=@(
            'Start-DomeniaAccountValidation',
            'Complete-DomeniaAccountValidation',
            'Stop-DomeniaAccountValidation'
        ) }
        [pscustomobject]@{ File='Domenia-Storage.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStorageWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-Storage.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaPersistence',
            'Add-DomeniaIndexPersistence',
            'Reset-DomeniaLinkBaseline',
            'Queue-DomeniaLinkChanges',
            'Start-DomeniaStorageWork',
            'Complete-DomeniaStorageWork',
            'Fail-DomeniaStorageWork',
            'Queue-DomeniaMetadata'
        ) }
        [pscustomobject]@{ File='Domenia-Receipts.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaReceiptsCommon',
            'Get-DomeniaReceiptWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-Sessions.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaSessionsWorkerCode',
            'Get-DomeniaSelectedMachineName',
            'Start-DomeniaSessionsRead',
            'Complete-DomeniaSessionsRead',
            'Fail-DomeniaSessionsRead',
            'Get-DomeniaRemoteCredentialCheckCode',
            'Start-DomeniaRemoteCredentialSession',
            'Set-DomeniaTargetCredentialContext'
        ) }
        [pscustomobject]@{ File='Domenia-Dossier.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaStoredCapture',
            'Get-DomeniaDocumentWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-Dossier.UI.ps1'; DotSource=$true; Functions=@(
            'Start-DomeniaDocumentTask',
            'Complete-DomeniaDocumentTask',
            'Fail-DomeniaDocumentTask',
            'Use-DomeniaCaptureFile',
            'Export-DomeniaTechnicalDossier'
        ) }
        [pscustomobject]@{ File='Domenia-Reconcile.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaReconcileWorkerCode',
            'Complete-DomeniaReconcile',
            'Fail-DomeniaReconcile',
            'Invoke-DomeniaReconcileTick',
            'Initialize-DomeniaReconcile'
        ) }
        [pscustomobject]@{ File='Domenia-Guard.UI.ps1'; DotSource=$true; Functions=@(
            'Show-DomeniaGuard',
            'Start-DomeniaReceiptRefresh',
            'Complete-DomeniaReceiptRefresh',
            'Fail-DomeniaReceiptRefresh',
            'Invoke-DomeniaReceiptChoice',
            'Save-DomeniaDraftBaseline',
            'Get-DomeniaDirtyFields',
            'Test-DomeniaDraftNavigation',
            'Keep-DomeniaDraftOnResult',
            'Show-DomeniaDraftComparison',
            'Set-DomeniaArtifactConsent',
            'Get-DomeniaFavouriteSearches',
            'Save-DomeniaFavouriteSearch',
            'Load-DomeniaFavouriteSearch',
            'Open-DomeniaSuiteTool',
            'Initialize-DomeniaGuard',
            'Set-DomeniaProtectedClipboard',
            'Remove-DomeniaFavouriteSearch',
            'Resume-DomeniaStorage',
            'Show-DomeniaUnavailableReasons'
        ) }
    )
}

function Assert-DomeniaRuntimeImports {
    [CmdletBinding()]
    param([string]$ModuleRoot = (Join-Path $PSScriptRoot 'modules'))
    foreach ($module in @(Get-DomeniaRuntimeModulePlan)) {
        $expected = [IO.Path]::GetFullPath((Join-Path $ModuleRoot $module.File))
        foreach ($name in @($module.Functions)) {
            # Function: avoids command auto-loading and aliases. Check origin too:
            # an older function in a parent scope must not mask an omitted import.
            $command = Get-Item -LiteralPath ('Function:\' + $name) -ErrorAction SilentlyContinue
            if ($null -eq $command -or -not $command.ScriptBlock.File) {
                throw [InvalidOperationException]::new(
                    "DOMENIA_MODULE_EXPORT : $($module.File) n'a pas fourni la fonction $name.")
            }
            $actual = [IO.Path]::GetFullPath([string]$command.ScriptBlock.File)
            if (-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) {
                throw [InvalidOperationException]::new(
                    "DOMENIA_MODULE_ORIGIN : la fonction $name ne provient pas de $($module.File).")
            }
        }
        [pscustomobject]@{File=[string]$module.File;Functions=@($module.Functions).Count;Validated=$true}
    }
}

$domeniaImportRoot = Join-Path $PSScriptRoot 'modules'
$domeniaImportPlan = @(Get-DomeniaRuntimeModulePlan)
$domeniaImportErrorAction = $ErrorActionPreference
$script:DomeniaRuntimeImports = @()
try {
    $ErrorActionPreference = 'Stop'
    # Check the entire declared set before importing the first module.
    foreach ($domeniaModule in $domeniaImportPlan) {
        $domeniaModulePath = Join-Path $domeniaImportRoot $domeniaModule.File
        if (-not [IO.File]::Exists($domeniaModulePath)) {
            throw [IO.FileNotFoundException]::new(
                "DOMENIA_MODULE_MISSING : $($domeniaModule.File). Reinstallez le paquet complet.",
                $domeniaModulePath)
        }
        $domeniaTokens=$null; $domeniaParseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $domeniaModulePath,[ref]$domeniaTokens,[ref]$domeniaParseErrors)
        if (@($domeniaParseErrors).Count -gt 0) {
            $domeniaFirstError=@($domeniaParseErrors)[0]
            throw [InvalidOperationException]::new(
                "DOMENIA_MODULE_PARSE : $($domeniaModule.File), ligne $($domeniaFirstError.Extent.StartLineNumber) : $($domeniaFirstError.Message)")
        }
    }
    foreach ($domeniaModule in $domeniaImportPlan) {
        # Experience is already dot-sourced by UX. Validate it without importing
        # it a second time and resetting its state.
        if (-not $domeniaModule.DotSource) { continue }
        $domeniaModulePath=Join-Path $domeniaImportRoot $domeniaModule.File
        try {
            . $domeniaModulePath
        }
        catch {
            throw [InvalidOperationException]::new(
                "DOMENIA_MODULE_IMPORT : echec de $($domeniaModule.File). $($_.Exception.Message)",
                $_.Exception)
        }
    }
    $script:DomeniaRuntimeImports = @(Assert-DomeniaRuntimeImports -ModuleRoot $domeniaImportRoot)
}
finally {
    $ErrorActionPreference = $domeniaImportErrorAction
}
