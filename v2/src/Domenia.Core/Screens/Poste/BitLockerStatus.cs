namespace Domenia.Core.Poste;

/// <summary>Interpret the provider's separate encryption and protection states without turning a missing field into zero.</summary>
public sealed record BitLockerStatus(string Label, FactState State, Tone Tone, bool Suspended = false)
{
    public const string Limit = "Protection désactivée ne signifie pas non chiffré. Une méthode ou un pourcentage seuls ne prouvent pas un chiffrement terminé.";

    public static BitLockerStatus Of(BitLockerVolume volume)
    {
        // Microsoft documents rounding at 0/100 percent: only the status codes prove completion.
        // Contradictory values from different provider snapshots must not produce a healthy or unencrypted verdict.
        if (volume.Protection == 1 && (volume.Conversion is 0 or 2 or 3 or 4 or 5 || volume.Method == 0)
            || volume.Method == 0 && volume.Conversion is 1 or 2 or 3 or 4 or 5)
        { return new("États incohérents", FactState.Unknown, Tone.Warn); }
        if (volume.Protection == 1) { return new("Protégé", FactState.Observed, Tone.Ok); }
        return volume.Conversion switch
        {
            0 when volume.Method == 5 => new("Chiffrement matériel déverrouillé", FactState.Observed, Tone.Warn),
            0 => new("Non chiffré", FactState.Observed, Tone.Warn),
            1 when volume.Protection == 0 => new("Protection suspendue", FactState.Observed, Tone.Warn, true),
            1 => new("Chiffré, protection inconnue", FactState.Observed, Tone.Warn),
            2 => new("Chiffrement en cours", FactState.Observed, Tone.Warn),
            3 => new("Déchiffrement en cours", FactState.Observed, Tone.Warn),
            4 => new("Chiffrement en pause", FactState.Observed, Tone.Warn),
            5 => new("Déchiffrement en pause", FactState.Observed, Tone.Warn),
            _ when volume.Method == 0 => new("Non chiffré", FactState.Observed, Tone.Warn),
            _ when volume.Protection == 0 => new("Protection désactivée, chiffrement inconnu", FactState.Unknown, Tone.Warn),
            _ => new("État inconnu", FactState.Unknown, Tone.Warn),
        };
    }

    public static string Detail(BitLockerVolume volume)
    {
        var text = Of(volume).Label;
        if (volume.Method is int method and > 0) { text += " · " + PosteLabels.BitLockerMethod(method); }
        if (volume.EncryptedPercent is double percent and >= 0 and <= 100) { text += " · " + FrenchText.Percent(percent, 0) + " chiffré"; }
        if (volume.ProtectorCount is int count and >= 0) { text += " · " + FrenchText.Count(count, "protecteur", "protecteurs"); }
        return text;
    }
}
