using System.Collections.Immutable;
using Microsoft.Win32;

namespace Domenia.App;

/// <summary>Read-only machine policy, outside the delivered package and its writable manifests.</summary>
internal sealed record PackagePublisherPolicy(ImmutableArray<string> CertificateSha256, bool RequirePinnedPublisher, string? Problem = null)
{
    internal string Identity => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(
        (RequirePinnedPublisher ? "required" : "optional") + "\n" + string.Join("\n", CertificateSha256.Order(StringComparer.Ordinal)) + "\n" + Problem)));
    internal const string RegistryPath = @"Software\Policies\Domenia\Publisher";
    internal static PackagePublisherPolicy Unconfigured { get; } = new([], false);
    internal static string Pin(string value)
    {
        if (value.Length > 256) throw new InvalidDataException("Empreinte éditeur trop longue.");
        var normalized = string.Concat(value.Where(c => c is not (' ' or ':' or '\t' or '\r' or '\n')));
        if (normalized.Length != 64 || !normalized.All(char.IsAsciiHexDigit))
            throw new InvalidDataException("Une empreinte SHA-256 de certificat signataire (64 chiffres hexadécimaux) est requise.");
        return normalized.ToUpperInvariant();
    }
    internal static PackagePublisherPolicy Parse(IEnumerable<string> pins, bool required)
    {
        var values = pins.Take(17).Select(Pin).ToImmutableArray();
        if (values.Length > 16 || values.Distinct(StringComparer.Ordinal).Count() != values.Length || required && values.IsEmpty)
            throw new InvalidDataException("Politique éditeur ambiguë, vide ou supérieure à seize certificats.");
        return new(values, required);
    }
    internal static PackagePublisherPolicy ReadMachine()
    {
        try
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var policy = machine.OpenSubKey(RegistryPath, writable: false);
            if (policy is null) return Unconfigured;
            if (policy.ValueCount > 2 || policy.GetValueNames().Any(n => n is not ("CertificateSha256" or "RequirePinnedPublisher")))
                throw new InvalidDataException("Champs de politique éditeur non reconnus.");
            var pins = policy.GetValue("CertificateSha256", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            var required = policy.GetValue("RequirePinnedPublisher", null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (pins is not null && (policy.GetValueKind("CertificateSha256") != RegistryValueKind.MultiString || pins is not string[])
                || required is not null && (policy.GetValueKind("RequirePinnedPublisher") != RegistryValueKind.DWord || required is not int flag || flag is not (0 or 1)))
                throw new InvalidDataException("Types de politique éditeur invalides.");
            return Parse(pins as string[] ?? [], required is int value && value == 1);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException or InvalidDataException or ArgumentException)
        { return new([], true, "Politique machine éditeur illisible ; aucune admission par défaut (" + error.GetType().Name + ")."); }
    }
}
