using System.Collections.Immutable;
using Domenia.Core.Accueil;
using FleetProbeCatalog = Domenia.Core.Accueil.ProbeCatalog;

namespace Domenia.Core.Poste;

public sealed record PosteScalarProbePage(ProbeDefinition Probe, ProbeStatus Status, string StatusLabel,
    ImmutableArray<string> Columns, ImmutableArray<ImmutableArray<string?>> Rows, int Page, int Pages, int Total, string Provenance);

/// <summary>Scalar projections use their actual per-GUID, per-version stored values and the shared D1 transforms.</summary>
public static class PosteScalarProbeCards
{
    public const int PageSize = 100;

    public static PosteScalarProbePage Build(ProbeDefinition probe, ProbeReading? reading, int page, DateTimeOffset now, TimeZoneInfo zone)
    {
        var currentDefinition = reading is not null && ProbeDefinitionIdentity.Current(probe, reading.DefinitionHash);
        var validDate = reading?.At is { } at && at <= now + TimeSpan.FromMinutes(5) && now - at <= TimeSpan.FromDays(30);
        var values = reading is { State: MeasureState.Known } && validDate && currentDefinition && reading.Error is null
            ? FleetProbeCatalog.Values(probe, reading, now) : reading?.Values ?? ImmutableArray<string>.Empty;
        var state = reading is null ? ProbeState.NotRead : reading.State switch
        {
            MeasureState.Known when validDate && currentDefinition && reading.Error is null => ProbeState.Read,
            MeasureState.Refused => ProbeState.Refused,
            MeasureState.Error => ProbeState.Failed,
            MeasureState.Absent => ProbeState.Absent,
            _ => ProbeState.NotRead,
        };
        var historical = values.IsDefaultOrEmpty && (reading?.State != MeasureState.Known || !currentDefinition || !validDate) ? reading?.Historical : null;
        if (historical is not null) values = historical.Values;
        var interpreted = currentDefinition && validDate && historical is null && reading?.State == MeasureState.Known && reading.Error is null;
        var total = values.Length;
        var pages = Math.Max(1, (int)Math.Ceiling(total / (double)PageSize));
        var current = Math.Clamp(page, 1, pages);
        var rows = values.Skip((current - 1) * PageSize).Take(PageSize)
            .Select(value => ImmutableArray.Create<string?>(value + (interpreted ? FleetProbeCatalog.Unit(probe) : ""))).ToImmutableArray();
        var provenance = reading?.At is { } date ? "Cache du " + PosteText.LocalDateTime(date, zone) + " (" + PosteText.Age(date, now) + ")"
            : "Aucun relevé daté conservé";
        if (reading is not null && !validDate) { provenance += " · date absente, future ou relevé de plus de 30 jours : aucune valeur actuelle"; }
        if (reading is not null && !currentDefinition) provenance += " · valeurs brutes historiques, définition ancienne ou inconnue : relancez explicitement la sonde";
        if (historical is not null) provenance += " · précédent relevé brut du " + (historical.At is { } previous ? PosteText.LocalDateTime(previous, zone) : "date inconnue");
        if (reading?.Error is { Length: > 0 } error) { provenance += " · " + error; }
        provenance += " · " + probe.Namespace + "\\" + probe.Class + " · " + probe.Mode + " / " + probe.Transform;
        if (PersonalProbeCatalog.IsKey(probe.Id)) { provenance += " · version " + probe.Id; }
        return new(probe, new(probe.Id, state, state == ProbeState.Read ? reading?.At : null, reading?.At, reading?.Error, total),
            PosteReadings.ProbeStateLabel(state), [interpreted ? "Valeur interprétée" : "Valeur historique brute"], rows, current, pages, total, provenance);
    }
}
