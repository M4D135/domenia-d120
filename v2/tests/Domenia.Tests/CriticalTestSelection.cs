namespace Domenia.Tests;

/// <summary>Release gate selected after David's 25/10/2026 decision: critical VM checks, not an exhaustive suite.
/// Kept explicit and checked against actual discovered tests; native domain acceptance is a separate desktop run.</summary>
internal static class CriticalTestSelection
{
    internal static readonly string[] Classes =
    [
        "WriteDeliveryTests", "WriteReceiptStateTests", "DirectoryNativeWriteBoundaryTests", "NativePosteRemoteWriteTests", "RemoteWriteTransportTests", "OperationCredentialNeedsTests", "RemoteProgramSafetyTests", "RemoteTaskReadTests", "RemoteTaskReadExtendedTests", "RemotePsExecPlanTests",
        "RuntimeConfigurationTests", "RuntimeSecurityPolicyTests", "SectionScopeFollowTests", "RuntimePlanTests", "StartupBoundaryTests", "StartupPresentationTests", "HostShutdownTests", "HostIncidentReportTests",
        "RequestTraceTests", "SessionDiagnosticTests", "WorkstationDetailedProbeTests", "ShellTests", "LocalStorageDiagnosticTests", "VaultIdentityPreferenceTests", "CollectionStorageAdmissionTests", "CollectionLastKnownTests", "NativeStorageBoundaryTests", "StorageAtomicIndexTests", "FicheTests", "PosteBoardLayoutTests", "LegacyCompatibilityFilesTests", "LegacyWorkspaceMigrationTests", "PreferenceLimitsTests", "StorageProcessTests", "DirectoryObservedFieldTests", "DirectoryProgressiveStorageTests", "CollectionWriteContextTests", "NativePurgeContractTests", "NativeStorageSwitchTests", "NativeStorageRetentionTests", "NativeStorageWriterTests", "SettingsCompletionTests",
        "DirectoryBranchTests", "DirectoryBranchCompositionTests", "LegacyAccountProjectionTests",
        "DirectoryValueTests", "AdValueReadingTests", "AdProjectionTests", "DistinguishedNameTests", "ExplainableFactsTests",
        "AdAuthenticationGateTests", "AdLargeFleetReaderTests", "AdRangeMaterializationTests", "AdTransportTests", "AdFicheObjectTests", "AdFicheReaderTests", "AdRelationComparisonTests",
        "SessionWritePolicyTests", "AdBoundaryTests", "AdSessionIdentityTests", "WorkingScopeTests", "DashboardOperationsTests", "DashboardCalculatorTests", "DirectoryCoverageTests", "DomainAccountRefreshTests", "WorkstationPresenceTests", "AdSearchScopeTests", "ShellOperationsTests",
        "DirectoryCapabilityRefusalTests", "NativeWorkstationIdentityTests", "OperationAccessBoundaryTests", "SecretMetadataRecoveryTests", "WriteConsultationTests", "SecretBoundaryCampaignTests", "AccountAccessLifetimeTests", "WriteCircuitTests", "WriteClosingTests", "ReceiptStoreTests", "ReceiptStoragePayloadTests", "AdAccountWriteTests", "AdFicheWriteTests",
        "CredentialVaultTests", "ModeResolverTests", "LoginSelectionSecurityTests", "AuthenticationPolicyTests", "CredentialVaultPresentationTests", "AdAccountsAccessTests", "AdPosteLastUserTests", "AdPosteNetworkTests", "AdRelationConsoleTests", "AdSearchTests",
        "SharedParkApplyTests", "SharedParkPublicationAclTests", "NativeSharedParkIntegrationTests", "NativeStorageBackupTests", "NativeBackupBoundaryTests", "AdLocalMaintenanceTests", "BackupPreferenceRestoreTests", "BackupScheduleEvidenceTests", "StorageBackupSchedulerRecoveryTests",
        "NativeReadWorkerTests", "PhysicalWorkBudgetTests", "BridgeSchedulingTests", "QueueTimingTests", "OperationFailureTests", "EngineSchedulingContractTests", "SyncCalibrationTests", "RuntimeResourceTests", "ProviderReadMeasuresTests", "AdPageBufferTests", "DirectoryAvailabilityTests", "CimProjectionPlanTests", "NativeProbeContractTests", "AdConsoleIdentityCacheTests",
        "CollectionAdmissionTests", "CollectionPreferenceContractTests", "CollectionReadRetryTests", "CollectionReadRetryNativeTests", "CollectionCachePolicyTests", "CacheLifetimeTests", "ProbeDefinitionCacheTests", "FicheCacheContractTests", "FicheVisitPolicyTests", "ProbeFailureIntegrationTests", "NativeProgressiveProbeCacheTests", "LocalReadContractsTests", "UserLocalStorageAccessTests", "PosteDetailPersistenceTests", "PosteDetailProjectionTests", "CollectionNetworkPolicyTests", "QueryIdentityCacheTests", "QueryRefreshTests", "QueryRefreshLargeFleetTests",
        "AdministrationIdentityTests", "MachineAdmissionInspectionTests", "RemoteCollectionSettingsTests", "ReadPerformanceTests",
        "QueryTemplateLibraryTests", "QueryInstanceChoiceTests", "AtelierBitLockerWidgetTests", "BitLockerStatusTests", "FleetQueryWidgetTests",
        "NativeFleetCacheTests", "FleetRowsScaleTests", "QueryCacheScaleTests", "NativeSettingsInspectionTests", "NativeStoragePurgeTests", "SearchOperationsTests",
        "CollectionOneShotAccessTests", "AdRelationProbeTests",
        "RemoteScriptReadTests", "FrozenDirectoryValidationTests", "FleetProbeScaleTests", "CampaignInventoryMergeTests",
        "AutomationCommandTests", "AutomationLocalStoreTests",
        "NativeAcceptanceReadSelectionTests", "NativeAcceptanceGuardTests", "NativeAcceptanceEvidenceTests",
        "CollectionQueueMeasurementsTests", "SqliteSessionMeasurementsTests", "OperationPhaseTests", "FleetMemoryHealthTests", "HomeMemoryCollectionTests", "HomeCollectionScopeTests", "HomeSearchSelectionTests", "HomeQueryDraftTests", "QueryRecordQualityTests", "QueryLibrarySnapshotTests", "QueryLegacyJsonMigrationTests", "QueryImplementationProvenanceTests", "ProbeDeclarationTests", "CimReadSafetyTests", "ProbeFilterTests",
        "PersonalProbeTests", "PersonalProbeNativeTests",
        "PostePersonalProbeTests", "PostePersonalProbeNativeTests",
        "QueryPersonalProbeTests", "QueryPersonalProbeNativeTests",
        "AccueilDurablePipelineTests", "AccueilWidgetCollectionTests", "AdAccueilTests", "PlatformTests",
        "NativePhysicalCompletionTests", "SearchInventoryAttemptsTests",
        "CampaignSharedInventoryTests", "SharedInventoryReadTests",
        "CampaignQueryPhysicalCompletionTests",
        "CompiledOperationContractTests", "PackagePublisherTrustTests", "PackageIntegrityTests", "PackageLifecycleTests", "PackageUpdateTests", "PackageUpdateChannelTests",
        "DemonstrationSessionTests", "SimulationIsolationTests", "QueryReferencePatchTests", "ReferencePatchScopeTests",
        "PreferenceAtomicUpdateTests", "BoardLayoutHistoryTests", "BoardLayoutTransferTests", "FleetLayoutPresentationTests", "PortableConfigurationTests",
        "AccountWritePolicyTests", "BridgeRemainingSharedReadTests", "ConfigurationSeedTests", "ConfigurationDecisionTests", "OfflineDossierLocalStoreTests", "GuiElementPolicyTests", "LoginPresentationTests", "StartupPreflightTests", "LaunchArgumentsTests", "HomeCampaignPersistenceTests", "LargeCampaignPersistenceTests", "AdSearchCheckpointTests", "CampaignPersistenceTests", "SearchCampaignStopTests", "AdaptiveReadBudgetTests", "WorkstationCapabilityTests",
    ];
}
