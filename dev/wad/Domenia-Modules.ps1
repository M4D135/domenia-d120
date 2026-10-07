#requires -Version 5.1
# Definition-only bootstrap, dot-sourced in the caller's scope.
# No window, timer, credential validation, database or network operation here.
# The list is closed: extra scripts beside these files are never auto-loaded.

function Get-DomeniaRuntimeModulePlan {
    @(
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
            'ConvertTo-DomeniaFlatText'
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
            'Test-DomeniaIdleAllows'
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
            'ConvertTo-DomeniaSavedView',
            'Split-DomeniaDn',
            'ConvertFrom-DomeniaDnValue',
            'Get-DomeniaDnParent',
            'Get-DomeniaOuDisplayPath',
            'Resolve-DomeniaOuRestore',
            'New-DomeniaNavHistory',
            'Get-DomeniaNavStateKey',
            'Push-DomeniaNavState',
            'Step-DomeniaNavHistory'
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
            'Select-DomeniaPrimaryRelation',
            'Resolve-DomeniaRelationStoragePlacement',
            'Get-DomeniaRelationStorageKey',
            'Get-DomeniaEvidenceKind',
            'Get-DomeniaEvidenceBadge',
            'Step-DomeniaAssociationState',
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
            'Get-DomeniaLinkConflicts'
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
            'Test-DomeniaDirectChildDn',
            'Test-DomeniaSecretRevealAllowed',
            'Get-DomeniaSecretExposurePolicy',
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
            'Get-DomeniaQuickDiagPlan',
            'Test-DomeniaQuickDiagAllowed',
            'ConvertTo-DomeniaQuickDiagFacts',
            'Get-DomeniaSessionEmptyText',
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
            'Get-DomeniaSuiteLaunchPlan'
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
            'Get-DomeniaStatusGlyph'
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
            'Get-DomeniaDryRunPolicy',
            'Invoke-DomeniaDryRun',
            'Get-DomeniaPostconditionRule',
            'Resolve-DomeniaPostcondition',
            'Get-DomeniaReceiptRequirement',
            'Get-DomeniaReceiptResumeState',
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
            'Get-DomeniaSessionEndPlan',
            'New-DomeniaBatchPlan',
            'Step-DomeniaBatch',
            'Get-DomeniaBatchReport',
            'Get-DomeniaRollbackKinds',
            'Get-DomeniaCompensation'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Access.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Support.Model.ps1'); File='Domenia-Insight.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaInsightText',
            'Get-DomeniaInsightRawMember',
            'Test-DomeniaInsightInertData',
            'Test-DomeniaInsightPseudonymKey',
            'Get-DomeniaInsightKeyedHash',
            'Test-DomeniaInsightFactObserved',
            'Get-DomeniaInsightFactReason',
            'Test-DomeniaVerdictAllowed',
            'Get-DomeniaInsightBlockerStep',
            'Get-DomeniaNextAction',
            'ConvertTo-DomeniaInsightLane',
            'ConvertTo-DomeniaInsightOutcomeText',
            'Get-DomeniaTimeline',
            'ConvertTo-DomeniaPseudonym',
            'ConvertTo-DomeniaInsightPseudoGuid',
            'ConvertTo-DomeniaInsightStepStatus',
            'ConvertTo-DomeniaInsightSubjectKind',
            'ConvertTo-DomeniaInsightMaskedNames',
            'New-DomeniaTicketReport',
            'ConvertTo-DomeniaInsightIncidentCode',
            'Group-DomeniaIncidents',
            'Get-DomeniaMetricProvenances',
            'New-DomeniaMetricStore',
            'Add-DomeniaMetricSample',
            'Get-DomeniaMetricSummary',
            'Test-DomeniaInsightTraceFieldName',
            'Get-DomeniaInsightTraceFields',
            'New-DomeniaTrace',
            'Set-DomeniaTraceEnabled',
            'Add-DomeniaTraceEvent',
            'Export-DomeniaTraceRows',
            'Test-DomeniaTraceExportTarget',
            'Test-DomeniaInsightSecretName',
            'Get-DomeniaInsightIdentifierKind',
            'ConvertTo-DomeniaInsightColumnName',
            'Test-DomeniaInsightPlainValue',
            'Test-DomeniaInsightPairValue',
            'Get-DomeniaInsightRemovedReason',
            'ConvertTo-DomeniaInsightFixtureValue',
            'Get-DomeniaInsightMembers',
            'ConvertTo-DomeniaInsightShape',
            'New-DomeniaReproFixture',
            'Test-DomeniaInsightJsonHasText',
            'Test-DomeniaReproFixtureSafe',
            'Test-DomeniaAssistantEndpoint',
            'ConvertTo-DomeniaInsightTextList',
            'New-DomeniaAssistantDossier',
            'ConvertTo-DomeniaInsightDataBlock',
            'New-DomeniaAssistantRequest',
            'ConvertFrom-DomeniaAssistantReply',
            'Get-DomeniaInsightJourneyOperations',
            'Test-DomeniaInsightJourneyOperation',
            'New-DomeniaInsightJourneyStep',
            'New-DomeniaInsightJourney',
            'Get-DomeniaTroubleshootingJourneys',
            'Test-DomeniaJourneyStepAllowed'
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
            'Step-DomeniaRelationsAssociation',
            'Update-DomeniaRelationsActions',
            'Update-DomeniaRelationEvidence',
            'Update-DomeniaRelationCandidateEvidence',
            'Refresh-DomeniaRelationViews',
            'Update-DomeniaRelationDetectionCounters',
            'Invoke-DomeniaRelationsTick',
            'Update-DomeniaRelationLinkIndex',
            'Get-DomeniaRelationsJournalPath',
            'Add-DomeniaRelationHistory',
            'Get-DomeniaRelationsRestorableEntry',
            'Test-DomeniaRelationsRestoreAvailable',
            'Add-DomeniaRelation',
            'Set-DomeniaRelationValue',
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
            'Get-DomeniaUxHeightPlan',
            'Set-DomeniaUxShortLayout',
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
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Shell.Model.ps1'); File='Domenia-Experience.UI.ps1'; DotSource=$false; Functions=@(
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
            'Test-DomeniaLiveRowInScope',
            'Get-DomeniaLiveProbeCode',
            'Get-DomeniaLiveCacheCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Live.Model.ps1','Domenia-Cache.Model.ps1','Domenia-Storage.UI.ps1'); File='Domenia-Live.UI.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaLiveIdentitySignal',
            'Initialize-DomeniaLive',
            'Reset-DomeniaLiveIdentity',
            'Stop-DomeniaLiveSearch',
            'Stop-DomeniaLiveProbes',
            'Stop-DomeniaLive',
            'Test-DomeniaLiveSearchActive',
            'Set-DomeniaLoginColumnVisible',
            'Update-DomeniaLoginColumnFromRows',
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
            'Fail-DomeniaLiveProbe',
            'Complete-DomeniaLiveCache',
            'Fail-DomeniaLiveCache',
            'Get-DomeniaLiveWorkerCount',
            'Get-DomeniaLiveDatabasePath',
            'Start-DomeniaLiveBackgroundWork',
            'Invoke-DomeniaLiveTick',
            'Test-DomeniaLiveBackgroundAllowed',
            'Update-DomeniaSearchMoreButton',
            'Invoke-DomeniaSearchMore'
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
        [pscustomobject]@{ File='Domenia-Continuity.Model.ps1'; DotSource=$true; Functions=@(
            'ConvertTo-DomeniaStateMap',
            'ConvertTo-DomeniaColumnLayout',
            'ConvertTo-DomeniaTreeBookmark',
            'Get-DomeniaChangeWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Continuity.Model.ps1','Domenia-Live.UI.ps1'); File='Domenia-Continuity.UI.ps1'; DotSource=$true; Functions=@(
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
            'Get-DomeniaOuRestoreDecision',
            'Show-DomeniaOuRestoreNotice',
            'Hide-DomeniaOuRestoreNotice',
            'Invoke-DomeniaOuRestoreRetry',
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
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Storage.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaStorageWorkerCode',
            'Get-DomeniaStorageUsageWorkerCode',
            'Get-DomeniaStoragePurgeWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Cache.Model.ps1','Domenia-Common.Model.ps1','Domenia-Release.Model.ps1','Domenia-Storage.Worker.ps1'); File='Domenia-Storage.UI.ps1'; DotSource=$true; Functions=@(
            'Initialize-DomeniaPersistence',
            'Add-DomeniaIndexPersistence',
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
            'Invoke-DomeniaIndexBackup'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Receipts.Worker.ps1'; DotSource=$true; Functions=@(
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
            'Invoke-DomeniaUiTaskDispatch',
            'Get-DomeniaDispatchIsolation',
            'New-DomeniaIsolatedReadPayload',
            'Register-DomeniaJobResources',
            'Sync-DomeniaJobResources',
            'Register-DomeniaOwnedTimer',
            'Register-DomeniaWorkerPool',
            'Add-DomeniaTaskSubscriber',
            'Invoke-DomeniaTaskSubscribers',
            'Remove-DomeniaQueuedTask',
            'Invoke-DomeniaQueuedTaskPromotion',
            'Register-DomeniaTaskOutcome',
            'Add-DomeniaTaskRuntimeMetric',
            'Test-DomeniaIdlePolicyEnabled',
            'Test-DomeniaBackgroundWorkAllowed',
            'Update-DomeniaIdlePolicy',
            'Initialize-DomeniaIdlePolicy',
            'Request-DomeniaIndexSearch',
            'Get-DomeniaLocalDatabasePathForRead',
            'Start-DomeniaIndexSearch',
            'Complete-DomeniaIndexSearchUi',
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
            'Invoke-DomeniaWorkView',
            'Get-DomeniaGridScrollViewer',
            'Get-DomeniaNavSnapshot',
            'Get-DomeniaVisiblePageName',
            'Enter-DomeniaNavSearch',
            'Exit-DomeniaNavSearch',
            'Update-DomeniaNavButtons',
            'Register-DomeniaNavLocation',
            'Restore-DomeniaNavState',
            'Invoke-DomeniaNavStep',
            'Initialize-DomeniaSearchUi'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@(); File='Domenia-Secrets.Worker.ps1'; DotSource=$true; Functions=@(
            'Get-DomeniaBitLockerListWorkerCode',
            'Get-DomeniaBitLockerKeyWorkerCode'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Common.Model.ps1','Domenia-Access.Model.ps1','Domenia-Access.UI.ps1','Domenia-Secrets.Worker.ps1'); File='Domenia-Secrets.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaBitLockerKeySelection',
            'Test-DomeniaSecretSingleExposure',
            'Get-DomeniaSecretIdentityReason',
            'Get-DomeniaSecretButtonExplanation',
            'Update-DomeniaSecretsPrerequisite',
            'Select-DomeniaSecretRow',
            'Start-DomeniaSecretReveal',
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
            'ConvertTo-DomeniaParkSession',
            'Test-DomeniaParkLinkChanged'
        ) }
        [pscustomobject]@{ Phase='Modules'; Requires=@('Domenia-Park.Model.ps1','Domenia-Relations.UI.ps1','Domenia-Storage.UI.ps1','Domenia-Inline.UI.ps1','Domenia-Engine.Worker.ps1'); File='Domenia-Park.UI.ps1'; DotSource=$true; Functions=@(
            'Test-DomeniaParkRunCurrent',
            'Update-DomeniaParkRunStatus',
            'Update-DomeniaParkControls',
            'Start-DomeniaOnlinePark',
            'Complete-DomeniaParkTargets',
            'Fail-DomeniaParkTargets',
            'Start-DomeniaParkRunTimer',
            'Stop-DomeniaOnlinePark',
            'Invoke-DomeniaParkRunTick',
            'Complete-DomeniaParkSession',
            'Fail-DomeniaParkSession',
            'Update-DomeniaParkResultRows'
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
        [pscustomobject]@{ File='Domenia-Live.Types.cs'; Types=@('Domenia.Live.ResultRow') }
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
