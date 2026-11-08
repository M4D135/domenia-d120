using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Core;

/// <summary>Version of the executed projection/interpretation, calculated once per immutable declaration, never per machine.</summary>
public static class ProbeDefinitionIdentity
{
    private sealed record Value(string Hash);
    private static readonly ConditionalWeakTable<ProbeDefinition, Value> Scalar = new();
    private static readonly ConditionalWeakTable<ProbeInfo, Value> Detailed = new();
    public static string Of(ProbeDefinition definition) => PersonalProbeCatalog.IsKey(definition.Id) ? definition.Id[7..]
        : Scalar.GetValue(definition, static p => new(Hash(JsonSerializer.Serialize(new
        { Contract = "Domenia.ScalarProbe/1", p.Id, p.Namespace, p.Class, p.Properties, p.Filter, p.Mode, p.Transform, p.SkipOnDc,
            Fields = p.Fields.Select(f => new { f.Name, f.CimType, f.Kind, f.IsArray, f.Unit }) })))).Hash;
    public static string Of(ProbeInfo definition) => Detailed.GetValue(definition, static p => new(Hash(JsonSerializer.Serialize(new
        { Contract = "Domenia.DetailedProbe/1", p.Id, p.Namespace, p.Class, p.Properties, p.Filter, p.Reading })))).Hash;
    public static bool Valid(string? hash) => hash is null || hash.Length == 64 && hash.All(char.IsAsciiHexDigitLower);
    public static bool Current(string id, string? hash) => PersonalProbeCatalog.IsKey(id)
        ? hash is null || hash == id[7..] // The personal key already is the full immutable declaration proof.
        : Domenia.Core.Accueil.ProbeCatalog.Find(id) is { } definition && hash == Of(definition);
    public static bool Current(ProbeDefinition definition, string? hash) => PersonalProbeCatalog.IsKey(definition.Id) && hash is null || hash == Of(definition);
    public static bool Current(ProbeInfo definition, string? hash) => hash == Of(definition);
    private static string Hash(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
}
