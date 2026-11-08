using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Domenia.Core;

/// <summary>Complete dated local answer, bounded before anything is written to a pipe or destination.</summary>
public sealed record AutomationAnswer(AutomationRequest Request, JsonObject Source, JsonArray Items, bool Truncated,
    IReadOnlyList<string> ExcludedFields, IReadOnlyList<string> Notes, DateTimeOffset GeneratedUtc)
{
    public JsonObject Envelope() => new()
    {
        ["Contract"] = ShellAutomation.ContractName, ["Command"] = Request.Command,
        ["GeneratedUtc"] = GeneratedUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
        ["Source"] = Source.DeepClone(), ["Perimeter"] = JsonSerializer.SerializeToNode(Request.Perimeter),
        ["Limit"] = Request.Limit, ["Count"] = Items.Count, ["Truncated"] = Truncated,
        ["ExcludedFields"] = JsonSerializer.SerializeToNode(ExcludedFields), ["Notes"] = JsonSerializer.SerializeToNode(Notes),
        ["Items"] = Items.DeepClone(), ["Meaning"] = ShellAutomation.Meaning,
    };

    public string Text()
    {
        if (Request.Format != "Csv") return Envelope().ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        string[] columns = Request.Command switch
        {
            "postes" => ["Guid", "Nom", "DN", "Etat", "Description", "DerniereConnexion", "ModifieAD", "SynchroniseUtc", "Controleur", "Systeme", "CreeAD", "MotDePasseMachineDefini", "FaitsLusUtc"],
            "associations" => ["Poste", "Compte", "Source", "Confiance", "VerifieAD", "ObserveUtc", "Details", "CompteGuid", "PosteGuid", "CompteDN", "PosteDN"],
            _ => throw new InvalidOperationException("Format CSV non disponible pour cette commande."),
        };
        static string Quote(string value) => "\"" + ShellCsv.Neutralize(value).Replace("\"", "\"\"", StringComparison.Ordinal) + "\"";
        var text = new StringBuilder(string.Join(';', columns.Select(Quote))).Append("\r\n");
        foreach (var item in Items)
            text.Append(string.Join(';', columns.Select(column => Quote(item?[column]?.ToString() ?? "")))).Append("\r\n");
        return text.ToString();
    }
}
