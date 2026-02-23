import 'package:injectable/injectable.dart';
import 'package:trackflow/core/di/injection.dart';
import 'package:trackflow/core/sync/domain/executors/operation_executor.dart';
import 'package:trackflow/core/sync/domain/executors/track_version_operation_executor.dart';

/// Factory for creating operation executors based on entity type
///
/// This factory follows the Strategy pattern, providing the appropriate
/// executor implementation for each entity type. This allows the
/// PendingOperationsManager to remain generic and focused on coordination.
@injectable
class OperationExecutorFactory {
  /// Get the appropriate executor for the given entity type
  ///
  /// Returns a configured executor that can handle operations
  /// for the specified entity type.
  ///
  /// Throws [UnsupportedError] if the entity type is not supported.
  OperationExecutor getExecutor(String entityType) {
    switch (entityType) {
      case 'track_version':
        return sl<TrackVersionOperationExecutor>();
      default:
        throw UnsupportedError(
          'No executor found for entity type: $entityType',
        );
    }
  }

  /// Get all supported entity types
  List<String> get supportedEntityTypes => [
    'track_version',
  ];
}
