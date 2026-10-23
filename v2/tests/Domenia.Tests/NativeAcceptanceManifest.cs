using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core;

namespace Domenia.Tests;

internal sealed record NativeAcceptanceTarget(string Dn, Guid ObjectGuid, string Sid, DateTimeOffset CreatedAt, string Sam, string? Host);
internal sealed record NativeAcceptanceManifest(string Format, string RunId, string Machine, string Controller, string OperatorSid,
    string SourceCommit, string AssemblySha256, NativeAcceptanceTarget Canary, string? OriginalDescription,
    NativeAcceptanceTarget Group, NativeAcceptanceTarget Computer)
{
    internal const string Domain = "cnamts.local";
    internal const string Root = "DC=cnamts,DC=local";
    internal const string Scope = "OU=Domenia-Tests,DC=cnamts,DC=local";
    internal static readonly JsonSerializerOptions Json = new()
    { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter() } };

    internal static NativeAcceptanceManifest Parse(string text)
    {
        if (text.Length > 16_384) { throw new InvalidDataException("Manifeste trop long."); }
        using var document = JsonDocument.Parse(text, new() { MaxDepth = 8 });
        Unique(document.RootElement);
        var value = JsonSerializer.Deserialize<NativeAcceptanceManifest>(text, Json) ?? throw new InvalidDataException("Manifeste absent.");
        value.Validate(); return value;
    }
    private static void Unique(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) { return; }
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        { if (!names.Add(property.Name)) { throw new InvalidDataException("Clé dupliquée."); } Unique(property.Value); }
    }
    internal void Validate()
    {
        if (Format != "Domenia.NativeAcceptance/1" || !WritePlans.IsPlanId(RunId)
            || !SafeName(Machine, 63) || !SafeName(Controller, 253) || !Controller.EndsWith("." + Domain, StringComparison.OrdinalIgnoreCase)
            || OperatorSid is null || !OperatorSid.StartsWith("S-1-5-21-", StringComparison.Ordinal) || OperatorSid.Length > 100
            || !Hex(SourceCommit, 40) || !Hex(AssemblySha256, 64) || OriginalDescription?.Length > 512)
        { throw new InvalidDataException("Identité ou format de recette invalide."); }
        ValidateTarget(Canary); ValidateTarget(Group); ValidateTarget(Computer);
        if (new[] { Canary.ObjectGuid, Group.ObjectGuid, Computer.ObjectGuid }.Distinct().Count() != 3
            || Canary.Sid == OperatorSid || !Canary.Sam.StartsWith("domenia-canary", StringComparison.OrdinalIgnoreCase)
            || Canary.Host is not null || Group.Host is not null || !SafeName(Computer.Host, 253)
            || !Computer.Host!.EndsWith("." + Domain, StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Cibles de recette non dédiées ou ambiguës."); }
    }
    private static bool Hex(string? value, int length) => value?.Length == length && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static bool SafeName(string? name, int limit) => name is { Length: > 0 } && name.Length <= limit
        && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.') && name[0] != '.' && name[^1] != '.';
    internal static void ValidateTarget(NativeAcceptanceTarget? target)
    {
        if (target is null || target.ObjectGuid == Guid.Empty || target.CreatedAt == default || target.CreatedAt.Offset != TimeSpan.Zero
            || target.Sid is null || !target.Sid.StartsWith("S-1-5-21-", StringComparison.Ordinal) || target.Sid.Length > 100
            || target.Sam is not { Length: > 0 and <= 256 } || target.Sam.Any(char.IsControl)
            || target.Dn is not { Length: > 0 and <= 2048 } || !DistinguishedName.IsWithin(target.Dn, Scope, true)
            || DistinguishedName.AreEqual(target.Dn, Scope))
        { throw new InvalidDataException("Cible hors de l’OU de recette ou identité incomplète."); }
    }
    internal static void VerifyTarget(FicheEntry entry, NativeAcceptanceTarget expected, FicheKind kind)
    {
        ValidateTarget(expected);
        if (entry.Kind != kind || entry.ObjectGuid != expected.ObjectGuid || !DistinguishedName.AreEqual(entry.Dn, expected.Dn)
            || entry.Generalized("whenCreated") != expected.CreatedAt || entry.First("objectSid") != expected.Sid
            || !string.Equals(entry.First("sAMAccountName"), expected.Sam, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(entry.First("dNSHostName"), expected.Host, StringComparison.OrdinalIgnoreCase)
            || entry.Int32("adminCount") is > 0 || entry.First("isCriticalSystemObject")?.Equals("TRUE", StringComparison.OrdinalIgnoreCase) == true
            || entry.Int32("userAccountControl") is int flags && (flags & AdValues.ServerTrustAccount) != 0)
        { throw new InvalidDataException("Identité, portée ou protection de la cible différente du manifeste."); }
    }
    internal void VerifyPlan(WritePlan plan, string? before, string? after, string login)
    {
        if (plan.Simulated || plan.Kind != ObjectWrites.UpdateKind || !WritePlans.IsIntact(plan)
            || plan.Target.Kind != "user" || plan.Target.ObjectGuid != Canary.ObjectGuid.ToString("D")
            || !DistinguishedName.AreEqual(plan.Target.Dn, Canary.Dn) || plan.Target.SamAccountName != Canary.Sam
            || !string.Equals(plan.Controller, Controller, StringComparison.OrdinalIgnoreCase) || plan.Operator != login
            || plan.Changes.Length != 1 || plan.Changes[0].Attribute != "description" || plan.Changes[0].ReferenceGuid is not null
            || plan.Changes[0].BeforeValue != before || plan.Changes[0].AfterValue != after
            || plan.Changes[0].Kind is not (WriteChangeKind.Replace or WriteChangeKind.Clear or WriteChangeKind.Add))
        { throw new InvalidDataException("Plan différent du canari descriptif autorisé ; aucun envoi."); }
    }
}
