namespace Domenia.Core;

/// <summary>
/// How much a fact is worth, for every module (Domenia 1 New-DomeniaFact: Constaté, Estimé, Refusé, Indisponible, Inconnu).
/// A refusal or an unavailable source never proves anything about the object; an estimate is never a proof. The five states
/// exist once here: <c>PosteFact</c>, <c>AuditFact</c>, <c>FicheFact</c> and <c>AccountsFact</c> reach them through this
/// type (TRV-138), as do the measures of the directory and of the readings (<see cref="DomeniaFact.StateOf"/>).
/// </summary>
public enum DomeniaFactState
{
    Observed,
    Estimated,
    Refused,
    Unavailable,
    Unknown,
}

/// <summary>
/// The one format of an explainable fact (TRV-138, Domenia 1 New-DomeniaFact): the fact, its value, its state, the source and
/// the reader account that gave it, what it does not prove (its limit), what it suggests (its hypothesis) and when it was
/// read. <see cref="New"/> refuses to state anything above a bare observation without its limit: each assertion carries its
/// limit. The modules keep their own record and project onto this one with their <c>ToFact</c>. Pure.
/// </summary>
public sealed record DomeniaFact(string Label, string Value, DomeniaFactState State, string Source, string Limit, string? Hypothesis, DateTimeOffset? At, string? Reader)
{
    /// <summary>What is said when a fact above a bare observation was recorded without its limit: the missing limit is told, never invented.</summary>
    public const string LimitNotRecorded = "Limite non enregistrée pour cette affirmation.";

    /// <summary>What is said when a fact was recorded without naming its source.</summary>
    public const string SourceNotRecorded = "Source non enregistrée pour cette affirmation.";

    /// <summary>The five states in the words the operator reads.</summary>
    public static string LabelOf(DomeniaFactState state) => state switch
    {
        DomeniaFactState.Observed => "Constaté",
        DomeniaFactState.Estimated => "Estimé",
        DomeniaFactState.Refused => "Refusé",
        DomeniaFactState.Unavailable => "Indisponible",
        _ => "Inconnu",
    };

    /// <summary>The state of the fact in French, as the pages show it.</summary>
    public string StateLabel => LabelOf(State);

    /// <summary>True when the fact says what it does not prove.</summary>
    public bool CarriesItsLimit => !string.IsNullOrWhiteSpace(Limit) && Limit != LimitNotRecorded;

    /// <summary>The limit to show: the recorded one, or the sentence that says it was left out.</summary>
    public string LimitSaid => CarriesItsLimit ? Limit : LimitNotRecorded;

    /// <summary>Fact built by a module that already holds its own record: nothing is invented, a missing limit is told.</summary>
    public static DomeniaFact Of(string label, string value, DomeniaFactState state, string? source, string? limit, string? hypothesis = null, DateTimeOffset? at = null, string? reader = null) =>
        new(label, value, state, string.IsNullOrWhiteSpace(source) ? SourceNotRecorded : source,
            string.IsNullOrWhiteSpace(limit) ? LimitNotRecorded : limit, hypothesis, at, reader);

    /// <summary>Builds a fact and honours the guard rail: nothing above a bare observation is stated without its limit.</summary>
    public static DomeniaFact New(string label, string value, DomeniaFactState state, string source, string limit, string? hypothesis = null, DateTimeOffset? at = null, string? reader = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(label);
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        ArgumentException.ThrowIfNullOrWhiteSpace(source);
        if (state != DomeniaFactState.Observed && string.IsNullOrWhiteSpace(limit))
        {
            throw new ArgumentException("Une affirmation qui n’est pas un constat doit dire ce qu’elle ne prouve pas.", nameof(limit));
        }
        return new DomeniaFact(label, value, state, source, string.IsNullOrWhiteSpace(limit) ? LimitNotRecorded : limit, hypothesis, at, reader);
    }

    /// <summary>State of one measurement, for the directory and the readings modules, which now state their facts like the others.</summary>
    public static DomeniaFactState StateOf(MeasureState state) => state switch
    {
        MeasureState.Known or MeasureState.Absent => DomeniaFactState.Observed,
        MeasureState.Refused => DomeniaFactState.Refused,
        MeasureState.NotRead => DomeniaFactState.Unknown,
        MeasureState.Expired or MeasureState.Incomplete => DomeniaFactState.Estimated,
        _ => DomeniaFactState.Unavailable,
    };

    /// <summary>A fact of the directory or of the readings from one measure: source, limit, hypothesis and date travel with it.</summary>
    public static DomeniaFact OfMeasure(string label, string value, MeasureState state, string source, string limit, string? hypothesis = null, DateTimeOffset? at = null, string? reader = null) =>
        New(label, value, StateOf(state), source, limit, hypothesis, at, reader);

    /// <summary>
    /// Presence of a workstation as one explainable fact: a measure that never answered stays unknown and never becomes a
    /// verdict, the diagnostic says what it does not prove, and no cause is invented for a reading without one.
    /// </summary>
    public static DomeniaFact OfPresence(string label, PresenceMeasure? measure, string source = "Relevé ICMP enregistré", string? reader = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(label);
        ArgumentException.ThrowIfNullOrWhiteSpace(source);
        var m = measure ?? PresenceMeasure.Unread;
        if (m.HasReading)
        {
            var online = m.Answered == true;
            return new DomeniaFact(label, online ? "Répond au ping" : "Ne répond pas au ping", DomeniaFactState.Observed, source,
                online
                    ? "Un poste qui répond au ping peut refuser les outils d’administration."
                    : "Aucune réponse ICMP" + FrenchText.Colon + "poste éteint, hors du réseau ou ICMP filtré" + FrenchText.Colon + "ce n’est pas une preuve qu’il est éteint.",
                null, m.CheckedAt, reader);
        }
        var value = m.State switch
        {
            MeasureState.Error => "Lecture de présence en erreur",
            MeasureState.Refused => "Lecture de présence refusée",
            MeasureState.Expired => "Relevé de présence trop ancien",
            MeasureState.Incomplete => "Lecture de présence incomplète",
            MeasureState.Absent => "Poste sans présence à rendre",
            _ => "Jamais relevé",
        };
        return new DomeniaFact(label, value, m.State == MeasureState.Known ? DomeniaFactState.Unknown : StateOf(m.State), source,
            m.Diagnostic?.Text ?? "Aucune mesure utilisable" + FrenchText.Colon + "rien n’est conclu sur la présence du poste.",
            null, m.CheckedAt, reader);
    }
}
