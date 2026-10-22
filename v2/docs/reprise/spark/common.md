# Contexte commun (Domenia 2)

Tu écris du code pour Domenia 2 : réécriture en C# .NET 10 (net10.0-windows, x64) et WebView2 d'un outil d'administration
Active Directory (Domenia 1, PowerShell). Le dépôt est déjà en place ; tu ne vois que les fichiers fournis ci-dessous.

Règles impératives :
- C# : `Nullable` activé, `ImplicitUsings` activé, avertissements traités comme erreurs, `AnalysisLevel latest`
  (analyseurs .NET : CA1062 arguments, CA1305/CA1307/CA1309/CA1310 culture et comparaisons ordinales explicites,
  CA2007 `ConfigureAwait(false)` sur chaque await dans les bibliothèques, CA1031, CA1001/CA2000 disposition, CA1849, etc.).
  Écris du code qui compile sans AUCUN avertissement : `ArgumentNullException.ThrowIfNull`, `StringComparison.Ordinal`
  ou `OrdinalIgnoreCase`, `CultureInfo.InvariantCulture`, `.ConfigureAwait(false)`, pas de `catch (Exception)` nu sauf
  avec `#pragma warning disable CA1031` justifié, `sealed` pour les classes non héritées, `static` quand possible.
- Pas de `dynamic`, pas de réflexion inutile, pas de dépendance NuGet nouvelle (seulement ce qui est cité).
- Commentaires et documentation XML en ANGLAIS. Textes visibles (messages d'erreur, libellés) en FRANÇAIS soigné, avec
  une espace insécable U+00A0 avant « : ; ? ! % » et à l'intérieur des guillemets « », apostrophe typographique ’.
  Dans le code C#, utilise `FrenchText.Colon` (« \u00A0: ») et `FrenchText.Nbsp` quand c'est disponible.
- Sécurité : jamais de secret (mot de passe, jeton) dans un message, un journal ou une exception ; lecture seule par défaut.
- Espaces de noms : file-scoped (`namespace X;`). Une classe publique par fichier sauf petits records liés.
- Ne modifie PAS les fichiers fournis en contexte sauf si la tâche le demande explicitement ; crée de nouveaux fichiers.

Format de réponse OBLIGATOIRE : uniquement des fichiers complets, chacun ainsi (chemin relatif depuis la racine du dépôt) :

=== FILE: v2/src/Exemple/Chemin.cs ===
<contenu complet du fichier>
=== END FILE ===

Après les fichiers, une courte section « NOTES » (5 lignes au plus) : hypothèses, points à vérifier. Rien d'autre.
