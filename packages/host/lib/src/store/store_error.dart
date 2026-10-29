/// Typed store errors; the codes are mapped onto the hello reply later.
sealed class StoreError implements Exception {
  const StoreError();

  String get code;
}

/// A migration step failed; the store stays at [fromVersion].
final class StoreMigrationFailed extends StoreError {
  const StoreMigrationFailed({
    required this.fromVersion,
    required this.toVersion,
    required this.cause,
  });

  final int fromVersion;
  final int toVersion;
  final Object cause;

  @override
  String get code => 'store-migration-failed';

  @override
  String toString() =>
      '$code: migration $fromVersion -> $toVersion failed: $cause';
}

/// The store's schema version is newer than this host supports.
final class StoreNewer extends StoreError {
  const StoreNewer({required this.storeVersion, required this.supportedVersion});

  final int storeVersion;
  final int supportedVersion;

  @override
  String get code => 'store-newer';

  @override
  String toString() =>
      '$code: store version $storeVersion, supported $supportedVersion';
}

/// The store file exists but cannot be opened or read as a database.
final class StoreUnreadable extends StoreError {
  const StoreUnreadable({required this.path, this.cause});

  final String path;
  final Object? cause;

  @override
  String get code => 'store-unreadable';

  @override
  String toString() => '$code: $path${cause == null ? '' : ' ($cause)'}';
}
