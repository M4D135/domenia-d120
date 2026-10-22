using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>Who ran « dsregcmd /status »: the SSO state belongs to the session that ran it (Domenia 1 D074).</summary>
public enum DsregCollector
{
    EndUserSession,
    AdministrativeAccount,
    Unknown,
}

/// <summary>Result of poste.dsreg.analyze: join mode, SSO verdict and facts; nothing is executed nor repaired.</summary>
public sealed record DsregAnalysis(bool Recognized, string Mode, string SsoVerdict, string SsoReason, string ExecutingAccount, bool? ComputerMatches, bool Truncated, int Lines, ImmutableArray<PosteFact> Facts);

/// <summary>
/// Join state from a pasted « dsregcmd /status » text (Domenia 1 ConvertFrom-DomeniaDsregStatus, Get-DomeniaJoinStateFacts).
/// The join state is a property of the device; the SSO state (PRT, Windows Hello, workplace registration) belongs to the
/// session that collected the text. Nothing is run, nothing is repaired. Pure.
/// </summary>
public static partial class PosteDsreg
{
    /// <summary>Longest text analysed (128 Kio, as Domenia 1).</summary>
    public const int MaxLength = 131_072;

    [GeneratedRegex(@"^\s*\|\s*(?<name>[^|]*[^|\s])\s*\|\s*$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex HeaderLine();

    [GeneratedRegex(@"^\s*(?<key>[A-Za-z][A-Za-z0-9 ._()-]{0,63}?)\s*:(\s+(?<value>.*))?$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex PairLine();

    public static DsregAnalysis Analyze(string? text, DsregCollector collector, string? endUser, string? expectedComputer, DateTimeOffset? collectedAt)
    {
        var raw = text ?? "";
        var truncated = raw.Length > MaxLength;
        if (truncated)
        {
            raw = raw[..MaxLength];
        }
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var count = 0;
        foreach (var line in raw.Split('\n'))
        {
            count++;
            var clean = line.TrimEnd('\r');
            if (HeaderLine().IsMatch(clean))
            {
                continue;
            }
            var pair = PairLine().Match(clean);
            if (!pair.Success)
            {
                continue;
            }
            var key = pair.Groups["key"].Value.Trim();
            var value = pair.Groups["value"].Success ? PosteText.Flat(pair.Groups["value"].Value, 256) : "";
            if (key.Length > 0)
            {
                values.TryAdd(key, value);
            }
        }
        const string Source = "dsregcmd /status (texte collé)";
        const string Pasted = "Texte collé : poste, session et date de collecte déclarés, non vérifiés par Domenia.";
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        string Get(string key) => values.TryGetValue(key, out var v) ? v.Trim() : "";
        if (!values.ContainsKey("AzureAdJoined") && !values.ContainsKey("DomainJoined"))
        {
            facts.Add(PosteText.Fact("Jonction", "Texte non reconnu", FactState.Unknown, Source, "Collez la sortie complète de dsregcmd /status."));
            return new DsregAnalysis(false, "Inconnu", "NonEvaluable", "Texte non reconnu.", "", null, truncated, count, facts.ToImmutable());
        }
        var ad = Get("DomainJoined").ToUpperInvariant();
        var entra = Get("AzureAdJoined").ToUpperInvariant();
        var mode = (ad, entra) switch
        {
            ("YES", "YES") => "Hybride (AD et Entra ID)",
            ("NO", "YES") => "Entra ID seul",
            ("YES", "NO") => "Active Directory seul",
            ("NO", "NO") => "Aucune jonction",
            _ => "Inconnu",
        };
        foreach (var (label, flag, detailKey) in new[] { ("Jonction Active Directory", ad, "DomainName"), ("Jonction Entra ID", entra, "TenantName") })
        {
            if (flag is "YES" or "NO")
            {
                var detail = Get(detailKey);
                facts.Add(PosteText.Fact(label, (flag == "YES" ? "Oui" : "Non") + (flag == "YES" && detail.Length > 0 ? " (" + detail + ")" : ""), FactState.Observed, Source, Pasted, at: collectedAt, tone: Tone.Info));
            }
            else
            {
                facts.Add(PosteText.Fact(label, "Non indiqué", FactState.Unknown, Source, Pasted, at: collectedAt));
            }
        }
        facts.Add(PosteText.Fact("Mode de jonction", mode, mode == "Inconnu" ? FactState.Unknown : FactState.Observed, Source, Pasted, at: collectedAt, tone: mode == "Aucune jonction" ? Tone.Warn : Tone.Info));
        var deviceAuth = Get("DeviceAuthStatus");
        if (deviceAuth.Length > 0)
        {
            facts.Add(PosteText.Fact("Authentification de l’appareil", deviceAuth, FactState.Observed, Source, Pasted, at: collectedAt, tone: deviceAuth.Equals("SUCCESS", StringComparison.OrdinalIgnoreCase) ? Tone.Ok : Tone.Warn));
        }
        bool? matches = null;
        var deviceName = Get("Device Name");
        if (deviceName.Length > 0)
        {
            string? hint = null;
            if (!string.IsNullOrWhiteSpace(expectedComputer))
            {
                matches = PosteText.ShortName(deviceName) == PosteText.ShortName(expectedComputer);
                if (matches == false)
                {
                    hint = "Le texte semble provenir d’un autre poste que " + expectedComputer + " : il ne décrit pas ce poste.";
                }
            }
            facts.Add(PosteText.Fact("Nom du poste dans le texte", deviceName, FactState.Observed, Source, Pasted, hint, collectedAt, matches == false ? Tone.Alert : Tone.Info));
        }
        var executing = Get("Executing Account Name");
        var executingAccount = executing.Length > 0 ? executing.Split(',')[0].Trim() : "";
        var user = (endUser ?? "").Trim();
        var evaluable = false;
        var reason = collector switch
        {
            DsregCollector.AdministrativeAccount => "Lu sous un compte d’administration : l’état SSO décrit cette session, pas le jeton de l’utilisateur final.",
            DsregCollector.Unknown => "Session de collecte non déclarée : état SSO de l’utilisateur final non évaluable.",
            _ when user.Length == 0 => "Utilisateur final non désigné : état SSO non évaluable.",
            _ when executingAccount.Length == 0 => "Compte d’exécution absent du texte : session de collecte non vérifiable, état SSO non évaluable.",
            _ when AccountMatches(user, executing) => "",
            _ => "Texte produit sous le compte " + executingAccount + ", pas sous celui de " + user + " : état SSO non évaluable.",
        };
        evaluable = reason.Length == 0;
        var verdict = "NonEvaluable";
        if (evaluable)
        {
            const string UserSource = "dsregcmd /status, session de l’utilisateur final (déclarée)";
            var prt = Get("AzureAdPrt").ToUpperInvariant();
            verdict = prt switch { "YES" => "PrtPresent", "NO" => "PrtAbsent", _ => "Inconnu" };
            var value = prt switch { "YES" => "Présent", "NO" => "Absent", _ => "Non indiqué" };
            var update = Get("AzureAdPrtUpdateTime");
            if (prt == "YES" && update.Length > 0)
            {
                value += ", mis à jour le " + update;
            }
            facts.Add(PosteText.Fact("Jeton SSO Entra ID (PRT)", value, verdict == "Inconnu" ? FactState.Unknown : FactState.Observed, UserSource, "État à la date de collecte seulement. " + Pasted, at: collectedAt, tone: prt == "YES" ? Tone.Ok : Tone.Warn));
            foreach (var (label, key) in new[] { ("Windows Hello configuré", "NgcSet"), ("Enregistrement Workplace", "WorkplaceJoined") })
            {
                var flag = Get(key).ToUpperInvariant();
                if (flag is "YES" or "NO")
                {
                    facts.Add(PosteText.Fact(label, flag == "YES" ? "Oui" : "Non", FactState.Observed, UserSource, Pasted, at: collectedAt, tone: Tone.Info));
                }
            }
        }
        else
        {
            facts.Add(PosteText.Fact("Jeton SSO de l’utilisateur final", "Non évaluable", FactState.Unknown, Source, reason, at: collectedAt));
        }
        if (truncated)
        {
            facts.Add(PosteText.Fact("Texte", "Tronqué à 128 Kio", FactState.Observed, Source, "La fin du texte n’a pas été lue.", tone: Tone.Warn));
        }
        return new DsregAnalysis(true, mode, verdict, reason, executingAccount, matches, truncated, count, facts.ToImmutable());
    }

    /// <summary>
    /// Compares the declared end user with « Executing Account Name » (DOMAIN\login, upn): DOMAIN\login whole, a UPN with the
    /// UPN part, a bare login with the login part.
    /// </summary>
    public static bool AccountMatches(string endUser, string executingLine)
    {
        ArgumentNullException.ThrowIfNull(endUser);
        ArgumentNullException.ThrowIfNull(executingLine);
        var parts = executingLine.Split(',').Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
        var wanted = endUser.Trim();
        if (parts.Count == 0 || wanted.Length == 0)
        {
            return false;
        }
        if (wanted.Contains('\\', StringComparison.Ordinal))
        {
            return string.Equals(parts[0], wanted, StringComparison.OrdinalIgnoreCase);
        }
        if (wanted.Contains('@', StringComparison.Ordinal))
        {
            return parts.Any(p => string.Equals(p, wanted, StringComparison.OrdinalIgnoreCase));
        }
        var seen = parts[0].Contains('\\', StringComparison.Ordinal) ? parts[0][(parts[0].LastIndexOf('\\') + 1)..] : parts[0];
        return string.Equals(seen, wanted, StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>Facts of the update provider (Domenia 1 ConvertTo-DomeniaUpdateFacts): Windows Update, date, source and result, old after 30 days.</summary>
public static class PosteUpdates
{
    public const int StaleDays = 30;

    public static ImmutableArray<PosteFact> Facts(UpdateConfig config, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(zone);
        var facts = ImmutableArray.CreateBuilder<PosteFact>();
        facts.Add(Provider("Windows Update", config.LastSuccess, config.LastResult, config.Source ?? "Client Windows Update", true, now, zone));
        return facts.ToImmutable();
    }

    private static PosteFact Provider(string label, DateTimeOffset? last, string? result, string source, bool present, DateTimeOffset now, TimeZoneInfo zone)
    {
        var raw = (result ?? "").Trim();
        var (code, text) = raw.ToUpperInvariant() switch
        {
            "SUCCEEDED" or "SUCCESS" or "OK" or "INSTALLED" or "0" or "REUSSI" => ("Succes", "succès signalé par la source"),
            "FAILED" or "FAILURE" or "ERROR" or "ECHEC" => ("Echec", "échec signalé par la source"),
            "PENDING" or "INPROGRESS" or "RUNNING" => ("EnAttente", "en attente selon la source"),
            "" => ("Inconnu", "résultat non indiqué"),
            _ => ("Autre", PosteText.Flat(raw, 120)),
        };
        if (!present)
        {
            return PosteText.Fact(label, "Non détecté", FactState.Observed, source, null, at: now, tone: Tone.Off);
        }
        if (last is not DateTimeOffset at)
        {
            return PosteText.Fact(label, "Date de la dernière information inconnue, " + text, FactState.Unknown, source, "Sans date, l’information ne décrit pas l’état actuel.", at: now);
        }
        var age = (int)Math.Floor((now - at).TotalDays);
        var value = "Dernière information le " + PosteText.LocalDateTime(at, zone) + ", " + text;
        if (at > now.AddDays(1))
        {
            return PosteText.Fact(label, value + " (date postérieure à la lecture : horloge à vérifier)", FactState.Estimated, source, "Dernière information disponible, pas une vérification en direct.", at: now, tone: Tone.Warn);
        }
        if (age > StaleDays)
        {
            return PosteText.Fact(label, value + " (ancienne : " + FrenchText.Integer(age) + " j)", FactState.Observed, source, "Information de plus de " + FrenchText.Integer(StaleDays) + " jours : l’état actuel n’est pas connu.", at: now, tone: Tone.Warn);
        }
        return PosteText.Fact(label, value, FactState.Observed, source, "Dernière information disponible, pas une vérification en direct.", at: now, tone: code == "Echec" ? Tone.Alert : code == "Succes" ? Tone.Ok : Tone.Info);
    }
}
