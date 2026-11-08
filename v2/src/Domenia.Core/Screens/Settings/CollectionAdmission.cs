namespace Domenia.Core;

/// <summary>Admission of a whole explicit population: never implement a limit with Take().</summary>
public static class CollectionAdmission
{
    public const string Ceiling = "collection.ceiling";
    public const string WindowClosed = "collection.windowClosed";

    public static CollectionSettings Read(IPreferenceStore preferences) => CollectionSettingsRules.Read(
        preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var stored) ? stored : null, []);

    public static int Maximum(CollectionSettings settings, bool widget = false)
    {
        var maximum = settings.Budgets.GetValueOrDefault(CollectionSettingsRules.MaxTargets, 500);
        var widgetMaximum = settings.Budgets.GetValueOrDefault(CollectionSettingsRules.WidgetMax);
        return widget && widgetMaximum > 0 ? Math.Min(maximum, widgetMaximum) : maximum;
    }

    public static void EnsureTargets(CollectionSettings settings, int count, bool widget = false)
    {
        if (count < 0) throw new ArgumentOutOfRangeException(nameof(count));
        var maximum = Maximum(settings, widget);
        if (count > maximum) throw new DomeniaOperationException(widget ? "widget.ceiling" : Ceiling,
            "La collecte demanderait " + FrenchText.Integer(count) + " postes : plafond " + FrenchText.Integer(maximum)
            + ". Aucun poste sélectionné arbitrairement ; choisissez une OU plus précise ou adaptez les paramètres de collecte.");
    }

    public static CollectionWindowState Window(CollectionSettings settings, TimeProvider clock) =>
        CollectionWindowRules.StateAt(CollectionWindowRules.Parse(CollectionSettingsRules.WindowText(settings)), clock.GetUtcNow(), clock.LocalTimeZone);

    public static string Notice(CollectionSettings settings, TimeProvider clock)
    {
        var state = Window(settings, clock);
        return CollectionWindowRules.Sentence(state, clock.GetUtcNow(), clock.LocalTimeZone)
            + (!state.Open ? " Cette collecte explicite reste possible après confirmation." : "");
    }

    public static void EnsureBackground(CollectionSettings settings, TimeProvider clock)
    {
        if (!Window(settings, clock).Open) throw new DomeniaOperationException(WindowClosed,
            "Vérification automatique suspendue. " + CollectionWindowRules.Sentence(Window(settings, clock), clock.GetUtcNow(), clock.LocalTimeZone));
    }
}
