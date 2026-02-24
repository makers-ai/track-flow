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

    test('should throw UnsupportedError for track_version entity type', () {
      expect(
        () => factory.getExecutor('track_version'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should throw UnsupportedError for audio_track entity type', () {
      expect(
        () => factory.getExecutor('audio_track'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should throw UnsupportedError for audio_comment entity type', () {
      expect(
        () => factory.getExecutor('audio_comment'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should throw UnsupportedError for audio_comment_by_version entity type', () {
      expect(
        () => factory.getExecutor('audio_comment_by_version'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should have empty supported entity types', () {
      final supportedTypes = factory.supportedEntityTypes;

      expect(supportedTypes, isEmpty);
      expect(supportedTypes.length, equals(0));
    });

    test('should not include any entity types in supported list', () {
      final supportedTypes = factory.supportedEntityTypes;

      expect(supportedTypes, isNot(contains('project')));
      expect(supportedTypes, isNot(contains('audio_track')));
      expect(supportedTypes, isNot(contains('audio_comment')));
      expect(supportedTypes, isNot(contains('audio_comment_by_version')));
      expect(supportedTypes, isNot(contains('track_version')));
    });
  });
}
