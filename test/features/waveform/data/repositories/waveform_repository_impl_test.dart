import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/waveform/domain/entities/audio_waveform.dart';
import 'package:trackflow/features/waveform/domain/value_objects/waveform_data.dart';
import 'package:trackflow/features/waveform/domain/value_objects/waveform_metadata.dart';
import 'package:trackflow/features/waveform/data/datasources/waveform_local_datasource.dart';
import 'package:trackflow/features/waveform/data/datasources/waveform_remote_datasource.dart';
import 'package:trackflow/features/waveform/data/repositories/waveform_repository_impl.dart';

import 'waveform_repository_impl_test.mocks.dart';

@GenerateMocks([WaveformLocalDataSource, WaveformRemoteDataSource])
void main() {
  late WaveformRepositoryImpl repository;
  late MockWaveformLocalDataSource mockLocalDataSource;
  late MockWaveformRemoteDataSource mockRemoteDataSource;

  late AudioTrackId testTrackId;
  late TrackVersionId testVersionId;
  late AudioWaveform testWaveform;

  setUp(() {
    mockLocalDataSource = MockWaveformLocalDataSource();
    mockRemoteDataSource = MockWaveformRemoteDataSource();

    repository = WaveformRepositoryImpl(
      localDataSource: mockLocalDataSource,
      remoteDataSource: mockRemoteDataSource,
    );

    testTrackId = AudioTrackId.fromUniqueString('track-123');
    testVersionId = TrackVersionId.fromUniqueString('version-456');

    testWaveform = AudioWaveform(
      id: AudioWaveformId.fromUniqueString('waveform-789'),
      versionId: testVersionId,
      data: WaveformData(
        amplitudes: [0.1, 0.5, 0.8, 0.3],
        sampleRate: 44100,
        duration: const Duration(seconds: 180),
        targetSampleCount: 200,
      ),
      metadata: WaveformMetadata(
        maxAmplitude: 0.8,
        rmsLevel: 0.4,
        compressionLevel: 1,
        generationMethod: 'just_waveform',
      ),
      generatedAt: DateTime(2025, 1, 1),
    );
  });

  group('WaveformRepositoryImpl', () {
    group('getWaveformByVersionId', () {
      test('should return local waveform when found in cache', () async {
        // Arrange
        when(
          mockLocalDataSource.getWaveformByVersionId(testVersionId),
        ).thenAnswer((_) async => testWaveform);

        // Act
        final result = await repository.getWaveformByVersionId(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (waveform) => expect(waveform, testWaveform),
        );

        // Should not call remote when local cache hit
        verifyNever(
          mockRemoteDataSource.fetchCanonicalForVersion(
            trackId: anyNamed('trackId'),
            versionId: anyNamed('versionId'),
          ),
        );
      });

      test('should fallback to remote when not in local cache', () async {
        // Arrange
        when(
          mockLocalDataSource.getWaveformByVersionId(testVersionId),
        ).thenAnswer((_) async => null);

        when(
          mockRemoteDataSource.fetchCanonicalForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).thenAnswer((_) async => testWaveform);

        when(
          mockLocalDataSource.saveWaveform(testWaveform),
        ).thenAnswer((_) async {});

        // Act
        final result = await repository.getWaveformByVersionId(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (waveform) => expect(waveform, testWaveform),
        );
      });

      test('should cache waveform locally after remote fetch', () async {
        // Arrange
        when(
          mockLocalDataSource.getWaveformByVersionId(testVersionId),
        ).thenAnswer((_) async => null);

        when(
          mockRemoteDataSource.fetchCanonicalForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).thenAnswer((_) async => testWaveform);

        when(
          mockLocalDataSource.saveWaveform(testWaveform),
        ).thenAnswer((_) async {});

        // Act
        await repository.getWaveformByVersionId(testTrackId, testVersionId);

        // Assert
        verify(mockLocalDataSource.saveWaveform(testWaveform)).called(1);
      });

      test('should return failure when not found in local or remote', () async {
        // Arrange
        when(
          mockLocalDataSource.getWaveformByVersionId(testVersionId),
        ).thenAnswer((_) async => null);

        when(
          mockRemoteDataSource.fetchCanonicalForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).thenAnswer((_) async => null);

        // Act
        final result = await repository.getWaveformByVersionId(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Should not try to cache null
        verifyNever(mockLocalDataSource.saveWaveform(any));
      });

      test('should return failure when local throws exception', () async {
        // Arrange
        when(
          mockLocalDataSource.getWaveformByVersionId(testVersionId),
        ).thenThrow(Exception('Database error'));

        // Act
        final result = await repository.getWaveformByVersionId(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );
      });
    });

    group('deleteWaveformsForVersion', () {
      test('should delete remote first then local', () async {
        // Arrange
        when(
          mockRemoteDataSource.deleteWaveformsForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).thenAnswer((_) async {});

        when(
          mockLocalDataSource.deleteWaveformsForVersion(testVersionId),
        ).thenAnswer((_) async {});

        // Act
        final result = await repository.deleteWaveformsForVersion(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isRight(), true);

        // Verify both were called
        verify(
          mockRemoteDataSource.deleteWaveformsForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).called(1);
        verify(
          mockLocalDataSource.deleteWaveformsForVersion(testVersionId),
        ).called(1);
      });

      test('should propagate remote error without touching local', () async {
        // Arrange
        when(
          mockRemoteDataSource.deleteWaveformsForVersion(
            trackId: testTrackId.value,
            versionId: testVersionId,
          ),
        ).thenThrow(Exception('Remote deletion failed'));

        // Act
        final result = await repository.deleteWaveformsForVersion(
          testTrackId,
          testVersionId,
        );

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Local should NOT be called when remote fails
        verifyNever(
          mockLocalDataSource.deleteWaveformsForVersion(any),
        );
      });
    });

    group('storeCanonicalWaveformOnline', () {
      test('should upload to remote first then cache locally', () async {
        // Arrange
        when(
          mockRemoteDataSource.uploadCanonical(
            trackId: testTrackId.value,
            waveform: testWaveform,
          ),
        ).thenAnswer((_) async {});

        when(
          mockLocalDataSource.saveWaveform(testWaveform),
        ).thenAnswer((_) async {});

        // Act
        final result = await repository.storeCanonicalWaveformOnline(
          trackId: testTrackId,
          waveform: testWaveform,
        );

        // Assert
        expect(result.isRight(), true);

        verify(
          mockRemoteDataSource.uploadCanonical(
            trackId: testTrackId.value,
            waveform: testWaveform,
          ),
        ).called(1);
        verify(mockLocalDataSource.saveWaveform(testWaveform)).called(1);
      });

      test('should propagate remote error without caching locally', () async {
        // Arrange
        when(
          mockRemoteDataSource.uploadCanonical(
            trackId: testTrackId.value,
            waveform: testWaveform,
          ),
        ).thenThrow(Exception('Upload failed'));

        // Act
        final result = await repository.storeCanonicalWaveformOnline(
          trackId: testTrackId,
          waveform: testWaveform,
        );

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Local should NOT be called when remote fails
        verifyNever(mockLocalDataSource.saveWaveform(any));
      });
    });

    group('clearAllWaveforms', () {
      test('should clear local cache', () async {
        // Arrange
        when(mockLocalDataSource.clearAll()).thenAnswer((_) async {});

        // Act
        final result = await repository.clearAllWaveforms();

        // Assert
        expect(result.isRight(), true);
        verify(mockLocalDataSource.clearAll()).called(1);
      });

      test('should return failure when clear throws', () async {
        // Arrange
        when(mockLocalDataSource.clearAll()).thenThrow(Exception('Clear failed'));

        // Act
        final result = await repository.clearAllWaveforms();

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );
      });
    });

    group('watchWaveformChanges', () {
      test('should delegate to local datasource', () {
        // Arrange
        when(
          mockLocalDataSource.watchWaveformChanges(testVersionId),
        ).thenAnswer((_) => Stream.value(testWaveform));

        // Act
        final stream = repository.watchWaveformChanges(testVersionId);

        // Assert
        expect(stream, isA<Stream<AudioWaveform>>());
        verify(
          mockLocalDataSource.watchWaveformChanges(testVersionId),
        ).called(1);
      });
    });
  });
}
