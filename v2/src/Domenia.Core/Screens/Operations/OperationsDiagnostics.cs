using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Figures handed by the page to the diagnostic: numbers and closed values only, checked again here.</summary>
/// <param name="WebView">Version of the WebView2 engine (shape « 154.0.4258.62 »), from app.info.</param>
/// <param name="Theme">dark, light or contrast.</param>
/// <param name="InterfaceP50Ms">Median lateness of the page heartbeat (OPE-030), or null.</param>
public sealed record InterfaceFigures(string? WebView, string? Theme, double? InterfaceP50Ms, double? InterfaceP95Ms, int? InterfaceSamples);

/// <summary>One file of the diagnostic dossier (ZIP).</summary>
public sealed record DossierFile(string Name, string Text);

/// <summary>
/// The redacted support diagnostic (Domenia 1 New-DomeniaRedactedDiagnostic, OPE-004) and the diagnostic dossier (Domenia 1
/// Export-SelfCheckReport, OPE-008), built on allow-lists. The diagnostic never holds a name, a message, a DN, an address, a path
/// nor a secret: a value is kept only when it has the shape of a version, an operation of the registry, an error code or a number.
/// Pure: inputs are handed in.
/// </summary>
public static partial class OperationsDiagnostics
{
    public const string Format = "Domenia.Diagnostic.3";
    public const int MaxMetrics = 200;
    public const int MaxErrors = 200;
    public const int MaxTraces = 64;
    public const int MaxSlow = 16;

    private static readonly JsonWriterOptions Indented = new() { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>
    /// Builds the diagnostic JSON. <paramref name="declared"/> is the closed list of the registry: an operation outside it is
    /// dropped, so a free text can never pass as an operation name.
    /// </summary>
    public static string Build(
        DateTimeOffset at,
        AppMode mode,
        InterfaceFigures page,
        double? memoryMb,
        bool readOnly,
        int receiptsPending,
        ActivitySnapshot activity,
        IReadOnlyCollection<string> declared,
        IEnumerable<OperationSample> samples,
        IEnumerable<(string Code, int Count)> errors,
        IEnumerable<SlowEvent> slow,
        int faults)
    {
        ArgumentNullException.ThrowIfNull(page);
        ArgumentNullException.ThrowIfNull(activity);
        ArgumentNullException.ThrowIfNull(declared);
        ArgumentNullException.ThrowIfNull(samples);
        ArgumentNullException.ThrowIfNull(errors);
        ArgumentNullException.ThrowIfNull(slow);
        var known = declared.ToHashSet(StringComparer.Ordinal);
        using var buffer = new MemoryStream();
        using (var w = new Utf8JsonWriter(buffer, Indented))
        {
            w.WriteStartObject();
            w.WriteString("format", Format);
            w.WriteString("capturedUtc", at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture));
            w.WriteBoolean("containsNames", false);
            w.WriteBoolean("containsMessages", false);
            w.WriteBoolean("containsSecrets", false);
            w.WriteBoolean("containsTargets", false);

            w.WriteStartObject("versions");
            WriteVersion(w, "domenia", ProductInfo.Version);
            WriteVersion(w, "dotnet", Environment.Version.ToString());
            WriteVersion(w, "os", Environment.OSVersion.Version.ToString());
            w.WriteString("bitness", Environment.Is64BitProcess ? "64" : "32");
            WriteVersion(w, "webView2", page.WebView);
            if (page.Theme is "dark" or "light" or "contrast")
            {
                w.WriteString("theme", page.Theme);
            }
            w.WriteEndObject();

            w.WriteStartObject("counters");
            w.WriteNumber("tasksOpen", activity.Summary.Active);
            w.WriteNumber("tracesKept", activity.Kept);
            w.WriteNumber("traceFaults", faults);
            w.WriteNumber("receiptsPending", Math.Max(0, receiptsPending));
            if (memoryMb is double mb)
            {
                w.WriteNumber("memoryMb", Math.Round(mb, 0));
            }
            if (page.InterfaceP50Ms is double p50 && double.IsFinite(p50) && p50 >= 0)
            {
                w.WriteNumber("interfaceP50Ms", Math.Round(p50, 1));
            }
            if (page.InterfaceP95Ms is double p95 && double.IsFinite(p95) && p95 >= 0)
            {
                w.WriteNumber("interfaceP95Ms", Math.Round(p95, 1));
            }
            if (page.InterfaceSamples is int count && count >= 0)
            {
                w.WriteNumber("interfaceSamples", Math.Min(count, 100_000));
            }
            w.WriteBoolean("readOnly", readOnly);
            w.WriteBoolean("simulation", mode == AppMode.Simulation);
            w.WriteEndObject();

            w.WriteStartArray("metrics");
            foreach (var group in samples.Where(s => known.Contains(s.Operation)).GroupBy(s => s.Operation, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal).Take(MaxMetrics))
            {
                var summary = ActivityRules.Latency(group.Select(s => s.DurationMs));
                w.WriteStartObject();
                w.WriteString("operation", group.Key);
                w.WriteNumber("count", summary.Count);
                WriteNumberOrNull(w, "p50Ms", summary.P50);
                WriteNumberOrNull(w, "p95Ms", summary.P95);
                WriteNumberOrNull(w, "maxMs", summary.Max);
                w.WriteNumber("successPercent", Math.Round(100.0 * group.Count(s => s.Succeeded) / Math.Max(1, group.Count()), 1));
                w.WriteEndObject();
            }
            w.WriteEndArray();

            w.WriteStartArray("errors");
            foreach (var (code, n) in errors.Where(e => IsErrorCode(e.Code)).Take(MaxErrors))
            {
                w.WriteStartObject();
                w.WriteString("code", code);
                w.WriteNumber("count", n);
                w.WriteEndObject();
            }
            w.WriteEndArray();

            w.WriteStartArray("traces");
            foreach (var row in activity.Open.Concat(activity.Recent).Where(r => known.Contains(r.Operation) && IsReference(r.Reference)).Take(MaxTraces))
            {
                w.WriteStartObject();
                w.WriteString("reference", row.Reference);
                w.WriteString("operation", row.Operation);
                w.WriteString("kind", JsonNamingPolicy.CamelCase.ConvertName(row.Kind.ToString()));
                if (row.Outcome is TaskOutcome outcome)
                {
                    w.WriteString("outcome", JsonNamingPolicy.CamelCase.ConvertName(outcome.ToString()));
                }
                if (row.Category is string category && IsErrorCode(category))
                {
                    w.WriteString("category", category);
                }
                w.WriteBoolean("open", row.State is not TaskState.Completed);
                w.WriteNumber("totalMs", Math.Round(row.DurationMs, 1));
                w.WriteStartArray("phases");
                foreach (var phase in row.Phases.Where(p => p.Phase is "queue" or "engine" or "step"))
                {
                    w.WriteStartObject();
                    w.WriteString("phase", phase.Phase);
                    WriteNumberOrNull(w, "durationMs", phase.DurationMs is double d ? Math.Round(d, 1) : null);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteEndObject();
            }
            w.WriteEndArray();

            w.WriteStartArray("slowness");
            foreach (var item in slow.Where(s => known.Contains(s.Operation)).Take(MaxSlow))
            {
                w.WriteStartObject();
                w.WriteString("operation", item.Operation);
                w.WriteString("phase", item.Phase is "queue" or "engine" ? item.Phase : "");
                w.WriteNumber("durationMs", Math.Round(item.DurationMs, 1));
                w.WriteNumber("totalMs", Math.Round(item.TotalMs, 1));
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>What the operator reads before saving: what the file contains and, as important, what it never contains.</summary>
    public static ImmutableArray<string> Preview(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var versions = root.GetProperty("versions").EnumerateObject().Select(p => p.Name + " " + p.Value.GetString()).ToList();
        int Count(string name) => root.GetProperty(name).GetArrayLength();
        return
        [
            "Versions" + FrenchText.Colon + (versions.Count > 0 ? string.Join(" · ", versions) : "aucune") + ".",
            "Compteurs" + FrenchText.Colon + "tâches ouvertes, reçus à vérifier, mémoire, réactivité de l’interface, lecture seule et mode.",
            "Mesures locales" + FrenchText.Colon + FrenchText.Count(Count("metrics"), "série", "séries") + " par opération du pont (médiane, 95e centile, maximum, réussite).",
            "Erreurs" + FrenchText.Colon + FrenchText.Count(Count("errors"), "code", "codes") + " avec leur nombre, jamais leur message.",
            "Opérations" + FrenchText.Colon + FrenchText.Count(Count("traces"), "trace", "traces") + " par référence courte, issue, phases et durées.",
            "Lenteurs expliquées" + FrenchText.Colon + FrenchText.Integer(Count("slowness")) + ".",
            "Jamais inclus" + FrenchText.Colon + "mots de passe, clés, jetons, messages d’erreur, noms de comptes, de postes ou de groupes, chemins AD, adresses, chemins de fichiers et contenu des journaux.",
        ];
    }

    public static string Sha256(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text ?? "")));

    /// <summary>
    /// The files of the diagnostic dossier (Domenia 1 Export-SelfCheckReport): runtime.json (versions, mode, identities, domain,
    /// controller, read only, tasks, stores), configuration-expurgee.json (decision of the mode, sensitive keys masked),
    /// verification.csv (last check of the application) and LISEZMOI.txt. No raw journal. With <paramref name="anonymize"/>,
    /// identities, domain, controller and workstation names are replaced by stable pseudonyms in every file (improvement of OPE-008).
    /// </summary>
    public static ImmutableArray<DossierFile> Dossier(
        DateTimeOffset at,
        ModeDecision decision,
        SessionSnapshot? session,
        InterfaceFigures page,
        double? memoryMb,
        int tasksOpen,
        int receiptsPending,
        bool receiptsPersistent,
        bool preferencesPersistent,
        IReadOnlyCollection<string> writeKinds,
        CheckReport? check,
        bool anonymize)
    {
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(page);
        ArgumentNullException.ThrowIfNull(writeKinds);
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var counters = new Dictionary<string, int>(StringComparer.Ordinal);
        string Hide(string? value, string kind)
        {
            if (string.IsNullOrEmpty(value) || !anonymize)
            {
                return value ?? "";
            }
            if (!names.TryGetValue(value, out var pseudonym))
            {
                counters[kind] = counters.TryGetValue(kind, out var n) ? n + 1 : 1;
                pseudonym = kind + "-" + counters[kind].ToString(CultureInfo.InvariantCulture);
                names[value] = pseudonym;
            }
            return pseudonym;
        }
        var process = Hide(Environment.UserDomainName + "\\" + Environment.UserName, "identite");
        var machine = Hide(Environment.MachineName, "poste");
        var account = Hide(session?.Account.Login, "compte");
        var domain = Hide(session?.Domain?.DnsName, "domaine");
        var netbios = Hide(session?.Domain?.NetbiosName, "netbios");
        var rootDn = Hide(session?.Domain?.RootDn, "racine");
        var controller = Hide(session?.Controller?.DnsName, "controleur");
        var joined = Hide(decision.JoinedDomain, "domaine");

        var runtime = new StringBuilder();
        using (var buffer = new MemoryStream())
        {
            using (var w = new Utf8JsonWriter(buffer, Indented))
            {
                w.WriteStartObject();
                w.WriteString("application", ProductInfo.Name);
                w.WriteString("version", ProductInfo.Version);
                w.WriteString("generated", at.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture));
                w.WriteString("dotnet", Environment.Version.ToString());
                w.WriteString("os", Environment.OSVersion.VersionString);
                w.WriteBoolean("is64Bit", Environment.Is64BitProcess);
                w.WriteString("webView2", IsVersion(page.WebView) ? page.WebView : "");
                w.WriteString("processIdentity", process);
                w.WriteString("machine", machine);
                w.WriteString("mode", decision.Mode == AppMode.Simulation ? "simulation" : "annuaire");
                w.WriteString("modeReason", decision.Reason.ToString());
                w.WriteString("joinedDomain", joined);
                w.WriteString("account", account);
                w.WriteString("domain", domain);
                w.WriteString("netbios", netbios);
                w.WriteString("rootDn", rootDn);
                w.WriteString("controller", controller);
                w.WriteBoolean("readOnly", session?.ReadOnly ?? true);
                w.WriteNumber("tasksOpen", tasksOpen);
                w.WriteNumber("receiptsPending", receiptsPending);
                w.WriteBoolean("receiptsOnDisk", receiptsPersistent);
                w.WriteBoolean("preferencesOnDisk", preferencesPersistent);
                if (memoryMb is double mb)
                {
                    w.WriteNumber("memoryMb", Math.Round(mb, 0));
                }
                w.WriteStartArray("writeKinds");
                foreach (var kind in writeKinds.Order(StringComparer.Ordinal))
                {
                    w.WriteStringValue(kind);
                }
                w.WriteEndArray();
                w.WriteEndObject();
            }
            runtime.Append(Encoding.UTF8.GetString(buffer.ToArray()));
        }

        string configuration;
        using (var buffer = new MemoryStream())
        {
            using (var w = new Utf8JsonWriter(buffer, Indented))
            {
                w.WriteStartObject();
                w.WriteString("source", LegacyConfiguration.FileName);
                w.WriteString("mode", decision.Mode == AppMode.Simulation ? "simulation" : "annuaire");
                w.WriteString("reason", decision.Reason.ToString());
                w.WriteString("detail", ReceiptReviews.Mask(Pseudonymize(decision.Detail, names)));
                w.WriteStartArray("warnings");
                foreach (var warning in decision.Warnings)
                {
                    w.WriteStringValue(ReceiptReviews.Mask(Pseudonymize(warning, names)));
                }
                w.WriteEndArray();
                w.WriteString("note", "Seul Auth.DemoProvider est lu par Domenia 2 ; les clés sensibles (mot de passe, secret, jeton, clé) seraient masquées.");
                w.WriteEndObject();
            }
            configuration = Encoding.UTF8.GetString(buffer.ToArray());
        }

        var csv = new StringBuilder("Catégorie;Test;État;Durée (ms);Détail\r\n");
        if (check is not null)
        {
            foreach (var row in check.Rows)
            {
                csv.Append(Cell(row.Category)).Append(';').Append(Cell(row.Test)).Append(';').Append(Cell(StatusText(row.Status))).Append(';')
                    .Append(Math.Round(row.DurationMs).ToString(CultureInfo.InvariantCulture)).Append(';').Append(Cell(ReceiptReviews.Mask(Pseudonymize(row.Detail, names)))).Append("\r\n");
            }
        }
        var readme = string.Join("\r\n",
            "Domenia " + ProductInfo.Version + " — dossier de diagnostic en lecture seule",
            "Généré le " + at.UtcDateTime.ToString("yyyy'-'MM'-'dd' 'HH':'mm", CultureInfo.InvariantCulture) + " UTC.",
            "Journaux bruts exclus. Aucun mot de passe, aucune clé ni aucun jeton.",
            anonymize
                ? "Identités, domaine, contrôleur et noms de postes remplacés par des pseudonymes stables (compte-1, domaine-1…)."
                : "Les identités, noms de postes, domaines et chemins ne sont pas anonymisés : relisez avant tout partage.",
            check is null ? "Aucune vérification de l’application dans cette session : verification.csv est vide." : "verification.csv : dernière vérification de l’application (" + check.Summary + ").",
            "");
        return
        [
            new DossierFile("runtime.json", runtime.ToString()),
            new DossierFile("configuration-expurgee.json", configuration),
            new DossierFile("verification.csv", csv.ToString()),
            new DossierFile("LISEZMOI.txt", readme),
        ];
    }

    public static string StatusText(CheckStatus status) => status switch
    {
        CheckStatus.Ok => "OK",
        CheckStatus.Warn => "À savoir",
        CheckStatus.Error => "Erreur",
        _ => "Sans objet",
    };

    /// <summary>Summary line of a check (Domenia 1: « 12 OK  1 erreur(s)  340 ms. Aucune écriture AD effectuée. »).</summary>
    public static CheckReport Report(DateTimeOffset at, bool full, IReadOnlyList<CheckRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var ok = rows.Count(r => r.Status == CheckStatus.Ok);
        var errors = rows.Count(r => r.Status == CheckStatus.Error);
        var warnings = rows.Count(r => r.Status == CheckStatus.Warn);
        var infos = rows.Count(r => r.Status == CheckStatus.Info);
        var total = Math.Round(rows.Sum(r => r.DurationMs), 1);
        var summary = FrenchText.Integer(ok) + " OK · " + FrenchText.Count(errors, "erreur", "erreurs") + " · " + FrenchText.Count(warnings, "point à savoir", "points à savoir")
            + (infos > 0 ? " · " + FrenchText.Integer(infos) + " pour information" : "")
            + " · " + ActivityRules.Duration(total) + ". Aucune écriture effectuée.";
        return new CheckReport(at, full, ok, errors, warnings, total, summary, [.. rows]);
    }

    public static bool IsVersion(string? value) => value is not null && value.Length <= 40 && VersionShape().IsMatch(value);

    public static bool IsErrorCode(string? value) => value is not null && value.Length <= 64 && ErrorShape().IsMatch(value);

    private static bool IsReference(string? value) => value is { Length: 8 } && value.All(char.IsAsciiLetterOrDigit);

    private static void WriteVersion(Utf8JsonWriter w, string name, string? value)
    {
        if (IsVersion(value))
        {
            w.WriteString(name, value);
        }
    }

    private static void WriteNumberOrNull(Utf8JsonWriter w, string name, double? value)
    {
        if (value is double v && double.IsFinite(v))
        {
            w.WriteNumber(name, v);
        }
        else
        {
            w.WriteNull(name);
        }
    }

    private static string Pseudonymize(string text, Dictionary<string, string> names)
    {
        foreach (var (value, pseudonym) in names.OrderByDescending(p => p.Key.Length))
        {
            text = text.Replace(value, pseudonym, StringComparison.OrdinalIgnoreCase);
        }
        return text;
    }

    /// <summary>CSV cell: quoted when needed, formulas neutralised (« = + - @ » at the start), like the kit.</summary>
    private static string Cell(string value)
    {
        var text = value ?? "";
        if (text.Length > 0 && text[0] is '=' or '+' or '-' or '@')
        {
            text = "'" + text;
        }
        return text.IndexOfAny([';', '"', '\r', '\n']) >= 0 ? "\"" + text.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : text;
    }

    [GeneratedRegex(@"^[0-9]{1,6}(\.[0-9]{1,6}){1,3}(-[a-z0-9]{1,12})?$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex VersionShape();

    [GeneratedRegex(@"^[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*){1,3}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex ErrorShape();
}
