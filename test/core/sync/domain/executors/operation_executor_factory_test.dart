import 'package:flutter_test/flutter_test.dart';
import 'package:trackflow/core/sync/domain/executors/operation_executor_factory.dart';

void main() {
  late OperationExecutorFactory factory;

  setUp(() {
    factory = OperationExecutorFactory();
  });

  group('OperationExecutorFactory', () {
    test('should throw UnsupportedError for unknown entity type', () {
      // Act & Assert
      expect(
        () => factory.getExecutor('unknown_entity'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should throw UnsupportedError for empty string entity type', () {
      // Act & Assert
      expect(() => factory.getExecutor(''), throwsA(isA<UnsupportedError>()));
    });

    test('should have correct supported entity types', () {
      // Act
      final supportedTypes = factory.supportedEntityTypes;

      // Assert
      expect(
        supportedTypes,
        containsAll([
          'audio_track',
          'track_version',
          'audio_comment',
          'audio_comment_by_version',
        ]),
      );
      expect(supportedTypes.length, equals(4));
    });

    test('should not include project in supported entity types', () {
      // Act
      final supportedTypes = factory.supportedEntityTypes;

      // Assert
      expect(supportedTypes, isNot(contains('project')));
    });
  });
}
