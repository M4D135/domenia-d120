using System.Collections.Immutable;

namespace Domenia.Core.Queries;

/// <summary>Documented provider codes remain numeric in recipes and readings; labels are presentation only.
/// These are SELECT properties of Win32_EncryptableVolume, never calls to its mutating methods.</summary>
internal static class QueryInstanceChoices
{
    internal const string BitLockerSource = "https://learn.microsoft.com/en-us/windows/win32/secprov/win32-encryptablevolume";
    internal const string EncryptionSource = "https://learn.microsoft.com/en-us/windows/win32/secprov/getencryptionmethod-win32-encryptablevolume";
    internal const string EncryptionMap = "Map:0=Non chiffré;1=AES 128 avec diffuseur;2=AES 256 avec diffuseur;3=AES 128;4=AES 256;5=Chiffrement matériel;6=XTS-AES 128;7=XTS-AES 256;4294967295=Méthode inconnue";

    internal static bool IsBitLocker(QueryProbe probe) => probe.Class.Equals("Win32_EncryptableVolume", StringComparison.OrdinalIgnoreCase)
        && probe.Namespace.Equals(@"root\cimv2\Security\MicrosoftVolumeEncryption", StringComparison.OrdinalIgnoreCase);

    internal static string Label(QueryProbe probe, string property) => !IsBitLocker(probe) ? property : property switch
    {
        "DriveLetter" => "Volume",
        "DeviceID" => "Identifiant du volume",
        "PersistentVolumeID" => "Identifiant persistant du volume",
        "ProtectionStatus" => "Protection BitLocker",
        "ConversionStatus" => "État du chiffrement",
        "EncryptionMethod" => "Méthode de chiffrement",
        _ => property,
    };

    internal static ImmutableArray<QueryChoice> Choices(QueryProbe probe, string property, QueryFieldKind kind)
    {
        if (kind != QueryFieldKind.Number || !IsBitLocker(probe)) return [];
        // GetEncryptionMethod documents value 7 as XTS-AES 256, without a diffuser (the class overview has a typo).
        return property switch
        {
            "EncryptionMethod" => [Code(0, "Non chiffré"), Code(1, "AES 128 avec diffuseur"), Code(2, "AES 256 avec diffuseur"),
                Code(3, "AES 128"), Code(4, "AES 256"), Code(5, "Chiffrement matériel"), Code(6, "XTS-AES 128"),
                Code(7, "XTS-AES 256"), Code(uint.MaxValue, "Méthode inconnue")],
            "ProtectionStatus" => [Code(0, "Protection désactivée"), Code(1, "Protection activée"), Code(2, "Protection inconnue")],
            "ConversionStatus" => [Code(0, "Entièrement déchiffré"), Code(1, "Entièrement chiffré"), Code(2, "Chiffrement en cours"),
                Code(3, "Déchiffrement en cours"), Code(4, "Chiffrement suspendu"), Code(5, "Déchiffrement suspendu")],
            _ => [],
        };
    }

    private static QueryChoice Code(decimal value, string label) => new(label, QueryValue.FromNumber(value));
}
