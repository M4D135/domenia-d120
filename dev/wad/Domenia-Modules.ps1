#requires -Version 5.1
# Definition-only bootstrap, dot-sourced in the caller's scope.
# No window, timer, credential validation, database or network operation here.
# The list is closed: extra scripts beside these files are never auto-loaded.

function Get-DomeniaRuntimeModulePlan {
    @(
        [pscustomobject]@{ Phase='Bootstrap'; Requires=@(); File='Domenia-CredentialVault.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaCredentialVaultTarget',
            'Initialize-DomeniaCredentialVault',
            'Get-DomeniaCredentialVaultCredential',
            'Save-DomeniaCredentialVaultCredential',
            'Remove-DomeniaCredentialVaultCredential'
        ) }
        # D011: pure rule modules first. Phase and Requires are validated by Test-DomeniaStartupPlan
        # (Domenia-Engine.Model.ps1) before any module of the Modules phase is imported.
        [pscustomobject]@{ Phase='Bootstrap'; Requires=@(); File='Domenia-Common.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaMember',
            'Get-DomeniaMemberValue',
            'Test-DomeniaDictionaryKey',
            'Get-DomeniaCollectionItems',
            'ConvertFrom-DomeniaLargeInteger',
            'Test-DomeniaGuidText',
            'ConvertTo-DomeniaGuidText',
            'ConvertTo-DomeniaSidText',
            'Get-DomeniaTextHash',
            'ConvertTo-DomeniaUtcDate',
            'Get-DomeniaFeatureFlag',
            'New-DomeniaFact',
            'ConvertTo-DomeniaFlatText',
            'Split-DomeniaRawDn',
            'Get-DomeniaRawDnParent',
            'ConvertFrom-DomeniaDnLabel',
            'Get-DomeniaDnSite',
            'Add-DomeniaSwallowedEntry',
            'Get-DomeniaSwallowedEntries'
        ) }
        [pscustomobject]@{ Phase='Bootstrap'; Requires=@('Domenia-Common.Model.ps1'); File='Domenia-Engine.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStartupPhases',
            'Get-DomeniaFunctionProviderMap',
            'Test-DomeniaStartupPlan',
            'Test-DomeniaPhaseCall',
            'New-DomeniaSelectionIdentity',
            'Test-DomeniaIdentityCurrent',
            'Get-DomeniaTaskClass',
            'Get-DomeniaTaskPriority',
            'Get-DomeniaPayloadDigest',
            'Get-DomeniaTaskDedupKey',
            'Test-DomeniaTaskAdmission',
            'Select-DomeniaNextQueuedTask',
            'Test-DomeniaForegroundTaskClass',
            'Get-DomeniaTaskOrder',
            'Test-DomeniaPulseDue',
            'Get-DomeniaPulseDelay',
            'Get-DomeniaTaskState',
            'Get-DomeniaTaskStateSummary',
            'Get-DomeniaCancelStatusText',
            'Get-DomeniaOperationProvider',
            'Get-DomeniaOperationCredentialNeeds',
            'ConvertTo-DomeniaProviderOutcome',
            'Test-DomeniaQueuedTaskExpired',
            'Get-DomeniaIsolationDecision',
            'Get-DomeniaProviderBudget',
            'New-DomeniaProviderState',
            'Get-DomeniaProviderStateKey',
            'Register-DomeniaProviderOutcome',
            'Reset-DomeniaProviderState',
            'Test-DomeniaProviderAdmission',
            'Test-DomeniaAutoRetryAllowed',
            'New-DomeniaResourceRegistry',
            'Register-DomeniaResource',
            'Release-DomeniaResources',
            'Get-DomeniaResourceSummary',
            'Get-DomeniaIdlePolicy',
            'Get-DomeniaIdleActivityForSource',
            'Test-DomeniaIdleAllows',
            'Get-DomeniaReadTimeoutState'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1'); File='Domenia-Cache.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaProjection',
            'Test-DomeniaProjectionMinimal',
            'Get-DomeniaRowUpdatePlan',
            'New-DomeniaPageBuffer',
            'Add-DomeniaPageRows',
            'Get-DomeniaDataNatures',
            'Get-DomeniaFreshnessPolicy',
            'Get-DomeniaFreshness',
            'Get-DomeniaObservationTimes',
            'Copy-DomeniaObservationTimes',
            'Set-DomeniaObservationTime',
            'Get-DomeniaRecordFreshness',
            'Get-DomeniaCacheKey',
            'Test-DomeniaCacheEntryValid',
            'Resolve-DomeniaIncrementalSync',
            'New-DomeniaNegativeCache',
            'Get-DomeniaNegativeTtlSeconds',
            'Register-DomeniaFailure',
            'Clear-DomeniaFailure',
            'Test-DomeniaNegativeCache',
            'New-DomeniaWriteQueue',
            'Add-DomeniaWriteRequest',
            'Get-DomeniaWriteBatch',
            'Resolve-DomeniaWriteConflict',
            'Get-DomeniaPersistenceLabel',
            'Get-DomeniaRetentionPolicy',
            'Format-DomeniaSize',
            'Get-DomeniaPurgeTargets',
            'Get-DomeniaPurgePlan',
            'Resolve-DomeniaDirectoryReachability',
            'Get-DomeniaCacheReadPolicy',
            'Get-DomeniaCacheCatalogRows',
            'Test-DomeniaProtectedAssociationSource'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1'); File='Domenia-Search.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaLdapLiteral',
            'Split-DomeniaSearchWords',
            'Get-DomeniaTypeFilter',
            'ConvertFrom-DomeniaSearchSyntax',
            'Get-DomeniaWordFilter',
            'ConvertTo-DomeniaSearchFilter',
            'New-DomeniaGlobalSearchRequest',
            'Test-DomeniaGlobalSearchRequest',
            'New-DomeniaSearchState',
            'Set-DomeniaBrowseOu',
            'Get-DomeniaScopeLabel',
            'Get-DomeniaGlobalSearchPlan',
            'Get-DomeniaFavouriteName',
            'Get-DomeniaSearchRank',
            'Test-DomeniaAdminAccountRow',
            'Sort-DomeniaSearchResults',
            'ConvertTo-DomeniaGuidFilterValue',
            'Get-DomeniaPastedIdentifier',
            'Get-DomeniaResultCounterText',
            'Get-DomeniaContinuationDecision',
            'New-DomeniaContinuation',
            'Test-DomeniaContinuationCurrent',
            'ConvertTo-DomeniaLdapTime',
            'Get-DomeniaWorkViews',
            'Get-DomeniaWorkViewPlan',
            'Get-DomeniaSearchQueryCatalog',
            'Find-DomeniaSearchQuery',
            'ConvertTo-DomeniaSearchQueryRows',
            'ConvertTo-DomeniaSavedView',
            'Split-DomeniaDn',
            'ConvertFrom-DomeniaDnValue',
            'Get-DomeniaDnParent',
            'Get-DomeniaOuDisplayPath',
            'Resolve-DomeniaOuRestore',
            'New-DomeniaNavHistory',
            'Get-DomeniaNavStateKey',
            'Push-DomeniaNavState',
            'Step-DomeniaNavHistory',
            'Get-DomeniaSystemContainerNames',
            'Test-DomeniaSystemContainer',
            'Split-DomeniaTreeRows',
            'Get-DomeniaTreeSelectionDelay',
            'Test-DomeniaOuTreeMatch',
            'ConvertTo-DomeniaOuFavourite',
            'Get-DomeniaDnDomainKey',
            'Import-DomeniaOuFavourites',
            'Set-DomeniaOuFavouriteState'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1'); File='Domenia-Relations.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaRelationDirection',
            'ConvertTo-DomeniaRelationType',
            'Test-DomeniaSameSubject',
            'Test-DomeniaRelationConfirmation',
            'Resolve-DomeniaRelationSubjectChange',
            'Get-DomeniaRelationKind',
            'ConvertTo-DomeniaRelationLoginKey',
            'ConvertTo-DomeniaRelationComputerKey',
            'Get-DomeniaRelationKey',
            'Test-DomeniaSameRelation',
            'Resolve-DomeniaRelationUpsert',
            'ConvertTo-DomeniaRelationUtcDate',
            'Get-DomeniaRelationWhenTicks',
            'ConvertTo-DomeniaRelationWhenText',
            'Format-DomeniaRelationWhen',
            'Get-DomeniaRelationWhenSortKey',
            'Select-DomeniaPrimaryRelation',
            'Resolve-DomeniaRelationStoragePlacement',
            'Get-DomeniaRelationStorageKey',
            'Get-DomeniaEvidenceKind',
            'Get-DomeniaEvidenceLabel',
            'Get-DomeniaEvidenceBadge',
            'Step-DomeniaAssociationState',
            'Get-DomeniaAssociationRefusal',
            'Merge-DomeniaRelationCandidates',
            'Get-DomeniaDetectionScopePlan',
            'Test-DomeniaDetectionMatchesPlan',
            'Test-DomeniaDetectionWithinPlan',
            'Test-DomeniaProbeAllowed',
            'New-DomeniaDetectionCounters',
            'Add-DomeniaDetectionOutcome',
            'ConvertTo-DomeniaDetectionOutcome',
            'Get-DomeniaDetectionCounterText',
            'ConvertTo-DomeniaAccountIdentity',
            'Test-DomeniaAccountIdentityMatch',
            'New-DomeniaLinkHistoryEntry',
            'Get-DomeniaLinkRestoreCandidate',
            'Get-DomeniaLinkConflicts',
            'Get-DomeniaRelationRestoreLabel',
            'Get-DomeniaOrphanReason',
            'Test-DomeniaRelationMatchesFilter',
            'ConvertFrom-DomeniaLinkCsvRow',
            'Get-DomeniaLinkImportStatus',
            'New-DomeniaImportedRelation'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Relations.Model.ps1'); File='Domenia-Access.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaOperationResource',
            'ConvertTo-DomeniaMachineKey',
            'Test-DomeniaLocalAccountName',
            'Get-DomeniaCredentialScope',
            'Test-DomeniaCredentialContext',
            'Set-DomeniaScopeAccount',
            'Get-DomeniaErrorDecision',
            'New-DomeniaDenialCoalescer',
            'Add-DomeniaAccessDenial',
            'Complete-DomeniaAccessPrompt',
            'Get-DomeniaReauthPlan',
            'New-DomeniaCredentialLease',
            'Test-DomeniaCredentialLease',
            'Use-DomeniaCredentialLease',
            'Clear-DomeniaCredentialLease',
            'Get-DomeniaOperationAuthNeed',
            'Get-DomeniaCapabilityExplanation',
            'ConvertTo-DomeniaLapsView',
            'ConvertTo-DomeniaBitLockerKeyList',
            'Find-DomeniaBitLockerKey',
            'ConvertTo-DomeniaBitLockerKeyBlocks',
            'Get-DomeniaSecretColumnHeader',
            'Test-DomeniaDirectChildDn',
            'Test-DomeniaSecretRevealAllowed',
            'Get-DomeniaSecretExposurePolicy',
            'Get-DomeniaSecretRevealCountdown',
            'Get-DomeniaSecretActionView',
            'Protect-DomeniaSecretText',
            'Test-DomeniaTextHasSecret',
            'Select-DomeniaAllowedFields',
            'Get-DomeniaTransportPolicy',
            'Test-DomeniaTransportFallbackAllowed',
            'Test-DomeniaTransportCodeSafety'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1'); File='Domenia-Directory.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaAttr',
            'Get-DomeniaAttrAll',
            'ConvertTo-DomeniaAdInt64',
            'ConvertTo-DomeniaAdDate',
            'Get-DomeniaAdIntervalState',
            'ConvertFrom-DomeniaAdInterval',
            'Get-DomeniaCnFromDn',
            'Get-DomeniaAccountState',
            'Get-DomeniaUserSupportSummary',
            'Resolve-DomeniaPasswordPolicy',
            'Get-DomeniaLockoutDiagnosis',
            'ConvertTo-DomeniaLockoutUtc',
            'Get-DomeniaLockoutTimeline',
            'Get-DomeniaPrimaryGroupSid',
            'Find-DomeniaMembershipPath',
            'Resolve-DomeniaMembershipAnswer',
            'Test-DomeniaPrivilegedGroup',
            'Compare-DomeniaUserAccess',
            'New-DomeniaGroupDelta',
            'Test-DomeniaGroupDeltaPostcondition',
            'ConvertTo-DomeniaAceView',
            'New-DomeniaLifecyclePlan',
            'Set-DomeniaLifecycleStep',
            'Get-DomeniaLifecycleNextStep',
            'Find-DomeniaDirectoryInconsistencies',
            'ConvertFrom-DomeniaReplMetadata',
            'Compare-DomeniaDcReadings'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1'); File='Domenia-Workstation.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaWorkstationFactState',
            'Test-DomeniaWorkstationMember',
            'Test-DomeniaWorkstationListMember',
            'Test-DomeniaWorkstationPartialStatus',
            'Test-DomeniaWorkstationNotRequested',
            'ConvertTo-DomeniaWorkstationBool',
            'Get-DomeniaWorkstationShortName',
            'ConvertTo-DomeniaWorkstationNumber',
            'Get-DomeniaWorkstationNumberText',
            'Get-DomeniaWorkstationDurationText',
            'Get-DomeniaDiagStatusLabel',
            'Get-DomeniaDiagSeverity',
            'ConvertTo-DomeniaDiagVerdict',
            'ConvertTo-DomeniaSoftwareFromInventory',
            'Get-DomeniaSoftwareColumnVisibility',
            'Get-DomeniaSoftwareAccessSummary',
            'Get-DomeniaInventoryMapText',
            'Get-DomeniaInventoryValueText',
            'Get-DomeniaQuickDiagPlan',
            'Test-DomeniaQuickDiagAllowed',
            'ConvertTo-DomeniaQuickDiagFacts',
            'Get-DomeniaSessionEmptyText',
            'Get-DomeniaSessionIdleText',
            'Get-DomeniaSessionOpenedText',
            'Get-DomeniaSessionAccountName',
            'ConvertTo-DomeniaSessionView',
            'Get-DomeniaMsiProviderClassNames',
            'Test-DomeniaMsiProviderClass',
            'Get-DomeniaSoftwareSources',
            'ConvertFrom-DomeniaSoftwareAccess',
            'Test-DomeniaInventoryGuardNode',
            'Get-DomeniaInventoryCodeFindings',
            'Test-DomeniaInventoryCodeSafe',
            'Get-DomeniaEventPresets',
            'New-DomeniaEventQuery',
            'ConvertTo-DomeniaEventFacts',
            'ConvertFrom-DomeniaGpLink',
            'Get-DomeniaRsopGpoGuid',
            'Get-DomeniaRsopGpoOutcome',
            'Resolve-DomeniaGpoView',
            'ConvertFrom-DomeniaDsregStatus',
            'Get-DomeniaDsregValue',
            'Test-DomeniaDsregAccountMatch',
            'Get-DomeniaJoinStateFacts',
            'ConvertTo-DomeniaUpdateFacts',
            'Test-DomeniaMachineIdentityCoherence',
            'Select-DomeniaRelationsForMachine',
            'Test-DomeniaMacAddress',
            'New-DomeniaWakePacket',
            'ConvertTo-DomeniaWakeIpv4Number',
            'ConvertFrom-DomeniaWakeIpv4Number',
            'ConvertTo-DomeniaWakeIpv4Prefix',
            'Get-DomeniaBroadcastAddress',
            'Test-DomeniaWakeIpv4InNetwork',
            'Test-DomeniaWakeAllowed',
            'Get-DomeniaWakeState',
            'Get-DomeniaSuiteContextFields',
            'Get-DomeniaSuiteMemberNames',
            'Test-DomeniaSuiteContract',
            'Get-DomeniaSuiteLaunchPlan',
            'Get-DomeniaWorkstationNoiseRules',
            'Get-DomeniaSystemEventLevel',
            'Test-DomeniaServiceStopExpected'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1'); File='Domenia-Shell.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaShellFirstValue',
            'ConvertTo-DomeniaShellValueText',
            'ConvertTo-DomeniaShellRect',
            'Get-DomeniaShellPages',
            'Test-DomeniaSelectorAllowed',
            'Get-DomeniaPageTitle',
            'Get-DomeniaCounterText',
            'Get-DomeniaActivityStripSlots',
            'Compare-DomeniaReservedSlots',
            'Get-DomeniaReservedLayout',
            'New-DomeniaInlineRequest',
            'Resolve-DomeniaInlineRequest',
            'Test-DomeniaInlineRequestBlocks',
            'Test-DomeniaInlineCodeSafe',
            'Get-DomeniaResultColumns',
            'Get-DomeniaResultProfileLabels',
            'Resolve-DomeniaColumnPreferences',
            'Test-DomeniaProfileChangeAllowed',
            'Get-DomeniaSelectionPreview',
            'ConvertTo-DomeniaPreviewLoadState',
            'ConvertTo-DomeniaSelectionPreviewText',
            'Test-DomeniaShellSensitiveOption',
            'Get-DomeniaOperationSummary',
            'Test-DomeniaNoAbsenceClaim',
            'Get-DomeniaEmptyState',
            'Resolve-DomeniaSearchEmptyKind',
            'Get-DomeniaDisabledHelpDetails',
            'Get-DomeniaDisabledHelp',
            'Get-DomeniaMissingDisabledHelp',
            'Get-DomeniaActivationDecision',
            'ConvertFrom-DomeniaHexColor',
            'Get-DomeniaRelativeLuminance',
            'Get-DomeniaContrastRatio',
            'Test-DomeniaPaletteContrast',
            'Get-DomeniaSuiteContrastPairs',
            'Get-DomeniaBootContrastPairs',
            'Get-DomeniaBoundedWindowRect',
            'Get-DomeniaStatusGlyph',
            'Get-DomeniaReadOnlyReturnPlan',
            'Get-DomeniaThemeToggleIcon',
            'Get-DomeniaSessionBadge',
            'ConvertFrom-DomeniaRecentJson',
            'Add-DomeniaRecentEntry',
            'Select-DomeniaRecentEntries',
            'Get-DomeniaSearchSuggestionItems',
            'Get-DomeniaExpertTabDecision'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Access.Model.ps1','Domenia-Directory.Model.ps1'); File='Domenia-Safety.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaOperationEffect',
            'Test-DomeniaSecretAttribute',
            'Test-DomeniaMemberPresent',
            'ConvertTo-DomeniaDnKey',
            'Resolve-DomeniaTargetKeys',
            'Test-DomeniaDnValuedAttribute',
            'ConvertTo-DomeniaComparableValue',
            'Get-DomeniaNamedValues',
            'ConvertTo-DomeniaPlanChanges',
            'New-DomeniaInterventionPlan',
            'Test-DomeniaPlanHasSecret',
            'Get-DomeniaPlanSecretLimit',
            'Test-DomeniaPlanStillValid',
            'Get-DomeniaPostconditionRule',
            'Resolve-DomeniaPostcondition',
            'Get-DomeniaReceiptRequirement',
            'Get-DomeniaReceiptResumeState',
            'Get-DomeniaOperationDisplayName',
            'Get-DomeniaReceiptStageView',
            'Get-DomeniaReceiptView',
            'Get-DomeniaReceiptSummary',
            'Test-DomeniaReceiptReviewReason',
            'Get-DomeniaReceiptActionView',
            'ConvertTo-DomeniaReceiptRecord',
            'New-DomeniaWriteRegistry',
            'Test-DomeniaWriteAdmission',
            'Set-DomeniaWriteOutcome',
            'Get-DomeniaAtomicStrategy',
            'Test-DomeniaPreconditionCurrent',
            'Resolve-DomeniaConditionalWrite',
            'Get-DomeniaLockClass',
            'New-DomeniaOperationLock',
            'Get-DomeniaReceiptLocks',
            'Test-DomeniaOperationAllowed',
            'Get-DomeniaCompensation',
            'Test-DomeniaRawAttributeAllowed',
            'ConvertTo-DomeniaDnDisplayName',
            'Test-DomeniaWriteTargetDn',
            'Get-DomeniaPlanChangeText'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Access.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Support.Model.ps1'); File='Domenia-Insight.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaInsightText',
            'Test-DomeniaInsightPseudonymKey',
            'Get-DomeniaInsightKeyedHash',
            'ConvertTo-DomeniaInsightOutcomeText',
            'ConvertTo-DomeniaPseudonym',
            'ConvertTo-DomeniaInsightStepStatus',
            'ConvertTo-DomeniaInsightSubjectKind',
            'ConvertTo-DomeniaInsightMaskedNames',
            'New-DomeniaTicketReport'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1'); File='Domenia-Release.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaSha256Text',
            'Test-DomeniaReleaseRelativePath',
            'Join-DomeniaReleasePath',
            'Test-DomeniaReleaseMapKey',
            'Get-DomeniaReleaseMapValue',
            'ConvertTo-DomeniaReleaseCanonicalText',
            'Get-DomeniaWorkerRegistryFingerprint',
            'ConvertFrom-DomeniaBuildLabel',
            'Get-DomeniaBuildLabelTokens',
            'Test-DomeniaReleaseContract',
            'Get-DomeniaReleaseIdentity',
            'Test-DomeniaReleaseConsistency',
            'Test-DomeniaProdLayout',
            'Compare-DomeniaRebuildManifest',
            'ConvertTo-DomeniaMigrationDomain',
            'ConvertTo-DomeniaMigrationComputerKey',
            'ConvertTo-DomeniaMigrationUserLogin',
            'Get-DomeniaMigrationPlan',
            'Get-DomeniaMigratedState',
            'Test-DomeniaMigrationIdempotent',
            'Get-DomeniaInstallPlan',
            'Get-DomeniaInstallTimeline',
            'Test-DomeniaLaunchSet',
            'Resolve-DomeniaInstallInterruption',
            'ConvertFrom-DomeniaSchemaLabel',
            'Test-DomeniaSchemaStepSafety',
            'Test-DomeniaSchemaCompatibility',
            'Get-DomeniaSchemaRestorePlan',
            'ConvertTo-DomeniaPublisherPin',
            'Test-DomeniaSignerTrust',
            'Get-DomeniaSignatureVerdict',
            'Get-DomeniaComponentInventory',
            'Get-DomeniaStorageLayout',
            'Get-DomeniaPreferenceMigrationPlan',
            'Get-DomeniaSuiteKitManifest',
            'Test-DomeniaSuiteKitDiffusion',
            'ConvertTo-DomeniaConnectorEndpoint',
            'Get-DomeniaConnectorCatalog',
            'Test-DomeniaConnectorAvailable',
            'Get-DomeniaSourceReadPlan',
            'ConvertFrom-DomeniaWaptHost'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Shell.Model.ps1'); File='Domenia-Selection.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaObjectReadIdentity',
            'Get-DomeniaRowSelectionIdentity',
            'Get-DomeniaSelectionContext',
            'Test-DomeniaSameSelectionContext',
            'Get-DomeniaCurrentSelectionIdentity',
            'Test-DomeniaSelectionLoadCurrent',
            'Get-DomeniaObjectResultGuid',
            'Assert-DomeniaObjectResultIdentity',
            'Get-DomeniaObjectCacheKey',
            'Get-DomeniaSelectionCachePolicy',
            'Update-DomeniaSelectionReadUi',
            'Clear-DomeniaPreloadSelection',
            'Clear-DomeniaSelectionEverywhere',
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
            'Get-DomeniaBannerPlan',
            'New-DomeniaBannerButton',
            'Show-DomeniaBanner',
            'Update-DomeniaBannerOccurrence',
            'Close-DomeniaBanner',
            'Get-DomeniaBannerSupportText',
            'Invoke-DomeniaBannerCommand',
            'Get-DomeniaEmbeddedLookupCode',
            'Complete-DomeniaEmbeddedLookup',
            'Fail-DomeniaEmbeddedLookup',
            'New-DomeniaOuPickerNode',
            'Stop-DomeniaOuPickerRead',
            'Start-DomeniaOuPickerRead',
            'Show-DomeniaOuPickerNavigation',
            'Complete-DomeniaOuPickerRead',
            'Fail-DomeniaOuPickerRead',
            'Show-DomeniaOuTreePicker',
            'Show-DomeniaInlinePicker',
            'Select-DomeniaRelationsUser',
            'Get-DomeniaEmbeddedContext',
            'New-DomeniaFileRequest',
            'Get-DomeniaEmbeddedPathCode',
            'Complete-DomeniaEmbeddedPath',
            'Fail-DomeniaEmbeddedPath',
            'Show-DomeniaInlineFilePicker'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Selection.UI.ps1'); File='Domenia-Relations.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaRelationsState',
            'Set-DomeniaRelationsSelection',
            'Set-DomeniaRelationsGridSelection',
            'Clear-DomeniaRelationsSelection',
            'Get-DomeniaRelationsSubject',
            'Get-DomeniaRelationsIdentity',
            'Get-DomeniaRelationsSubjectIdentity',
            'Get-DomeniaRelationsTargetIdentity',
            'Test-DomeniaRelationsCurrent',
            'Test-DomeniaRelationsListContains',
            'Get-DomeniaRelationsAllRelations',
            'Get-DomeniaRelationsSelectedLinks',
            'Get-DomeniaRelationsActiveGrid',
            'Test-DomeniaRelationsPageVisible',
            'Open-DomeniaRelationsPage',
            'Show-DomeniaRelationsAddPanel',
            'Switch-DomeniaRelationsHelp',
            'Step-DomeniaRelationsAssociation',
            'Update-DomeniaRelationsActions',
            'Update-DomeniaRelationEvidence',
            'Update-DomeniaRelationCandidateEvidence',
            'Get-DomeniaAllLinksBadgeFilter',
            'Clear-DomeniaAllLinksFilter',
            'Update-DomeniaAllLinksView',
            'Refresh-DomeniaRelationViews',
            'Update-DomeniaRelationDetectionCounters',
            'Invoke-DomeniaRelationsTick',
            'Update-DomeniaRelationLinkIndex',
            'Get-DomeniaRelationsJournalPath',
            'Add-DomeniaRelationHistory',
            'Get-DomeniaRelationsRestorableEntry',
            'Reset-DomeniaRelationsRestoreCache',
            'Get-DomeniaRelationsRestoreCandidate',
            'Test-DomeniaRelationsRestoreAvailable',
            'Add-DomeniaRelation',
            'Set-DomeniaRelationValue',
            'Get-DomeniaRelationSaveRefusal',
            'Find-DomeniaRelationInstance',
            'Remove-DomeniaRelations',
            'Get-DomeniaRelationRefusalText',
            'Remove-DomeniaRelation',
            'Request-DomeniaRelationRemoval',
            'Complete-DomeniaRelationRemoval',
            'Cancel-DomeniaRelationRemoval',
            'Restore-DomeniaRemovedLink',
            'Save-DomeniaRelationConfirmations',
            'Complete-DomeniaRelationsSearch',
            'Fail-DomeniaRelationsSearch',
            'Get-DomeniaRelationScopeCandidates',
            'Show-DomeniaRelationDetectionPlan',
            'Confirm-DomeniaRelationDetectionPlan',
            'Cancel-DomeniaRelationDetectionPlan',
            'Submit-DomeniaRelationsQuery',
            'Start-DomeniaRelationsComputerDetect',
            'Complete-DomeniaRelationsComputerProbe',
            'Fail-DomeniaRelationsComputerProbe',
            'Start-DomeniaRelationsSearch',
            'Stop-DomeniaRelationsSearch',
            'Use-DomeniaRelationCandidate',
            'Initialize-DomeniaRelationsUi',
            'Clear-DomeniaRelationManualResults',
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
            'Get-DomeniaLinkQualification',
            'Select-DomeniaBestLink',
            'Get-DomeniaGridHit',
            'Open-DomeniaRelationEnd',
            'Open-DomeniaAllLinksCell',
            'New-DomeniaAllLinksContextMenu',
            'New-DomeniaLinkImportPlan',
            'Update-DomeniaLinkImportUi',
            'Set-DomeniaLinkImportPlan',
            'Show-DomeniaLinkImportPreview',
            'Start-DomeniaLinkImportIndexCheck',
            'Test-DomeniaLinkImportIndexState',
            'Complete-DomeniaLinkImportIndexCheck',
            'Fail-DomeniaLinkImportIndexCheck',
            'Cancel-DomeniaLinkImportPreview',
            'Confirm-DomeniaLinkImport',
            'Request-DomeniaLinkImportUndo',
            'Undo-DomeniaLinkImport',
            'Update-DomeniaOrphanUi',
            'Select-DomeniaOrphanBatch',
            'Show-DomeniaOrphanLinks',
            'Request-DomeniaOrphanRemoval',
            'Cancel-DomeniaOrphanRemoval',
            'Complete-DomeniaOrphanRemoval',
            'Close-DomeniaOrphanLinks',
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
            'Get-DomeniaUxNavButtons',
            'Sync-DomeniaUxNavigation',
            'Update-DomeniaUxProfileVisibility',
            'Get-DomeniaUxHeightPlan',
            'Set-DomeniaSearchQueryOptionsLayout',
            'Set-DomeniaUxShortLayout',
            'Get-DomeniaUxAvailableSize',
            'Update-DomeniaUxLayout',
            'Switch-DomeniaUxHelp',
            'Switch-DomeniaUxLog',
            'Initialize-DomeniaUxShell',
            'Set-DomeniaUxPalette',
            'ConvertTo-DomeniaUxFlag',
            'Get-DomeniaUxLayoutPlan',
            'Save-DomeniaUxLayoutSettings',
            'Test-DomeniaUxNavFolded',
            'Switch-DomeniaUxSidebar',
            'Update-DomeniaUxSidebar',
            'Get-DomeniaUxOuDisplay',
            'Update-DomeniaUxOuScope',
            'Copy-DomeniaUxOuPath',
            'Initialize-DomeniaUxLoginPresentation',
            'Test-DomeniaUxExpertAllowed',
            'Send-DomeniaUxLiveChange',
            'Get-DomeniaUxSubject',
            'Update-DomeniaUxPageTitle',
            'Update-DomeniaUxSessionBadge',
            'Update-DomeniaUxAccountFooter',
            'Show-DomeniaUxAccountMenu',
            'Switch-DomeniaUxAbout',
            'Clear-DomeniaUxSubject',
            'Update-DomeniaUxProfileSwitch',
            'Invoke-DomeniaJournalShortcut',
            'Update-DomeniaUxThemeToggle',
            'Set-DomeniaUxHeaderLayout',
            'Get-DomeniaUxRecentEntries',
            'Add-DomeniaUxRecentEntry',
            'Add-DomeniaUxRecentObject',
            'Initialize-DomeniaUxSearchBar',
            'Update-DomeniaUxSearchClear',
            'Update-DomeniaUxSearchSuggestions',
            'Set-DomeniaUxSuggestionItems',
            'Hide-DomeniaUxSearchSuggestions',
            'Request-DomeniaUxLocalSuggestions',
            'Start-DomeniaUxLocalSuggestions',
            'Complete-DomeniaUxLocalSuggestionsUi',
            'Fail-DomeniaUxLocalSuggestionsUi',
            'Register-DomeniaUxSearchGesture',
            'Invoke-DomeniaUxSearchKey',
            'Select-DomeniaUxSuggestion',
            'Initialize-DomeniaUxEmptyStates',
            'Update-DomeniaUxEmptyStates',
            'Invoke-DomeniaUxEmptySearch',
            'Get-DomeniaUxReadOnlyDelay',
            'Request-DomeniaWriteMode',
            'Enable-DomeniaWriteMode',
            'Enter-DomeniaReadOnlyMode',
            'Exit-DomeniaWriteMode',
            'Update-DomeniaReadOnlySwitch',
            'Get-DomeniaUxReadOnlyPlan',
            'Invoke-DomeniaReadOnlyReturnTick',
            'Start-DomeniaReadOnlyReturnTimer',
            'Stop-DomeniaReadOnlyReturnTimer',
            'Get-DomeniaUiZoomLayoutSize',
            'Set-DomeniaUiZoom',
            'Initialize-DomeniaUiZoom'
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
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Shell.Model.ps1'); File='Domenia-Experience.UI.ps1'; DotSource=$false; Functions=@(
            'Get-DomeniaExperienceVisibleRows',
            'Get-DomeniaExperienceExportRows',
            'Open-DomeniaExperienceActivity',
            'Initialize-DomeniaOperationsPanel',
            'Set-DomeniaOperationsPanelPosition',
            'Show-DomeniaOperationsPanel',
            'Hide-DomeniaOperationsPanel',
            'Switch-DomeniaOperationsPanel',
            'Test-DomeniaOperationsPanelOpen',
            'Stop-DomeniaOperationRow',
            'Stop-DomeniaExperienceSelectedRead',
            'Sync-DomeniaOperationRows',
            'Get-DomeniaOperationsHealthText',
            'Update-DomeniaExperienceActivity',
            'Update-DomeniaExperienceIdentity',
            'Apply-DomeniaExperienceDensity',
            'Apply-DomeniaExperienceLogReading',
            'Find-DomeniaExperienceLog',
            'Set-DomeniaExperienceJournalLayout',
            'ConvertTo-DomeniaExperienceLogEntry',
            'Add-DomeniaExperienceLogEntry',
            'Clear-DomeniaExperienceLogEntries',
            'Set-DomeniaExperienceLogFilter',
            'Update-DomeniaExperienceLogView',
            'Update-DomeniaExperienceLogBadge',
            'Open-DomeniaExperienceJournal',
            'ConvertTo-DomeniaMaskedLogText',
            'Get-DomeniaExperienceLogCopyText',
            'Save-DomeniaExperiencePreferences',
            'Initialize-DomeniaExperience',
            'Update-DomeniaExperienceCapsLock',
            'Switch-DomeniaExperienceLoginTheme',
            'Update-DomeniaExperienceLoginThemeIcon',
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
            'Add-DomeniaLiveMemoryQuery',
            'Get-DomeniaLiveObjectKey',
            'ConvertTo-DomeniaLiveObservation',
            'Get-DomeniaLiveObservationView',
            'Test-DomeniaLiveIdentity',
            'Get-DomeniaLivePresenceView',
            'Test-DomeniaPresenceMatch',
            'Test-DomeniaLiveRowInScope',
            'Get-DomeniaLiveProbeCode',
            'Get-DomeniaLiveCacheCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Live.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Storage.UI.ps1'); File='Domenia-Live.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLiveIdentityKey',
            'Get-DomeniaLiveIdentitySignal',
            'Initialize-DomeniaLive',
            'Reset-DomeniaLiveIdentity',
            'Stop-DomeniaLiveSearch',
            'Stop-DomeniaLiveProbes',
            'Stop-DomeniaLive',
            'Test-DomeniaLiveSearchActive',
            'Set-DomeniaLoginColumnVisible',
            'Update-DomeniaLoginColumnFromRows',
            'Set-DomeniaResultColumns',
            'Update-DomeniaSearchActionStates',
            'Test-DomeniaRowHasAccount',
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
            'Complete-DomeniaLiveStored',
            'Fail-DomeniaLiveStored',
            'Fail-DomeniaLiveProbe',
            'Complete-DomeniaLiveCache',
            'Fail-DomeniaLiveCache',
            'Get-DomeniaLiveWorkerCount',
            'Get-DomeniaLiveDatabasePath',
            'Start-DomeniaLiveBackgroundWork',
            'Invoke-DomeniaLiveTick',
            'Test-DomeniaLiveBackgroundAllowed',
            'Test-DomeniaLiveTickNeeded',
            'Update-DomeniaSearchMoreButton',
            'Invoke-DomeniaSearchMore',
            'Complete-DomeniaLiveObservationRead',
            'Fail-DomeniaLiveObservationRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Access.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Shell.Model.ps1'); File='Domenia-Access.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaAccessFailureKind',
            'Get-DomeniaAccessScope',
            'Get-DomeniaAccessNow',
            'Get-DomeniaAccessIdleMinutes',
            'Get-DomeniaRetryScopeKey',
            'Test-DomeniaAccessLeaseUsable',
            'Use-DomeniaAccessLease',
            'Remove-DomeniaAccessCredential',
            'Get-DomeniaRetryCredential',
            'Set-DomeniaRetryWorkerContext',
            'Test-DomeniaSecretDenied',
            'Set-DomeniaSecretDenied',
            'Test-DomeniaAccessBusyWrite',
            'Test-DomeniaSecretOperation',
            'ConvertTo-DomeniaAccessCategory',
            'Get-DomeniaAccessCoalescer',
            'Add-DomeniaAccessDenialUi',
            'Complete-DomeniaAccessPromptUi',
            'Request-DomeniaAccessRecovery',
            'Update-DomeniaAccessButton',
            'Test-DomeniaAccessSessionCurrent',
            'Show-DomeniaAlternateCredential',
            'Invoke-DomeniaAccessRecovery',
            'Resolve-DomeniaCapabilityRoute',
            'Invoke-DomeniaCapabilityRoute',
            'Get-DomeniaControlCapabilityExplanation',
            'Get-DomeniaUnavailableReasonLines',
            'New-DomeniaAccessState',
            'Clear-DomeniaAccessAccounts',
            'Invoke-DomeniaAccessLeaseSweep',
            'Get-DomeniaTransportPolicyRows',
            'Update-DomeniaTransportPolicyView',
            'Initialize-DomeniaAccess',
            'Inspect-DomeniaAccessResult'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1'); File='Domenia-Continuity.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaStateMap',
            'ConvertTo-DomeniaColumnLayout',
            'ConvertTo-DomeniaTreeBookmark',
            'Get-DomeniaTreeRevealPath',
            'Get-DomeniaChangeWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Continuity.Model.ps1','Domenia-Live.UI.ps1'); File='Domenia-Continuity.UI.ps1'; DotSource=$true; Functions=@(
            'Stop-DomeniaFavouriteTreeReveal',
            'Start-DomeniaFavouriteTreeReveal',
            'Invoke-DomeniaFavouriteTreeReveal',
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
            'Clear-DomeniaVisitCacheForObject',
            'Test-DomeniaListRevalidationEnabled',
            'Update-DomeniaListRevalidationUi',
            'Test-DomeniaContinuityTickNeeded',
            'Invoke-DomeniaObjectChanges',
            'Get-DomeniaOuRestoreDecision',
            'Show-DomeniaOuRestoreNotice',
            'Hide-DomeniaOuRestoreNotice',
            'Invoke-DomeniaOuRestoreRetry',
            'Initialize-DomeniaContinuity'
        ) }
        [pscustomobject]@{ File='Domenia-Guard.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStructuredError',
            'Get-DomeniaCredentialAccountKey',
            'Set-WCredentialAttemptIdentity',
            'Get-WCredentialGuardKeys',
            'Assert-WCredentialAllowed',
            'Enter-WCredentialAttempt',
            'Exit-WCredentialAttempt',
            'Register-WCredentialFailure',
            'Get-DomeniaLinkFingerprint',
            'ConvertTo-DomeniaLinkRecord',
            'Get-DomeniaDraftFieldMap',
            'ConvertTo-DomeniaSavedSearch',
            'Get-DomeniaPercentile'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Storage.UI.ps1','Domenia-Store.Model.ps1'); File='Domenia-Accounts.Store.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaAccountPreferences',
            'Get-DomeniaAccountPreferenceScope',
            'Test-DomeniaAccountPreferenceContext',
            'Get-DomeniaAccountPreferenceIdentity',
            'Get-DomeniaRememberedAccount',
            'Update-DomeniaRememberedAccountFields',
            'Set-DomeniaCommittedAccountPreferences',
            'Save-DomeniaAccountPreference',
            'Sync-DomeniaAccountPreferences',
            'Complete-DomeniaAccountPreferenceRead',
            'Fail-DomeniaAccountPreferenceRead',
            'Complete-DomeniaAccountPreferenceSave',
            'Fail-DomeniaAccountPreferenceSave'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-CredentialVault.Model.ps1','Domenia-Accounts.Store.UI.ps1'); File='Domenia-Accounts.Vault.UI.ps1'; DotSource=$true; Functions=@(
            'Save-DomeniaSecondaryVault',
            'Invoke-DomeniaSecondaryVaultLogin',
            'Remove-DomeniaSecondaryVault',
            'Initialize-DomeniaAccountVaultUi'
        ) }
        [pscustomobject]@{ File='Domenia-Accounts.Async.ps1'; DotSource=$true; Functions=@(
            'Start-DomeniaAccountValidation',
            'Complete-DomeniaAccountValidation',
            'Stop-DomeniaAccountValidation'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Store.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStoreValue',
            'Get-DomeniaStoreHash',
            'Get-DomeniaStoreId',
            'ConvertTo-DomeniaStoreUtc',
            'Assert-DomeniaStoreSafeData',
            'ConvertTo-DomeniaStoreBatch',
            'ConvertTo-DomeniaStoreQueryChange',
            'ConvertTo-DomeniaStoragePolicy',
            'Get-DomeniaStorageBackupDecision'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Store.Model.ps1'); File='Domenia-DirectoryStore.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaDirectoryStoreWorkerPrelude',
            'ConvertTo-DomeniaDirectoryPropertyMap',
            'Get-DomeniaDirectoryPropertyValue',
            'Get-DomeniaDirectoryStoredType',
            'ConvertTo-DomeniaDirectoryDisplayRow',
            'ConvertTo-DomeniaDirectoryStoreChange',
            'ConvertFrom-DomeniaDirectoryCommittedRow'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-DirectoryStore.Model.ps1','Domenia-Storage.UI.ps1'); File='Domenia-DirectoryStore.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaDirectoryStore',
            'New-DomeniaDirectoryReadPipe',
            'Complete-DomeniaDirectoryReadPipe',
            'Invoke-DomeniaDirectoryStoreTick',
            'Complete-DomeniaDirectoryStoreBatch',
            'Fail-DomeniaDirectoryStoreBatch',
            'Submit-DomeniaDirectoryObjectRead',
            'Complete-DomeniaDirectoryObjectCommit',
            'Fail-DomeniaDirectoryObjectCommit',
            'Submit-DomeniaDirectoryTreeRead',
            'Complete-DomeniaDirectoryTreeRead',
            'Test-DomeniaDirectoryTreeCurrent',
            'Request-DomeniaDirectoryTreeSnapshot',
            'Complete-DomeniaDirectoryTreeSnapshot',
            'Fail-DomeniaDirectoryTreeSnapshot',
            'Fail-DomeniaDirectoryTreeCommit',
            'Test-DomeniaDirectoryChangesCurrent',
            'Complete-DomeniaDirectoryChangesCommit',
            'Complete-DomeniaDirectoryChangesRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-ProbeDetails.Model.ps1','Domenia-Storage.UI.ps1'); File='Domenia-ProbeDetails.UI.ps1'; DotSource=$true; Functions=@(
            'Show-DomeniaProbeDetails',
            'Test-DomeniaProbeDetailsState',
            'Complete-DomeniaProbeDetailsRead',
            'Update-DomeniaProbeDetailsPage',
            'Fail-DomeniaProbeDetailsRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-ProbeDetails.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaProbeDetailValue',
            'ConvertTo-DomeniaProbeDetailInstance',
            'New-DomeniaProbeDetailProjection',
            'Get-DomeniaProbeDetailPage',
            'Get-DomeniaProbeDetailWorkerPrelude'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-StorageLease.Model.ps1'; DotSource=$true; Functions=@(
            'Get-StoreWLeaseName',
            'Enter-StoreWDatabaseLease',
            'Exit-StoreWDatabaseLease',
            'Read-StoreWLeaseScalar',
            'Assert-StoreWDatabaseWritable'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-StorageLease.Model.ps1'); File='Domenia-Storage.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStorageWorkerCode',
            'Get-DomeniaStorageUsageWorkerCode',
            'Get-DomeniaStoragePurgeWorkerCode',
            'Get-DomeniaStorageBackupWorkerCode',
            'Get-DomeniaStorageLeaseWorkerCode',
            'Get-DomeniaStorageMaintenanceWorkerCode',
            'Get-DomeniaStorageRetentionWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Storage.UI.ps1'); File='Domenia-StorageContext.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaDatabasePreferenceKey',
            'Switch-DomeniaDatabaseContext',
            'Resume-DomeniaDatabaseViews'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Cache.Model.ps1','Domenia-Common.Model.ps1','Domenia-Release.Model.ps1','Domenia-Storage.Worker.ps1'); File='Domenia-Storage.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaPersistence',
            'Add-DomeniaIndexPersistence',
            'Request-DomeniaStorageWork',
            'Test-DomeniaStorageWorkPending',
            'Reset-DomeniaLinkBaseline',
            'Queue-DomeniaLinkChanges',
            'Request-DomeniaLinkPersistence',
            'Start-DomeniaStorageWork',
            'Complete-DomeniaStorageWork',
            'Fail-DomeniaStorageWork',
            'Queue-DomeniaMetadata',
            'Get-DomeniaPersistenceState',
            'Get-DomeniaUserLocalRoot',
            'Invoke-DomeniaPreferenceMigration',
            'Format-DomeniaStorageUsage',
            'Start-DomeniaStorageUsage',
            'Complete-DomeniaStorageUsage',
            'Fail-DomeniaStorageUsage',
            'Get-DomeniaStoragePurgeChoice',
            'Reset-DomeniaStoragePurgePreview',
            'Assert-DomeniaStoragePurgeReady',
            'Format-DomeniaStoragePurge',
            'Start-DomeniaStoragePurge',
            'Request-DomeniaStoragePurge',
            'Complete-DomeniaStoragePurge',
            'Fail-DomeniaStoragePurge',
            'Update-DomeniaIndexLocation',
            'Open-DomeniaIndexLocation',
            'Assert-DomeniaBackupDestination',
            'Invoke-DomeniaIndexBackup',
            'Complete-DomeniaIndexBackupUi',
            'Fail-DomeniaIndexBackupUi',
            'New-DomeniaStoreContext',
            'Submit-DomeniaStoreBatch',
            'Request-DomeniaStoreRead',
            'Get-DomeniaLocalDatabasePath',
            'Request-DomeniaStorageMaintenance',
            'Complete-DomeniaStorageMaintenancePreview',
            'Start-DomeniaStorageMaintenanceApply',
            'Complete-DomeniaStorageMaintenanceApply',
            'Fail-DomeniaStorageMaintenance',
            'Resume-DomeniaStorageMaintenance',
            'Get-DomeniaCurrentStoragePolicy',
            'Save-DomeniaStoragePolicy',
            'Initialize-DomeniaStoragePolicy',
            'Invoke-DomeniaScheduledBackup',
            'Request-DomeniaStorageRecovery',
            'Complete-DomeniaStorageRecovery',
            'Fail-DomeniaStorageRecovery',
            'Start-DomeniaStorageRetention',
            'Request-DomeniaStorageRetention',
            'Complete-DomeniaStorageRetention',
            'Fail-DomeniaStorageRetention',
            'Reset-DomeniaStorageObservationViews'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Lockout.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLockoutEventWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Receipts.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaReceiptsCommon',
            'Get-DomeniaReceiptWorkerCode'
        ) }
        [pscustomobject]@{ File='Domenia-Sessions.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaSessionsWorkerCode',
            'Get-DomeniaSelectedMachineName',
            'Start-DomeniaSessionsRead',
            'Complete-DomeniaSessionsCollected',
            'Fail-DomeniaSessionsCollected',
            'Complete-DomeniaSessionsRead',
            'Fail-DomeniaSessionsRead',
            'Open-DomeniaSessionFiche',
            'New-DomeniaSessionsContextMenu',
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
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Cache.Model.ps1','Domenia-Common.Model.ps1','Domenia-Live.UI.ps1'); File='Domenia-Reconcile.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaReconcileWorkerCode',
            'Complete-DomeniaReconcile',
            'Fail-DomeniaReconcile',
            'Invoke-DomeniaReconcileTick',
            'Initialize-DomeniaReconcile'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Storage.UI.ps1','Domenia-Migration.UI.ps1'); File='Domenia-Guard.UI.ps1'; DotSource=$true; Functions=@(
            'Show-DomeniaGuard',
            'Start-DomeniaReceiptRefresh',
            'Complete-DomeniaReceiptRefresh',
            'Fail-DomeniaReceiptRefresh',
            'Get-DomeniaSelectedReceiptView',
            'Test-DomeniaReceiptStoreBusy',
            'Update-DomeniaReceiptActionUi',
            'Invoke-DomeniaReceiptChoice',
            'Complete-DomeniaReceiptChoice',
            'Cancel-DomeniaReceiptChoice',
            'Save-DomeniaDraftBaseline',
            'Get-DomeniaDirtyFields',
            'Test-DomeniaDraftNavigation',
            'Keep-DomeniaDraftOnResult',
            'Show-DomeniaDraftComparison',
            'Set-DomeniaArtifactConsent',
            'Set-DomeniaReadFallbackConsent',
            'Read-DomeniaOuFavouriteStore',
            'Write-DomeniaOuFavouriteStore',
            'Import-DomeniaFavouriteSearchesOnce',
            'Get-DomeniaFavouriteSearches',
            'Test-DomeniaOuFavourite',
            'Save-DomeniaFavouriteSearch',
            'Load-DomeniaFavouriteSearch',
            'Update-DomeniaOuFavouritesUi',
            'Open-DomeniaSuiteTool',
            'Initialize-DomeniaGuard',
            'Set-DomeniaProtectedClipboard',
            'Remove-DomeniaFavouriteSearch',
            'Resume-DomeniaStorage',
            'Show-DomeniaUnavailableReasons'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1'); File='Domenia-Demo.Model.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaDemoProviderEnabled',
            'Test-DomeniaDemoIdentity',
            'Get-DomeniaDemoBannerText',
            'Get-DomeniaDemoPassThroughOperations',
            'ConvertTo-DomeniaDemoWorkerContext',
            'Get-DomeniaDemoUnavailableText',
            'New-DomeniaDemoGuidBytes',
            'New-DomeniaDemoSidBytes',
            'New-DomeniaDemoDirectory'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Demo.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaDemoDirectoryWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Engine.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLocalIndexReadWorkerCode',
            'Get-DomeniaParkSharedSyncWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Isolation.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaIsolatedReadWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Demo.Model.ps1','Domenia-Demo.Worker.ps1','Domenia-Engine.Worker.ps1','Domenia-Isolation.Worker.ps1','Domenia-Access.Model.ps1','Domenia-Cache.Model.ps1'); File='Domenia-Engine.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaEngineState',
            'Test-DomeniaSchedulerEnabled',
            'Get-DomeniaEngineLimits',
            'Get-DomeniaEngineLoad',
            'Get-DomeniaUiTaskAdmission',
            'Get-DomeniaNextTaskSequence',
            'Get-DomeniaContextCredentialIdentity',
            'Get-DomeniaCredentialGuardFailures',
            'Add-DomeniaCredentialFailureHistory',
            'Get-DomeniaCredentialFailureHistory',
            'Set-DomeniaCredentialGuardContext',
            'Sync-DomeniaCredentialGuardUi',
            'Save-DomeniaSupersededCollection',
            'Invoke-DomeniaUiTaskDispatch',
            'Get-DomeniaDispatchIsolation',
            'New-DomeniaIsolatedReadPayload',
            'Register-DomeniaJobResources',
            'Sync-DomeniaJobResources',
            'Register-DomeniaOwnedTimer',
            'Register-DomeniaWorkerPool',
            'New-DomeniaTimer',
            'Get-DomeniaPulse',
            'Get-DomeniaPulseNow',
            'Start-DomeniaTimer',
            'Stop-DomeniaTimer',
            'Set-DomeniaTimerInterval',
            'Invoke-DomeniaTimerSoon',
            'Invoke-DomeniaTimerTick',
            'Invoke-DomeniaPulse',
            'Update-DomeniaPulseSchedule',
            'Get-DomeniaPulseState',
            'Resume-DomeniaAsyncPoll',
            'Add-DomeniaRuntimeMetric',
            'Get-DomeniaRuntimeMetricSummary',
            'Write-DomeniaTrace',
            'Add-DomeniaTaskSubscriber',
            'Invoke-DomeniaTaskSubscribers',
            'Remove-DomeniaQueuedTask',
            'Invoke-DomeniaQueuedTaskPromotion',
            'Register-DomeniaTaskOutcome',
            'ConvertTo-DomeniaTaskErrorInfo',
            'Add-DomeniaTaskRuntimeMetric',
            'Test-DomeniaIdlePolicyEnabled',
            'Test-DomeniaBackgroundWorkAllowed',
            'Update-DomeniaIdlePolicy',
            'Set-DomeniaWindowSuspended',
            'Initialize-DomeniaIdlePolicy',
            'Get-DomeniaIndexSearchSort',
            'Set-DomeniaIndexSearchSort',
            'Request-DomeniaIndexSearch',
            'Get-DomeniaLocalDatabasePathForRead',
            'Start-DomeniaIndexSearch',
            'Complete-DomeniaIndexSearchUi',
            'Move-DomeniaIndexSearchPage',
            'Fail-DomeniaIndexSearchUi',
            'Request-DomeniaParkStateReload',
            'Add-DomeniaParkDeferredResult',
            'Invoke-DomeniaParkDeferredResults',
            'Complete-DomeniaParkStateReloadUi',
            'Fail-DomeniaParkStateReloadUi',
            'Get-DomeniaParkStatusTextSafe',
            'Start-DomeniaParkSharedSync',
            'Complete-DomeniaParkSharedSyncUi',
            'Fail-DomeniaParkSharedSyncUi'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Lockout.Worker.ps1'); File='Domenia-Lockout.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLockoutAccountKeys',
            'Show-DomeniaLockoutText',
            'Start-DomeniaLockoutEventRead',
            'Test-DomeniaLockoutStateCurrent',
            'Format-DomeniaLockoutReport',
            'Complete-DomeniaLockoutEventRead',
            'Fail-DomeniaLockoutEventRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Demo.Model.ps1'); File='Domenia-Demo.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaDemoMode',
            'Get-DomeniaDemoConfiguredIdentity',
            'Initialize-DomeniaDemoLoginPresentation',
            'Set-DomeniaDemoShellPresentation'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Shell.Model.ps1'); File='Domenia-Startup.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaActivationState',
            'ConvertTo-DomeniaActivationTrigger',
            'Register-DomeniaUserSwitchWatch',
            'Test-DomeniaOwnWindowActive',
            'Write-DomeniaActivationLog',
            'Request-DomeniaWindowActivation',
            'Test-DomeniaUserSwitchedAway'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Live.UI.ps1'); File='Domenia-Search.UI.ps1'; DotSource=$true; Functions=@(
            'Update-DomeniaSearchHint',
            'Update-DomeniaWorkViewList',
            'Get-DomeniaSearchQueryFavorites',
            'Initialize-DomeniaSearchQuerySelector',
            'Update-DomeniaSearchQueryList',
            'Update-DomeniaSearchQueryDetails',
            'Get-DomeniaSearchQueryCoverageText',
            'Switch-DomeniaSearchQueryFavorite',
            'Reset-DomeniaSearchQueryFilters',
            'Clear-DomeniaSearchQuery',
            'Open-DomeniaSearchQueryWorkshop',
            'Get-DomeniaWorkViewScopeChoice',
            'Update-DomeniaOuScopeChoices',
            'Invoke-DomeniaWorkView',
            'Test-DomeniaSearchLocalQueryCurrent',
            'Start-DomeniaSearchLocalQuery',
            'Complete-DomeniaSearchLocalRead',
            'Complete-DomeniaSearchLocalQuery',
            'Fail-DomeniaSearchLocalQuery',
            'Get-DomeniaGridScrollViewer',
            'Get-DomeniaNavSnapshot',
            'Get-DomeniaTypeLabelOfFilter',
            'Get-DomeniaVisiblePageName',
            'Enter-DomeniaNavSearch',
            'Exit-DomeniaNavSearch',
            'Update-DomeniaNavButtons',
            'Register-DomeniaNavLocation',
            'Restore-DomeniaNavState',
            'Invoke-DomeniaNavStep',
            'Test-DomeniaHistoryListShown',
            'Update-DomeniaHistoryBanner',
            'Invoke-DomeniaHistoryRefresh',
            'Get-DomeniaTreeSelectionSource',
            'Stop-DomeniaPendingFilterChange',
            'Request-DomeniaSearchFilterChanged',
            'Invoke-DomeniaPendingFilterChange',
            'Get-DomeniaOuTreeNodeName',
            'Set-DomeniaOuTreeNodeFilter',
            'Update-DomeniaOuTreeFilter',
            'Switch-DomeniaOuMenu',
            'Get-DomeniaTreeItemFromElement',
            'Initialize-DomeniaSearchUi',
            'Update-DomeniaOuBreadcrumb',
            'Open-DomeniaOuBreadcrumb',
            'Stop-DomeniaOuTreeFilter',
            'Invoke-DomeniaOuTreeFilterSlice'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Secrets.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaBitLockerListWorkerCode',
            'Get-DomeniaBitLockerKeyWorkerCode',
            'Get-DomeniaBitLockerPresenceWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Access.Model.ps1','Domenia-Access.UI.ps1','Domenia-Secrets.Worker.ps1'); File='Domenia-Secrets.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaBitLockerKeySelection',
            'Test-DomeniaSecretSingleExposure',
            'Get-DomeniaSecretIdentityReason',
            'Get-DomeniaSecretButtonExplanation',
            'Update-DomeniaSecretsPrerequisite',
            'Select-DomeniaSecretRow',
            'Start-DomeniaSecretReveal',
            'Start-DomeniaSecretRevealExpiry',
            'Hide-DomeniaRevealedSecret',
            'Get-DomeniaRevealedBitLockerKey',
            'Update-DomeniaSecretRevealCountdown',
            'Update-DomeniaSecretsView',
            'Invoke-DomeniaSecretRevealExtension',
            'Get-DomeniaSelectedSecretIndex',
            'Complete-DomeniaBitLockerListUi',
            'Invoke-DomeniaBitLockerRecoveryIdFilter',
            'Request-DomeniaBitLockerKey',
            'Complete-DomeniaBitLockerKeyUi',
            'Fail-DomeniaBitLockerKeyUi',
            'Invoke-DomeniaSecretsPrerequisite',
            'Initialize-DomeniaSecretsUi'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Shell.Model.ps1'); File='Domenia-Inline.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaInlineUi',
            'Get-DomeniaInlinePendingRequest',
            'Test-DomeniaInlineBlocks',
            'Request-DomeniaInlineConfirmation',
            'Update-DomeniaInlineTypedState',
            'Complete-DomeniaInlineRequest'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Release.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Storage.UI.ps1','Domenia-Inline.UI.ps1','Domenia-Migration.Worker.ps1'); File='Domenia-Migration.UI.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaLegacyNumber',
            'ConvertTo-DomeniaLegacyDate',
            'Read-DomeniaLegacySource',
            'Get-DomeniaLegacySnapshot',
            'New-DomeniaLegacyImportPlan',
            'Invoke-DomeniaLegacyImport',
            'Show-DomeniaLegacyImportPlan',
            'Request-DomeniaLegacyImport',
            'Start-DomeniaLegacyImportWork',
            'Complete-DomeniaLegacyImportWork',
            'Fail-DomeniaLegacyImportWork'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Migration.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaMigrationWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Cache.Model.ps1'); File='Domenia-Park.Model.ps1'; DotSource=$true; Functions=@(
            'Expand-DomeniaParkPrevious',
            'Clear-DomeniaParkTargetBuffers',
            'ConvertTo-DomeniaParkSession',
            'Test-DomeniaParkLinkChanged',
            'New-DomeniaCollectionPlan',
            'ConvertTo-DomeniaRemoteObservationChanges',
            'Test-DomeniaRemoteStoreContext',
            'Add-DomeniaRemoteProbeDefinitionHash'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1'); File='Domenia-HealthRules.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaHealthRuleCatalog',
            'Get-DomeniaHealthThresholdCatalog',
            'Get-DomeniaHealthValue',
            'ConvertTo-DomeniaHealthPolicy',
            'Test-DomeniaHealthRuleEnabled',
            'Add-DomeniaCustomHealthAttention',
            'Update-DomeniaFleetHealthPopulation',
            'Get-DomeniaHealthExplanation',
            'Test-DomeniaHealthScope',
            'ConvertTo-DomeniaHealthPolicyBook',
            'Resolve-DomeniaHealthPolicy',
            'Set-DomeniaHealthScopePolicy',
            'ConvertTo-DomeniaHealthSuspensions',
            'Get-DomeniaHealthSuspension',
            'Update-DomeniaFleetScopedHealth'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-HealthRules.Model.ps1'); File='Domenia-Boards.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaBoardCatalogCache',
            'Get-DomeniaBoardCatalog',
            'Get-DomeniaBoardCatalogItem',
            'Get-DomeniaBoardColor',
            'Format-DomeniaDashboardSize',
            'Get-DomeniaBoardThresholds',
            'Get-DomeniaThresholdState',
            'Get-DomeniaChartTicks',
            'Test-DomeniaBoardNumberText',
            'ConvertFrom-DomeniaOsVersion',
            'Get-DomeniaWindowsFamily',
            'Get-DomeniaWindowsRelease',
            'Format-DomeniaAge',
            'ConvertFrom-DomeniaUtcText',
            'Get-DomeniaCoverageText',
            'Test-DomeniaObservationAge',
            'New-DomeniaBoardEntry',
            'New-DomeniaBoardData',
            'Add-DomeniaBoardEntry',
            'Add-DomeniaBoardAttention',
            'Get-DomeniaBoardHealth',
            'Get-DomeniaFleetHealth',
            'Complete-DomeniaBoardData',
            'Get-DomeniaBoardVisualNames',
            'Get-DomeniaBoardVisuals',
            'Resolve-DomeniaBoardVisual',
            'Get-DomeniaBoardSizeNames',
            'Get-DomeniaBoardSize',
            'New-DomeniaBoardItemId',
            'New-DomeniaBoardItem',
            'Get-DomeniaBoardDefaultLayout',
            'Test-DomeniaFleetLegacyLayout',
            'ConvertTo-DomeniaBoardLayout',
            'ConvertTo-DomeniaBoardLayoutJson',
            'Get-DomeniaBoardGroups',
            'Add-DomeniaBoardItem',
            'Remove-DomeniaBoardItem',
            'Update-DomeniaBoardItem',
            'Move-DomeniaBoardItem',
            'Get-DomeniaProbeKind',
            'Get-DomeniaProbeUnit',
            'ConvertFrom-DomeniaProbeMeasure',
            'ConvertTo-DomeniaSearchText',
            'New-DomeniaBoardSample',
            'Get-DomeniaChartCategoryGroups',
            'Get-DomeniaHealthFingerprint',
            'Set-DomeniaHealthSnapshotMetadata',
            'Compare-DomeniaHealthSnapshots',
            'Get-DomeniaFleetPivots'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Charts.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaChartPalette',
            'Get-DomeniaStateColor',
            'Get-DomeniaStateDotColor',
            'Get-DomeniaStateTextKey',
            'ConvertTo-DomeniaChartBrush',
            'Format-DomeniaChartNumber',
            'New-DomeniaChartText',
            'New-DomeniaChartIcon',
            'Get-DomeniaChartTruncated',
            'Get-DomeniaChartValueText',
            'Get-DomeniaChartItemColor',
            'Test-DomeniaMotion',
            'New-DomeniaChartEase',
            'Start-DomeniaTween',
            'Set-DomeniaHoverValue',
            'Register-DomeniaIntro',
            'Register-DomeniaCountUp',
            'Start-DomeniaCountTimer',
            'Add-DomeniaDashboardCards',
            'Invoke-DomeniaDashboardEntrance',
            'New-DomeniaChartCard',
            'New-DomeniaChartHeader',
            'New-DomeniaChartEmpty',
            'New-DomeniaKpiTile',
            'New-DomeniaRowButton',
            'New-DomeniaAttentionCard',
            'Invoke-DomeniaChartSelect',
            'New-DomeniaArcPath',
            'Register-DomeniaArcDrawing',
            'Set-DomeniaDonutFocus',
            'New-DomeniaDonutChart',
            'New-DomeniaGauge',
            'New-DomeniaBarChart',
            'New-DomeniaChartGrid',
            'New-DomeniaColumnChart',
            'New-DomeniaLineChart',
            'New-DomeniaHealthCard',
            'New-DomeniaListCard'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-ProbeCatalog.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaExtendedProbeCatalog',
            'Add-DomeniaProbeMetadata'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-ProbeCatalog.Model.ps1'); File='Domenia-Probes.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaProbeCatalog',
            'Get-DomeniaProbeVisuals',
            'Get-DomeniaProbe',
            'ConvertTo-DomeniaProbePayload',
            'New-DomeniaObservationReader',
            'ConvertTo-DomeniaProbeNumber',
            'Get-DomeniaProbeValues',
            'Measure-DomeniaWidgetData',
            'Measure-DomeniaFleetProbeEntries'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Boards.Model.ps1'); File='Domenia-BoardFleet.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaFleetQueryPlan',
            'Get-DomeniaFleetPointTargets',
            'Get-DomeniaFleetBoardData',
            'Get-DomeniaFleetFreshness',
            'Get-DomeniaOuObservationFreshness',
            'Format-DomeniaOuFreshnessSummary'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Boards.Model.ps1'); File='Domenia-BoardSoftware.Model.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaSoftwareRowMatchesSelect',
            'Get-DomeniaSoftwareSelectLabel',
            'Get-DomeniaSoftwareSelectToggle',
            'Get-DomeniaSoftwareFamily',
            'Get-DomeniaSoftwareBoardData'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1'); File='Domenia-BoardComputer.UI.ps1'; DotSource=$true; Functions=@(
            'Add-DomeniaComputerBoardAdEntries',
            'Get-DomeniaComputerBoardData'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-HealthRules.Model.ps1','Domenia-BoardFleet.Model.ps1'); File='Domenia-HealthRules.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaHealthPolicySettingKey',
            'Get-DomeniaStoredHealthPolicyBook',
            'Get-DomeniaStoredHealthPolicy',
            'Save-DomeniaHealthPolicy',
            'Show-DomeniaHealthRulesEditor',
            'Show-DomeniaHealthExplanation',
            'Show-DomeniaFleetAnalysis'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Boards.Model.ps1','Domenia-Charts.UI.ps1','Domenia-Probes.Model.ps1','Domenia-HealthRules.UI.ps1'); File='Domenia-Widgets.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaWidgetList',
            'Get-DomeniaBoardPanelName',
            'Get-DomeniaBoardState',
            'Get-DomeniaBoardLayout',
            'Sync-DomeniaBoardUndo',
            'Clear-DomeniaBoardUndo',
            'Set-DomeniaBoardLayout',
            'Get-DomeniaBoardRenderContext',
            'Resume-DomeniaBoardRender',
            'Show-DomeniaBoard',
            'Find-DomeniaBoardHolder',
            'Get-DomeniaBoardGroupSubtitle',
            'Get-DomeniaBoardHintAction',
            'New-DomeniaBoardHint',
            'Get-DomeniaBoardActionControl',
            'New-DomeniaBoardButton',
            'New-DomeniaBoardToolbar',
            'New-DomeniaBoardAddTile',
            'Optimize-DomeniaBoardRow',
            'Resolve-DomeniaBoardEntry',
            'Get-DomeniaBoardSelectHandler',
            'New-DomeniaWidgetVisual',
            'New-DomeniaBoardChromeButton',
            'New-DomeniaBoardMenu',
            'Set-DomeniaBoardSegmentSelection',
            'New-DomeniaBoardWidget',
            'Invoke-DomeniaBoardAutoScroll',
            'Request-DomeniaBoardDrop',
            'Complete-DomeniaBoardDrop',
            'Invoke-DomeniaBoardAction',
            'Restore-DomeniaBoardFocus',
            'Get-DomeniaBoardSources',
            'Get-DomeniaBoardPreviewEntry',
            'Show-DomeniaBoardEditor',
            'Get-DomeniaWidgetObservations',
            'ConvertTo-DomeniaWidgetGuid',
            'Get-DomeniaWidgetResults',
            'Get-DomeniaWidgetProbeObservations',
            'Get-DomeniaWidgetCoverage',
            'Invoke-DomeniaBoardEntryAction',
            'Switch-DomeniaAttentionDetails',
            'Get-DomeniaBoardProbeIds',
            'Get-DomeniaFleetCollectionContext',
            'Start-DomeniaWidgetProbe'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Charts.UI.ps1'); File='Domenia-Dashboard.UI.ps1'; DotSource=$true; Functions=@(
            'Clear-DomeniaDashboards',
            'Get-DomeniaInventoryValue',
            'Get-DomeniaCategorySummary',
            'New-DomeniaDashboardSection',
            'Get-DomeniaEntryFileTimeUtc',
            'Get-DomeniaFleetScope',
            'Update-DomeniaFleetMachineList',
            'Get-DomeniaWindowsLifecycleTable',
            'Get-DomeniaObservationMaxAgeDays',
            'Test-DomeniaFleetDashboardShown',
            'Test-DomeniaFleetAwaitingScope',
            'Request-DomeniaFleetRefresh',
            'Start-DomeniaFleetDashboard',
            'Fail-DomeniaFleetDashboard',
            'Update-DomeniaFleetScopeText',
            'Show-DomeniaFleetScopeSource',
            'Select-DomeniaFleetScopeOu',
            'Show-DomeniaFleetAnalyzeSource',
            'Merge-DomeniaFleetObservations',
            'Request-DomeniaSelectedObservation',
            'Complete-DomeniaSelectedObservation',
            'Fail-DomeniaSelectedObservation',
            'Save-DomeniaFleetSnapshot',
            'Complete-DomeniaFleetDashboard',
            'Get-DomeniaAttentionTargets',
            'Copy-DomeniaFleetTargets',
            'Show-DomeniaFleetTargetsInSearch',
            'Start-DomeniaFleetBitLockerPresence',
            'Complete-DomeniaFleetBitLockerPresence',
            'Fail-DomeniaFleetBitLockerPresence',
            'Get-DomeniaFirstStepsState',
            'Update-DomeniaFirstSteps',
            'Open-DomeniaFirstStep',
            'Get-DomeniaBoardRouteTarget',
            'Invoke-DomeniaBoardRoute',
            'Update-DomeniaComputerDashboard',
            'Update-DomeniaSoftwareDashboard'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Park.Model.ps1','Domenia-Relations.UI.ps1','Domenia-Storage.UI.ps1','Domenia-Inline.UI.ps1','Domenia-Engine.Worker.ps1'); File='Domenia-Park.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaParkRunCurrent',
            'Update-DomeniaParkRunStatus',
            'Update-DomeniaParkControls',
            'Start-DomeniaOnlinePark',
            'Start-DomeniaParkAnalysis',
            'Complete-DomeniaParkTargets',
            'Fail-DomeniaParkTargets',
            'Start-DomeniaParkRunTimer',
            'Stop-DomeniaOnlinePark',
            'Invoke-DomeniaParkRunTick',
            'Complete-DomeniaParkSession',
            'Complete-DomeniaParkStored',
            'Fail-DomeniaParkStored',
            'Fail-DomeniaParkSession',
            'Update-DomeniaParkResultRows',
            'Initialize-DomeniaRemoteStoreState',
            'Submit-DomeniaRemoteObservations',
            'Submit-DomeniaRemoteChanges',
            'Invoke-DomeniaRemoteStoreQueue',
            'Complete-DomeniaRemoteStoreBatch',
            'Fail-DomeniaRemoteStoreBatch',
            'Get-DomeniaCommittedObservation',
            'Start-DomeniaCommittedPresence',
            'Complete-DomeniaCommittedPresence',
            'Fail-DomeniaCommittedPresence',
            'Publish-DomeniaCommittedPresence',
            'Fail-DomeniaCommittedPresenceStore',
            'Submit-DomeniaRemoteDetail',
            'Complete-DomeniaRemoteDetailStored',
            'Fail-DomeniaRemoteDetailStored',
            'Complete-DomeniaLastUserCollected',
            'Fail-DomeniaLastUserCollected',
            'New-DomeniaClassicCollectionState',
            'ConvertTo-DomeniaClassicStoreData',
            'Complete-DomeniaClassicCollected',
            'Fail-DomeniaClassicCollected',
            'Test-DomeniaClassicResultCurrent',
            'Complete-DomeniaCachedInventoryRead',
            'Fail-DomeniaCachedInventoryRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Probes.Model.ps1','Domenia-Boards.Model.ps1'); File='Domenia-Query.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaQueryFields',
            'Get-DomeniaQueryCatalog',
            'Find-DomeniaQueryCatalogEntries',
            'Get-DomeniaQueryOperators',
            'New-DomeniaQueryRecipe',
            'Get-DomeniaQueryIdentitySelection',
            'ConvertTo-DomeniaCompiledQuery',
            'ConvertTo-DomeniaQueryProbeSelection',
            'Get-DomeniaQueryTemplates',
            'ConvertFrom-DomeniaQueryLibrary',
            'ConvertTo-DomeniaQueryLibraryJson',
            'Get-DomeniaQueryProbeIds',
            'Get-DomeniaQueryCollectionRequirements',
            'ConvertTo-DomeniaQueryRecords',
            'Get-DomeniaQueryValuePresentation',
            'ConvertTo-DomeniaQueryGridRows',
            'Select-DomeniaQueryPopulation',
            'Get-DomeniaQueryMatchIds',
            'Measure-DomeniaQueryWidget',
            'New-DomeniaQuerySegmentRecipe',
            'ConvertTo-DomeniaQueryNumber',
            'Get-DomeniaQueryExplanation',
            'Measure-DomeniaQueryCoverage',
            'Copy-DomeniaQueryRecipe',
            'Resolve-DomeniaQueryParameters',
            'Resolve-DomeniaQueryExpressionParameters',
            'Get-DomeniaQueryInstanceFields',
            'Get-DomeniaQueryTimestampKey',
            'ConvertTo-DomeniaQueryExpression',
            'ConvertTo-DomeniaQueryInstances',
            'Get-DomeniaQueryExpressionClauses',
            'Get-DomeniaQueryRequestedFields',
            'Get-DomeniaQueryExpressionOutline',
            'Edit-DomeniaQueryExpression',
            'New-DomeniaQueryMissingCollectionPlan',
            'Get-DomeniaQueryExpressionKey',
            'Get-DomeniaQueryCollectionNodes',
            'ConvertTo-DomeniaQueryCollectionProjections',
            'Add-DomeniaQueryCollectionProjectionRecords'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Query.Model.ps1'); File='Domenia-QueryLibrary.Model.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaQueryLibrarySchema',
            'ConvertTo-DomeniaQuerySearchKey',
            'Assert-DomeniaQueryLibraryContext',
            'New-DomeniaQueryLibraryRecord',
            'New-DomeniaQueryLibraryRead',
            'New-DomeniaQueryPackImportPlan',
            'Get-DomeniaQueryLibraryDefinitionValidationCode',
            'ConvertTo-DomeniaQueryPowerShell'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-QueryLibrary.Model.ps1','Domenia-Storage.UI.ps1'); File='Domenia-QueryLibrary.Store.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaQueryLibraryStoreState',
            'Initialize-DomeniaQueryLibraryStore',
            'Get-DomeniaSavedQueryRecipes',
            'Request-DomeniaQueryLibraryStorePage',
            'Complete-DomeniaQueryLibraryStoreRead',
            'Complete-DomeniaQueryLibraryMigrationRead',
            'Submit-DomeniaQueryLibraryMigrationBatch',
            'Complete-DomeniaQueryLibraryMigrationBatch',
            'Publish-DomeniaQueryLibraryStoreCache',
            'Fail-DomeniaQueryLibraryStoreRead',
            'Save-DomeniaQueryRecipe',
            'Complete-DomeniaQueryRecipeStore',
            'Fail-DomeniaQueryRecipeStore',
            'Complete-DomeniaQueryRecipeSaveUi',
            'Complete-DomeniaQueryRecipeArchiveUi'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Query.Model.ps1'); File='Domenia-Query.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaQueryWorkerCode',
            'Get-DomeniaQueryExportWorkerCode',
            'Get-DomeniaQueryLibraryWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Query.UI.ps1','Domenia-Widgets.UI.ps1'); File='Domenia-QueryTargets.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaComputerQueryRecords',
            'ConvertTo-DomeniaQueryCountEntry',
            'Get-DomeniaComputerQueryBoardEntry',
            'Show-DomeniaWorkshopComputerPreview',
            'Show-DomeniaComputerQueryWorkshop',
            'Add-DomeniaWorkshopWidget',
            'Complete-DomeniaWorkshopWidgetSave'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-QueryLibrary.Store.UI.ps1'); File='Domenia-Query.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaQueryView',
            'Update-DomeniaQueryScopeLabel',
            'Show-DomeniaQueryWorkshop',
            'Initialize-DomeniaQueryWorkshop',
            'Initialize-DomeniaQueryCatalog',
            'Update-DomeniaQueryCatalog',
            'Show-DomeniaQueryCatalogDetails',
            'Use-DomeniaQueryCatalogField',
            'Update-DomeniaQueryOperators',
            'Update-DomeniaQueryLibraryControls',
            'Start-DomeniaQueryLibraryLoad',
            'Complete-DomeniaQueryLibraryLoad',
            'Fail-DomeniaQueryLibraryLoad',
            'Update-DomeniaQueryLibrary',
            'Show-DomeniaQueryLibraryDetails',
            'Use-DomeniaQueryLibrarySelection',
            'Reset-DomeniaQueryResults',
            'Set-DomeniaQueryDraft',
            'Get-DomeniaQueryDraft',
            'Save-DomeniaQueryLibraryState',
            'Invoke-DomeniaQueryAction',
            'Request-DomeniaQueryEvaluation',
            'Get-DomeniaQueryWidgetRecipes',
            'Start-DomeniaQueryEvaluation',
            'Complete-DomeniaQueryEvaluation',
            'Fail-DomeniaQueryEvaluation',
            'Start-DomeniaQueryExport',
            'Complete-DomeniaQueryExport',
            'Fail-DomeniaQueryExport',
            'Get-DomeniaQueryBoardEntry',
            'Test-DomeniaSearchQueryRow',
            'Show-DomeniaFleetWidgetDetails',
            'Get-DomeniaQuerySelectedRow',
            'Show-DomeniaQueryObjectDetails',
            'Show-DomeniaAttentionInWorkshop',
            'Initialize-DomeniaQueryAdvanced',
            'Update-DomeniaQueryInstanceFields',
            'Update-DomeniaQueryAdvancedDraft',
            'New-DomeniaQueryUiClause',
            'Invoke-DomeniaQueryAdvancedAction'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-BoardFleet.Model.ps1','Domenia-Park.UI.ps1','Domenia-Probes.Model.ps1','Domenia-Engine.UI.ps1','Domenia-Widgets.UI.ps1','Domenia-Query.Model.ps1'); File='Domenia-Refresh.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaOuRefreshContext',
            'Test-DomeniaOuRefreshCurrent',
            'Update-DomeniaOuRefreshUi',
            'Stop-DomeniaOuRefresh',
            'Fail-DomeniaOuRefresh',
            'Set-DomeniaOuRefreshAwaitingCommit',
            'Complete-DomeniaOuRefreshCommit',
            'Get-DomeniaOuRefreshProbePlan',
            'Invoke-DomeniaOuRefresh',
            'Invoke-DomeniaOuRefreshTick',
            'Complete-DomeniaOuRefreshTargets',
            'Fail-DomeniaOuRefreshTargets',
            'Update-DomeniaOuRefreshFromPark'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Workstation.Model.ps1'); File='Domenia-QuerySchema.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertFrom-DomeniaWqlSelect',
            'Assert-DomeniaQuerySchemaTarget',
            'Get-DomeniaQuerySchemaRequestKey',
            'New-DomeniaQueryReadDefinition',
            'Assert-DomeniaQueryReadDefinition',
            'Get-DomeniaQueryReadDefinitionFields',
            'Add-DomeniaQueryDetailRecords'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-QuerySchema.Model.ps1','Domenia-Common.Model.ps1','Domenia-Guard.Model.ps1','Domenia-ProbeDetails.Model.ps1'); File='Domenia-QuerySchema.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaQuerySchemaWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-QuerySchema.Model.ps1','Domenia-QuerySchema.Worker.ps1','Domenia-Query.UI.ps1','Domenia-Query.Model.ps1'); File='Domenia-QuerySchema.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaQuerySchemaUi',
            'Invoke-DomeniaQuerySchemaAction',
            'Complete-DomeniaQuerySchemaCollected',
            'Fail-DomeniaQuerySchemaCollected',
            'Complete-DomeniaQuerySchemaStored',
            'Fail-DomeniaQuerySchemaRead'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Query.UI.ps1','Domenia-Query.Model.ps1','Domenia-Query.Worker.ps1','Domenia-Storage.UI.ps1'); File='Domenia-QueryDetails.UI.ps1'; DotSource=$true; Functions=@(
            'Start-DomeniaQueryDetailRead',
            'Test-DomeniaQueryDetailReadCurrent',
            'Request-DomeniaQueryDetailPage',
            'Complete-DomeniaQueryDetailPage',
            'Fail-DomeniaQueryDetailPage',
            'Start-DomeniaQueryCompute',
            'Move-DomeniaQueryDetailPage',
            'Complete-DomeniaQueryCollectionPage',
            'Fail-DomeniaQueryCollectionPage'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-QueryLibrary.Model.ps1'); File='Domenia-QueryTransfer.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaQueryTransferWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-QueryTransfer.Worker.ps1','Domenia-Query.UI.ps1','Domenia-QueryLibrary.Store.UI.ps1'); File='Domenia-QueryTransfer.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaQueryTransferUi',
            'Invoke-DomeniaQueryTransfer',
            'Complete-DomeniaQueryTransfer',
            'Fail-DomeniaQueryTransfer',
            'Start-DomeniaQueryImport',
            'Submit-DomeniaQueryImportNext',
            'Complete-DomeniaQueryImportItem',
            'Fail-DomeniaQueryImportItem'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Continuity.Model.ps1'); File='Domenia-SearchWorkspace.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaSearchWorkspace',
            'Get-DomeniaSearchSelectionPlan',
            'ConvertTo-DomeniaComparisonText',
            'Get-DomeniaComputerComparison'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-SearchWorkspace.Model.ps1','Domenia-Search.UI.ps1','Domenia-Live.UI.ps1','Domenia-Storage.UI.ps1'); File='Domenia-SearchWorkspace.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaResultPresentation',
            'Restore-DomeniaResultPresentation',
            'Get-DomeniaSearchWorkspaces',
            'Update-DomeniaSearchWorkspaces',
            'Save-DomeniaSearchWorkspace',
            'Remove-DomeniaSearchWorkspace',
            'Undo-DomeniaSearchWorkspace',
            'Open-DomeniaSearchWorkspace',
            'Update-DomeniaSearchFilterChips',
            'Request-DomeniaSearchInspection',
            'Test-DomeniaSearchInspectionCurrent',
            'Complete-DomeniaSearchInspection',
            'Fail-DomeniaSearchInspection',
            'Switch-DomeniaSearchPreview',
            'Initialize-DomeniaSearchWorkspace'
        ) }
    )
}

function Get-DomeniaRuntimeModuleValue {
    # Optional plan field (Phase, Requires) read without depending on the rule modules.
    param($Module,[string]$Name,$Default)
    $property = $Module.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-DomeniaRuntimeTypePlan {
    # Immutable C# 5 types compiled before the rule modules (Add-Type of Windows PowerShell 5.1).
    @(
        [pscustomobject]@{ File='Domenia-Live.Types.cs'; Types=@('Domenia.Live.ResultRow','Domenia.Live.OperationRow') }
        [pscustomobject]@{ File='M4D.Admin.Common.Query.dll'; Types=@('M4D.Admin.Common.Query.QueryEngine'); SHA256='da97976108351a9e24552f18de2e02b4e5b454b438c461cb2317c427c610b391' }
        [pscustomobject]@{ File='Domenia.Native.dll'; Types=@('Domenia.Native.ObservationReader','Domenia.Native.ObservationIdentityReader','Domenia.Native.ProbeBatch'); SHA256='6e3b293fc08cae9b1660a48ebd7e2533ea2304711a169f61d329b92510530a2a' }
        [pscustomobject]@{ File='Domenia-Identity.Types.cs'; Types=@('Domenia.SelectionIdentity','Domenia.PlanChange','Domenia.InterventionPlan') }
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
$script:DomeniaStartupPlan = $null
try {
    $ErrorActionPreference = 'Stop'
    # Check the entire declared set before importing the first module.
    foreach ($domeniaType in @(Get-DomeniaRuntimeTypePlan)) {
        $domeniaTypePath = Join-Path $domeniaImportRoot $domeniaType.File
        if (-not [IO.File]::Exists($domeniaTypePath)) {
            throw [IO.FileNotFoundException]::new(
                "DOMENIA_MODULE_MISSING : $($domeniaType.File). Reinstallez le paquet complet.",
                $domeniaTypePath)
        }
        if($null -ne $domeniaType.PSObject.Properties['SHA256']){
            $domeniaActualHash=(Get-FileHash -LiteralPath $domeniaTypePath -Algorithm SHA256 -ErrorAction Stop).Hash
            if($domeniaActualHash -ine [string]$domeniaType.SHA256){throw 'DOMENIA_LIBRARY_HASH : bibliothèque commune différente du paquet attendu. Réinstallez le paquet complet.'}
            foreach($domeniaTypeName in @($domeniaType.Types)){
                $domeniaLoadedType=$domeniaTypeName -as [type]
                if($null -ne $domeniaLoadedType){
                    $loadedPath=[string]$domeniaLoadedType.Assembly.Location
                    if(-not $loadedPath -or (Get-FileHash -LiteralPath $loadedPath -Algorithm SHA256).Hash -ine [string]$domeniaType.SHA256){throw 'DOMENIA_LIBRARY_VERSION : une autre bibliothèque est déjà chargée. Redémarrez Domenia.'}
                }
            }
        }
    }
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
    # Types: compiled once per process; a type already loaded from the same file is kept.
    foreach ($domeniaType in @(Get-DomeniaRuntimeTypePlan)) {
        $domeniaMissingTypes = @(@($domeniaType.Types) | Where-Object { $null -eq ($_ -as [type]) })
        if ($domeniaMissingTypes.Count -eq 0) { continue }
        try { Add-Type -Path (Join-Path $domeniaImportRoot $domeniaType.File) -ErrorAction Stop }
        catch {
            throw [InvalidOperationException]::new(
                "DOMENIA_MODULE_TYPES : echec de compilation de $($domeniaType.File). $($_.Exception.Message)",
                $_.Exception)
        }
    }
    # Bootstrap phase: shared helpers and the startup-plan rules themselves.
    $domeniaImported = @{}
    foreach ($domeniaModule in $domeniaImportPlan) {
        if (-not $domeniaModule.DotSource) { continue }
        if ([string](Get-DomeniaRuntimeModuleValue $domeniaModule 'Phase' 'Modules') -ne 'Bootstrap') { continue }
        $domeniaModulePath = Join-Path $domeniaImportRoot $domeniaModule.File
        try { . $domeniaModulePath }
        catch {
            throw [InvalidOperationException]::new(
                "DOMENIA_MODULE_IMPORT : echec de $($domeniaModule.File). $($_.Exception.Message)",
                $_.Exception)
        }
        $domeniaImported[[string]$domeniaModule.File] = $true
    }
    # D011: phases, dependencies, cycles and duplicate providers are refused before the first business module.
    $script:DomeniaStartupPlan = Test-DomeniaStartupPlan -Modules $domeniaImportPlan
    if (-not [bool]$script:DomeniaStartupPlan.Valid) {
        throw [InvalidOperationException]::new(
            'DOMENIA_MODULE_PLAN : ' + ((@($script:DomeniaStartupPlan.Errors)) -join ' | '))
    }
    $domeniaByFile = @{}
    foreach ($domeniaModule in $domeniaImportPlan) { $domeniaByFile[[string]$domeniaModule.File] = $domeniaModule }
    foreach ($domeniaFile in @($script:DomeniaStartupPlan.Order)) {
        $domeniaModule = $domeniaByFile[[string]$domeniaFile]
        # Experience is already dot-sourced by UX. Validate it without importing
        # it a second time and resetting its state.
        if ($null -eq $domeniaModule -or -not $domeniaModule.DotSource -or $domeniaImported.ContainsKey([string]$domeniaFile)) { continue }
        $domeniaModulePath=Join-Path $domeniaImportRoot $domeniaModule.File
        try {
            . $domeniaModulePath
        }
        catch {
            throw [InvalidOperationException]::new(
                "DOMENIA_MODULE_IMPORT : echec de $($domeniaModule.File). $($_.Exception.Message)",
                $_.Exception)
        }
        $domeniaImported[[string]$domeniaFile] = $true
    }
    $script:DomeniaRuntimeImports = @(Assert-DomeniaRuntimeImports -ModuleRoot $domeniaImportRoot)
}
finally {
    $ErrorActionPreference = $domeniaImportErrorAction
}
