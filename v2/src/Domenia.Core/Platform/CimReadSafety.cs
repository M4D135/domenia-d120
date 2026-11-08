using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Shared refusal list from Domenia 1 Get-DomeniaMsiProviderClassNames. It contains the MSI provider classes and their
/// generic ancestors whose enumeration reaches that provider. This metadata never enumerates a provider or runs a command.
/// </summary>
public static class CimReadSafety
{
    public const int MaximumSelectLength = 4_000;
    public static ImmutableArray<string> MsiProviderClassNames { get; } =
    [
        "Win32_Product", "Win32_ProductCheck", "Win32_ProductResource", "Win32_ProductSoftwareFeatures",
        "Win32_SoftwareFeature", "Win32_SoftwareFeatureAction", "Win32_SoftwareFeatureCheck", "Win32_SoftwareFeatureParent", "Win32_SoftwareFeatureSoftwareElements",
        "Win32_SoftwareElement", "Win32_SoftwareElementAction", "Win32_SoftwareElementCheck", "Win32_SoftwareElementCondition", "Win32_SoftwareElementResource",
        "Win32_InstalledSoftwareElement", "Win32_Patch", "Win32_PatchFile", "Win32_PatchPackage", "Win32_Property", "Win32_Binary", "Win32_ApplicationService", "Win32_ApplicationCommandLine",
        "Win32_CommandLineAccess", "Win32_ActionCheck", "Win32_CheckCheck", "Win32_Condition", "Win32_LaunchCondition", "Win32_ReserveCost", "Win32_ServiceControl",
        "Win32_ServiceSpecification", "Win32_ServiceSpecificationService", "Win32_ShortcutAction", "Win32_ShortcutSAP", "Win32_BindImageAction", "Win32_ClassInfoAction",
        "Win32_CreateFolderAction", "Win32_DuplicateFileAction", "Win32_ExtensionInfoAction", "Win32_FontInfoAction", "Win32_MIMEInfoAction", "Win32_MoveFileAction",
        "Win32_PublishComponentAction", "Win32_RegistryAction", "Win32_RemoveFileAction", "Win32_RemoveIniAction", "Win32_SelfRegModuleAction", "Win32_TypeLibraryAction",
        "Win32_DirectorySpecification", "Win32_EnvironmentSpecification", "Win32_FileSpecification", "Win32_IniFileSpecification", "Win32_ProgIDSpecification",
        "Win32_ODBCAttribute", "Win32_ODBCDataSourceAttribute", "Win32_ODBCDataSourceSpecification", "Win32_ODBCDriverAttribute", "Win32_ODBCDriverSoftwareElement",
        "Win32_ODBCDriverSpecification", "Win32_ODBCSourceAttribute", "Win32_ODBCTranslatorSpecification",
        "Win32_MSIResource", "Win32_SettingCheck", "Win32_ManagedSystemElementResource",
        "CIM_Product", "CIM_ProductSoftwareFeatures", "CIM_SoftwareFeature", "CIM_SoftwareFeatureSoftwareElements", "CIM_SoftwareElement",
        "CIM_SoftwareElementActions", "CIM_SoftwareElementChecks", "CIM_InstalledSoftwareElement", "CIM_Action", "CIM_Check", "CIM_Component", "CIM_Dependency",
        "CIM_CopyFileAction", "CIM_CreateDirectoryAction", "CIM_DirectoryAction", "CIM_DirectorySpecification", "CIM_FileAction", "CIM_FileSpecification",
        "CIM_RemoveFileAction", "CIM_Service", "CIM_ServiceAccessBySAP", "CIM_ServiceAccessPoint", "CIM_Setting", "CIM_LogicalElement", "CIM_ManagedSystemElement",
    ];

    public static FrozenSet<string> MsiProviderClasses { get; } = MsiProviderClassNames.ToFrozenSet(StringComparer.OrdinalIgnoreCase);
}
