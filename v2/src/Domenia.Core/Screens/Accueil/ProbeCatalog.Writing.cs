using System.Text;
using System.Text.Json;

namespace Domenia.Core.Accueil;

public static partial class ProbeCatalog
{
    internal static string WriteDefinition(ProbeDefinition probe)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) { WriteDefinition(writer, probe); }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    /// <summary>Stable order and explicit values; representation and metadata changes create a new immutable personal key.</summary>
    internal static void WriteDefinition(Utf8JsonWriter writer, ProbeDefinition p)
    {
        writer.WriteStartObject();
        writer.WriteString("Id", p.Id); writer.WriteString("Category", p.Category); writer.WriteString("Name", p.Name);
        writer.WriteString("Namespace", p.Namespace); writer.WriteString("Class", p.Class);
        Strings("Properties", p.Properties); writer.WriteString("Filter", p.Filter); writer.WriteString("Mode", p.Mode);
        writer.WriteString("Transform", p.Transform); writer.WriteString("Visual", p.Visual);
        writer.WriteBoolean("Slow", p.Slow); writer.WriteBoolean("SkipOnDc", p.SkipOnDc); writer.WriteString("Origin", p.Origin);
        writer.WriteString("Description", p.Description); writer.WriteString("Rights", p.Rights); writer.WriteString("Compatibility", p.Compatibility);
        writer.WriteString("UnknownMeaning", p.UnknownMeaning); writer.WriteString("Limitations", p.Limitations);
        Strings("SourceUrls", p.SourceUrls);
        writer.WriteStartArray("Fields");
        foreach (var f in p.Fields)
        {
            writer.WriteStartObject(); writer.WriteString("Name", f.Name); writer.WriteString("CimType", f.CimType);
            writer.WriteString("Kind", f.Kind); writer.WriteBoolean("IsArray", f.IsArray); writer.WriteString("Unit", f.Unit);
            writer.WriteString("Description", f.Description); writer.WriteEndObject();
        }
        writer.WriteEndArray(); writer.WriteString("ProviderQualification", p.Qualification);
        if (p.Behavior is { } behavior)
        {
            writer.WriteStartObject("Behavior"); writer.WriteString("Reads", behavior.Reads); writer.WriteBoolean("Writes", behavior.Writes);
            writer.WriteString("Code", behavior.Code); Strings("Methods", behavior.Methods); writer.WriteString("Target", behavior.Target); writer.WriteEndObject();
        }
        if (p.Privilege is { } privilege)
        { writer.WriteStartObject("Privilege"); writer.WriteString("Level", privilege.Level); writer.WriteString("Text", privilege.Text); writer.WriteEndObject(); }
        if (p.Cost is { } cost)
        { writer.WriteStartObject("Cost"); writer.WriteString("Level", cost.Level); writer.WriteString("Reason", cost.Reason); writer.WriteEndObject(); }
        writer.WriteEndObject();
        void Strings(string name, IEnumerable<string> values)
        { writer.WriteStartArray(name); foreach (var value in values) { writer.WriteStringValue(value); } writer.WriteEndArray(); }
    }
}
