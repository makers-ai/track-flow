import 'package:flutter_test/flutter_test.dart';
import 'package:trackflow/core/sync/domain/executors/operation_executor_factory.dart';

void main() {
  late OperationExecutorFactory factory;

  setUp(() {
    factory = OperationExecutorFactory();
  });

  group('OperationExecutorFactory', () {
    test('should throw UnsupportedError for unknown entity type', () {
      expect(
        () => factory.getExecutor('unknown_entity'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should throw UnsupportedError for empty string entity type', () {
      expect(() => factory.getExecutor(''), throwsA(isA<UnsupportedError>()));
    });

    test('should throw UnsupportedError for audio_track entity type', () {
      expect(
        () => factory.getExecutor('audio_track'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should have correct supported entity types', () {
      final supportedTypes = factory.supportedEntityTypes;

      expect(
        supportedTypes,
        containsAll([
          'track_version',
          'audio_comment',
          'audio_comment_by_version',
        ]),
      );
      expect(supportedTypes.length, equals(3));
    });

    test('should not include project or audio_track in supported entity types', () {
      final supportedTypes = factory.supportedEntityTypes;

      expect(supportedTypes, isNot(contains('project')));
      expect(supportedTypes, isNot(contains('audio_track')));
    });
  });
}
