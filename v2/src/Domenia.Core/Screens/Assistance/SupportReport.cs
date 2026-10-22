using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>Layout of the support dossier: plain text (Domenia 1), GLPI (Markdown) or ServiceNow (work notes).</summary>
public enum ReportTemplate
{
    Text,
    Glpi,
    ServiceNow,
}

/// <summary>Everything the support dossier may hold; any part can be absent.</summary>
public sealed record SupportReportInput(
    SupportSnapshot? Snapshot,
    ImmutableArray<SupportFinding> Findings,
    SupportSnapshot? Before,
    SupportSnapshot? After,
    SupportIncident? Incident,
    string? TicketReference,
    ReportTemplate Template,
    DateTimeOffset Now,
    TimeZoneInfo Zone,
    string Build);

/// <summary>
/// Support dossier (Domenia 1 New-DomeniaSupportReport, New-DomeniaSupportUiReport, ConvertTo-DomeniaSupportHtml): ticket
/// reference, observed object, findings, provided attributes, A/B comparison, the explanation of one incident chosen by the
/// operator (never its raw message) and the limits. Domenia 2 adds the GLPI and ServiceNow layouts, keyed pseudonyms and the
/// SHA-256 fingerprint of the text; the HTML export keeps a strict policy (no script, its single style pinned by its hash).
/// </summary>
public static class SupportReport
{
    public const int TicketReferenceLimit = 80;

    public static ReportTemplate ParseTemplate(string? value) => value switch
    {
        "glpi" => ReportTemplate.Glpi,
        "servicenow" => ReportTemplate.ServiceNow,
        _ => ReportTemplate.Text,
    };

    /// <summary>Reference typed by the operator: cleaned, one line, 80 characters at most.</summary>
    public static string CleanReference(string? reference)
    {
        var text = SupportText.Flat(SupportText.Clean(reference ?? "", 256), 400);
        return text.Length > TicketReferenceLimit ? text[..TicketReferenceLimit] : text;
    }

    public static string Build(SupportReportInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var w = new Writer(input.Template);
        var c = FrenchText.Colon;
        var reference = CleanReference(input.TicketReference);
        w.Title("DOMENIA | DOSSIER SUPPORT");
        if (reference.Length > 0)
        {
            w.Line("Référence du ticket" + c + reference);
        }
        w.Line("Version" + c + SupportText.Clean(input.Build, 128));
        w.Line("Généré" + c + Local(input.Now, input.Zone) + " (" + input.Now.ToUniversalTime().ToString("yyyy'-'MM'-'dd' 'HH':'mm'Z'", CultureInfo.InvariantCulture) + ")");
        w.Line("Analyse locale" + c + "aucune écriture dans l’annuaire ni sonde réseau lancée par ce dossier.");
        w.Line("Document interne" + c + "il contient des identifiants et des métadonnées du parc. Relisez-le avant tout partage.");
        if (input.Snapshot is { } snapshot)
        {
            w.Section("Objet observé");
            w.Item("Nom" + c + snapshot.Name + " | Type" + c + snapshot.KindLabel);
            w.Item("Périmètre" + c + snapshot.Scope);
            w.Item("DN" + c + snapshot.Dn);
            w.Item("Source" + c + SourceLabel(snapshot.Source) + " | Lecture" + c + Local(snapshot.ObservedAt, input.Zone) + " | Capture" + c + Local(snapshot.CapturedAt, input.Zone));
            w.Section("Constats et vérifications");
            foreach (var finding in input.Findings)
            {
                w.Item("[" + finding.LevelLabel + "] " + finding.Title + " (" + finding.Code + ")");
                w.Sub("Élément observé" + c + finding.Evidence);
                w.Sub("Suite proposée" + c + finding.Next);
            }
            w.Section("Attributs fournis (liste limitée)");
            foreach (var field in snapshot.Fields.Where(f => f.Coverage != FieldCoverage.NotProvided))
            {
                w.Item(field.Name + " = " + string.Join(" ; ", field.Values) + " [" + CoverageLabel(field.Coverage) + "]");
            }
        }
        if (input.Before is { } before && input.After is { } after)
        {
            w.Section("Comparaison A / B");
            var comparison = SupportComparison.Compare(before, after);
            if (comparison.Refusal is not null)
            {
                w.Item(comparison.Refusal);
            }
            else
            {
                w.Item(comparison.SameObject ? "Même objet" + c + "comparaison entre deux captures." : "Objets différents" + c + "comparaison de référence, PAS un historique de modification.");
                w.Item("A" + c + before.Name + " | " + Local(before.CapturedAt, input.Zone) + " | source" + c + SourceLabel(before.Source));
                w.Item("B" + c + after.Name + " | " + Local(after.CapturedAt, input.Zone) + " | source" + c + SourceLabel(after.Source));
                var differences = comparison.Rows.Where(r => r.Status != CompareStatus.Identical).ToList();
                if (differences.Count == 0)
                {
                    w.Item("Aucune différence sur les attributs fournis et comparables.");
                }
                foreach (var row in differences)
                {
                    w.Item("[" + row.StatusLabel + "] " + row.Attribute);
                    w.Sub("A" + c + row.Before);
                    w.Sub("B" + c + row.After);
                    if (row.Added.Length > 0)
                    {
                        w.Sub("Groupes directs présents seulement en B" + c + string.Join(" ; ", row.Added));
                    }
                    if (row.Removed.Length > 0)
                    {
                        w.Sub("Groupes directs présents seulement en A" + c + string.Join(" ; ", row.Removed));
                    }
                }
                w.Item("memberOf" + c + "groupes directs fournis uniquement, hors groupe principal, imbrications et droits effectifs.");
                w.Item("Un attribut manquant ou partiel reste indéterminé, jamais traité comme une suppression certaine.");
            }
        }
        if (input.Incident is { } incident)
        {
            w.Section("Incident de session choisi manuellement");
            w.Item("Cet incident n’est pas attribué automatiquement à l’objet ci-dessus.");
            w.Item("Date" + c + Local(incident.At, input.Zone) + " | Zone" + c + incident.Area + " | Niveau" + c + incident.LevelLabel);
            foreach (var hint in incident.Hints)
            {
                w.Item(hint.Code + c + hint.Title);
                w.Sub("Indice" + c + hint.Evidence);
                w.Sub("Vérification" + c + hint.Next);
            }
            w.Item("Le message brut et la pile technique ne sont pas exportés.");
        }
        w.Section("Limites");
        w.Item("Les règles signalent des indices, pas une cause certaine. Aucune réparation automatique.");
        w.Item("Aucun mot de passe LAPS, aucune clé BitLocker ni aucun identifiant de connexion n’est exporté.");
        return w.ToString();
    }

    /// <summary>The names of the dossier that keyed pseudonyms replace (subject and captures).</summary>
    public static IEnumerable<KnownName> KnownNames(params SupportSnapshot?[] snapshots)
    {
        foreach (var snapshot in snapshots)
        {
            if (snapshot is null)
            {
                continue;
            }
            var kind = TicketReport.KindLabel(snapshot.Kind);
            yield return new KnownName(snapshot.Name, kind, kind);
            foreach (var field in new[] { "sAMAccountName", "userPrincipalName", "displayName", "mail", "dNSHostName", "name" })
            {
                foreach (var value in snapshot.Field(field)?.Values ?? [])
                {
                    yield return new KnownName(value, kind, kind);
                }
            }
            foreach (var value in snapshot.Field("objectGUID")?.Values ?? [])
            {
                yield return new KnownName(value, kind, "Identifiant");
            }
        }
    }

    /// <summary>
    /// Standalone HTML document of a report: no script, no external resource, light and dark themes, printable. The policy
    /// allows only its own style block, pinned by its SHA-256 (no « unsafe-inline »).
    /// </summary>
    public static string Html(string report, string title, string sha256)
    {
        ArgumentNullException.ThrowIfNull(report);
        const string style = "html{color-scheme:light dark}body{font-family:'Segoe UI',Arial,sans-serif;max-width:1100px;margin:40px auto;padding:0 24px;background:#f5f7fb;color:#172033}"
            + "header{border-bottom:4px solid #066ddb;padding-bottom:18px;margin-bottom:24px}h1{font-size:28px;margin:0 0 8px}"
            + "pre{background:#fff;border:1px solid #cbd5e1;border-radius:12px;padding:24px;white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.65 Consolas,monospace}"
            + "small,footer{color:#475569}footer{margin-top:16px;font-size:12px;overflow-wrap:anywhere}"
            + "@media(prefers-color-scheme:dark){body{background:#0f172a;color:#f8fafc}pre{background:#111827;border-color:#475569}small,footer{color:#cbd5e1}}"
            + "@media print{body{background:#fff;color:#000;margin:0;max-width:none}pre{background:#fff;color:#000;border:0;padding:0;font-size:10pt}small,footer{color:#333}}";
        var hash = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(style)));
        var builder = new StringBuilder();
        builder.Append("<!doctype html>\n<html lang=\"fr\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n");
        builder.Append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'sha256-").Append(hash).Append("'; base-uri 'none'; form-action 'none'\">\n");
        builder.Append("<title>").Append(WebUtility.HtmlEncode(title)).Append("</title>\n<style>").Append(style).Append("</style></head>\n<body><header><h1>DOMENIA | ")
            .Append(WebUtility.HtmlEncode(title)).Append("</h1><small>Document local et autonome. Aucune ressource externe ni script. Usage interne.</small></header>\n<pre>")
            .Append(WebUtility.HtmlEncode(report)).Append("</pre>\n<footer>Empreinte SHA-256 du texte du dossier (UTF-8)").Append(FrenchText.Colon)
            .Append(WebUtility.HtmlEncode(sha256)).Append("</footer></body></html>\n");
        return builder.ToString();
    }

    public static string SourceLabel(SnapshotSource source) => source switch
    {
        SnapshotSource.Live => "lecture de l’annuaire",
        SnapshotSource.Cache => "cache ou capture historique",
        _ => "origine non confirmée",
    };

    public static string CoverageLabel(FieldCoverage coverage) => coverage switch
    {
        FieldCoverage.Provided => "fourni",
        FieldCoverage.Partial => "partiel",
        _ => "non fourni",
    };

    private static string Local(DateTimeOffset at, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy' 'HH':'mm':'ss", CultureInfo.InvariantCulture);

    /// <summary>Lines of one layout: section headings and items written the way each ticketing tool reads them.</summary>
    private sealed class Writer(ReportTemplate template)
    {
        private readonly List<string> lines = [];

        public void Title(string text) => lines.Add(template switch
        {
            ReportTemplate.Glpi => "## " + text,
            ReportTemplate.ServiceNow => "*** " + text + " ***",
            _ => text,
        });

        public void Line(string text) => lines.Add(text);

        public void Section(string title)
        {
            lines.Add("");
            lines.Add(template switch
            {
                ReportTemplate.Glpi => "### " + title,
                ReportTemplate.ServiceNow => "=== " + title.ToUpper(CultureInfo.GetCultureInfo("fr-FR")) + " ===",
                _ => title.ToUpper(CultureInfo.GetCultureInfo("fr-FR")),
            });
        }

        public void Item(string text) => lines.Add(template switch
        {
            ReportTemplate.Glpi => "- " + text,
            ReportTemplate.ServiceNow => "* " + text,
            _ => text,
        });

        public void Sub(string text) => lines.Add(template switch
        {
            ReportTemplate.Glpi or ReportTemplate.ServiceNow => "  - " + text,
            _ => "  " + text,
        });

        public override string ToString() => string.Join("\r\n", lines);
    }
}
