namespace Domenia.Ad;

/// <summary>No definitive LDAP response was received after sending. Never classified as a proven refusal or retried.</summary>
public sealed class AdWriteOutcomeUnknownException() : Exception("Issue de l’écriture LDAP inconnue ; une relecture est nécessaire.");
