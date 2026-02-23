import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_local_datasource.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_remote_datasource.dart';
import 'package:trackflow/features/audio_track/data/models/audio_track_dto.dart';
import 'package:trackflow/features/audio_track/data/repositories/audio_track_repository_impl.dart';
import 'package:trackflow/features/audio_track/domain/entities/audio_track.dart';

import 'audio_track_repository_impl_test.mocks.dart';

@GenerateMocks([AudioTrackLocalDataSource, AudioTrackRemoteDataSource])
void main() {
  late AudioTrackRepositoryImpl repository;
  late MockAudioTrackLocalDataSource mockLocal;
  late MockAudioTrackRemoteDataSource mockRemote;

  late AudioTrack testTrack;
  late AudioTrackDTO testDto;
  late AudioTrackDTO remoteDtoResponse;

  setUp(() {
    mockLocal = MockAudioTrackLocalDataSource();
    mockRemote = MockAudioTrackRemoteDataSource();
    repository = AudioTrackRepositoryImpl(mockLocal, mockRemote);

    testTrack = AudioTrack(
      id: AudioTrackId.fromUniqueString('track-1'),
      name: 'Test Track',
      coverUrl: '',
      duration: const Duration(seconds: 120),
      projectId: ProjectId.fromUniqueString('project-1'),
      uploadedBy: UserId.fromUniqueString('user-1'),
      createdAt: DateTime(2025, 1, 1),
      activeVersionId: TrackVersionId.fromUniqueString('version-1'),
    );

    testDto = AudioTrackDTO(
      id: AudioTrackId.fromUniqueString('track-1'),
      name: 'Test Track',
      coverUrl: '',
      duration: 120000,
      projectId: ProjectId.fromUniqueString('project-1'),
      uploadedBy: UserId.fromUniqueString('user-1'),
      createdAt: DateTime(2025, 1, 1),
      extension: 'mp3',
      activeVersionId: TrackVersionId.fromUniqueString('version-1'),
    );

    remoteDtoResponse = AudioTrackDTO(
      id: AudioTrackId.fromUniqueString('track-1'),
      name: 'Test Track',
      coverUrl: '',
      duration: 120000,
      projectId: ProjectId.fromUniqueString('project-1'),
      uploadedBy: UserId.fromUniqueString('user-1'),
      createdAt: DateTime(2025, 1, 1),
      extension: 'mp3',
      activeVersionId: TrackVersionId.fromUniqueString('version-1'),
      lastModified: DateTime(2025, 1, 1, 0, 0, 1),
    );
  });

  // ---------------------------------------------------------------------------
  // createTrack — Remote-First
  // ---------------------------------------------------------------------------
  group('createTrack', () {
    test('should call remote first, then cache locally on success', () async {
      // Arrange
      when(mockRemote.createAudioTrack(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));
      when(mockLocal.cacheTrack(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.createTrack(testTrack);

      // Assert
      expect(result.isRight(), true);

      // Verify: remote called first, then local cache
      final verifications = verifyInOrder([
        mockRemote.createAudioTrack(any),
        mockLocal.cacheTrack(any),
      ]);
      for (final v in verifications) {
        v.called(1);
      }
    });

    test('should return failure when remote fails (no local cache, no rollback)', () async {
      // Arrange
      when(mockRemote.createAudioTrack(any))
          .thenAnswer((_) async => const Left(ServerFailure('Upload failed')));

      // Act
      final result = await repository.createTrack(testTrack);

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify: no local operations at all
      verifyNever(mockLocal.cacheTrack(any));
      verifyNever(mockLocal.deleteTrack(any));
    });
  });

  // ---------------------------------------------------------------------------
  // deleteTrack — Optimistic + Rollback
  // ---------------------------------------------------------------------------
  group('deleteTrack', () {
    test('should snapshot, delete locally, then call remote on success', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.deleteTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteAudioTrack(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.deleteTrack(
        AudioTrackId.fromUniqueString('track-1'),
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockLocal.deleteTrack('track-1')).called(1);
      verify(mockRemote.deleteAudioTrack('track-1')).called(1);
    });

    test('should rollback (re-cache) when remote fails', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.deleteTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockLocal.cacheTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteAudioTrack(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.deleteTrack(
        AudioTrackId.fromUniqueString('track-1'),
      );

      // Assert
      expect(result.isLeft(), true);
      verify(mockLocal.cacheTrack(testDto)).called(1);
    });

    test('should return failure when track not found locally', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => const Right(null));

      // Act
      final result = await repository.deleteTrack(
        AudioTrackId.fromUniqueString('track-1'),
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );
      verifyNever(mockLocal.deleteTrack(any));
      verifyNever(mockRemote.deleteAudioTrack(any));
    });
  });

  // ---------------------------------------------------------------------------
  // editTrackName — Optimistic + Rollback (try-catch, not Either)
  // ---------------------------------------------------------------------------
  group('editTrackName', () {
    test('should snapshot name, update locally, then call remote on success', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.updateTrackName(any, any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.editTrackName(any, any, any))
          .thenAnswer((_) async {});

      // Act
      final result = await repository.editTrackName(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        projectId: ProjectId.fromUniqueString('project-1'),
        newName: 'New Name',
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockLocal.updateTrackName('track-1', 'New Name')).called(1);
      verify(mockRemote.editTrackName('track-1', 'project-1', 'New Name')).called(1);
    });

    test('should rollback to previous name when remote throws', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.updateTrackName(any, any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.editTrackName(any, any, any))
          .thenThrow(Exception('Network error'));

      // Act
      final result = await repository.editTrackName(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        projectId: ProjectId.fromUniqueString('project-1'),
        newName: 'New Name',
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify rollback: optimistic update + rollback = 2 calls
      verify(mockLocal.updateTrackName('track-1', 'New Name')).called(1);
      verify(mockLocal.updateTrackName('track-1', 'Test Track')).called(1);
    });

    test('should not rollback name when no previous snapshot exists', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => const Left(CacheFailure('Not found')));
      when(mockLocal.updateTrackName(any, any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.editTrackName(any, any, any))
          .thenThrow(Exception('Network error'));

      // Act
      final result = await repository.editTrackName(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        projectId: ProjectId.fromUniqueString('project-1'),
        newName: 'New Name',
      );

      // Assert
      expect(result.isLeft(), true);
      // Only 1 call: optimistic update, no rollback
      verify(mockLocal.updateTrackName('track-1', 'New Name')).called(1);
      verifyNever(mockLocal.updateTrackName('track-1', 'Test Track'));
    });
  });

  // ---------------------------------------------------------------------------
  // setActiveVersion — Optimistic + Rollback
  // ---------------------------------------------------------------------------
  group('setActiveVersion', () {
    test('should snapshot versionId, update locally, then call remote on success', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.setActiveVersion(any, any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateActiveVersion(any, any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.setActiveVersion(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        versionId: TrackVersionId.fromUniqueString('version-2'),
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockLocal.setActiveVersion('track-1', 'version-2')).called(1);
      verify(mockRemote.updateActiveVersion('track-1', 'version-2')).called(1);
    });

    test('should rollback to previous versionId when remote fails', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.setActiveVersion(any, any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateActiveVersion(any, any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.setActiveVersion(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        versionId: TrackVersionId.fromUniqueString('version-2'),
      );

      // Assert
      expect(result.isLeft(), true);
      // Verify: optimistic + rollback
      verify(mockLocal.setActiveVersion('track-1', 'version-2')).called(1);
      verify(mockLocal.setActiveVersion('track-1', 'version-1')).called(1);
    });

    test('should return local failure when local update fails', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.setActiveVersion(any, any))
          .thenAnswer((_) async => const Left(CacheFailure('Local error')));

      // Act
      final result = await repository.setActiveVersion(
        trackId: AudioTrackId.fromUniqueString('track-1'),
        versionId: TrackVersionId.fromUniqueString('version-2'),
      );

      // Assert
      expect(result.isLeft(), true);
      verifyNever(mockRemote.updateActiveVersion(any, any));
    });
  });

  // ---------------------------------------------------------------------------
  // updateTrack — Optimistic + Rollback (cover art)
  // ---------------------------------------------------------------------------
  group('updateTrack', () {
    test('should snapshot, update locally, then call remote cover art on success', () async {
      // Arrange
      final trackWithCover = testTrack.copyWith(coverUrl: 'https://example.com/cover.jpg');
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.updateTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackCoverUrl(any, any, any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.updateTrack(trackWithCover);

      // Assert
      expect(result.isRight(), true);
      verify(mockRemote.updateTrackCoverUrl(
        'track-1',
        'https://example.com/cover.jpg',
        null,
      )).called(1);
    });

    test('should rollback to previous DTO when remote fails', () async {
      // Arrange
      final trackWithCover = testTrack.copyWith(coverUrl: 'https://example.com/cover.jpg');
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.updateTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockLocal.cacheTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackCoverUrl(any, any, any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.updateTrack(trackWithCover);

      // Assert
      expect(result.isLeft(), true);
      verify(mockLocal.cacheTrack(testDto)).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // getTrackById — Local only
  // ---------------------------------------------------------------------------
  group('getTrackById', () {
    test('should return local track when cache hit', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => Right(testDto));

      // Act
      final result = await repository.getTrackById(
        AudioTrackId.fromUniqueString('track-1'),
      );

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (track) => expect(track.id.value, 'track-1'),
      );
    });

    test('should return failure when not in cache', () async {
      // Arrange
      when(mockLocal.getTrackById(any))
          .thenAnswer((_) async => const Right(null));

      // Act
      final result = await repository.getTrackById(
        AudioTrackId.fromUniqueString('track-1'),
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // watchTracksByProject — Stream + Background Revalidation
  // ---------------------------------------------------------------------------
  group('watchTracksByProject', () {
    test('should return stream from local data source', () async {
      // Arrange
      when(mockLocal.watchTracksByProject(any)).thenAnswer(
        (_) => Stream.value(Right([testDto])),
      );
      // Mock revalidation calls (fire-and-forget)
      when(mockRemote.getTracksByProjectIds(any))
          .thenAnswer((_) async => [remoteDtoResponse]);
      when(mockLocal.cacheTrack(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockLocal.getAllTracks())
          .thenAnswer((_) async => Right([testDto]));

      // Act
      final stream = repository.watchTracksByProject(
        ProjectId.fromUniqueString('project-1'),
      );
      final result = await stream.first;

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (tracks) {
          expect(tracks.length, 1);
          expect(tracks.first.id.value, 'track-1');
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  // watchTrackById
  // ---------------------------------------------------------------------------
  group('watchTrackById', () {
    test('should return stream from local data source', () async {
      // Arrange
      when(mockLocal.watchTrackById(any)).thenAnswer(
        (_) => Stream.value(Right(testDto)),
      );

      // Act
      final stream = repository.watchTrackById(
        AudioTrackId.fromUniqueString('track-1'),
      );
      final result = await stream.first;

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (track) => expect(track.id.value, 'track-1'),
      );
    });

    test('should return failure when track is null', () async {
      // Arrange
      when(mockLocal.watchTrackById(any)).thenAnswer(
        (_) => Stream.value(const Right(null)),
      );

      // Act
      final stream = repository.watchTrackById(
        AudioTrackId.fromUniqueString('track-1'),
      );
      final result = await stream.first;

      // Assert
      expect(result.isLeft(), true);
    });
  });

  // ---------------------------------------------------------------------------
  // deleteAllTracks
  // ---------------------------------------------------------------------------
  group('deleteAllTracks', () {
    test('should delegate to local data source', () async {
      // Arrange
      when(mockLocal.deleteAllTracks())
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.deleteAllTracks();

      // Assert
      expect(result.isRight(), true);
      verify(mockLocal.deleteAllTracks()).called(1);
    });

    test('should return failure when local throws', () async {
      // Arrange
      when(mockLocal.deleteAllTracks()).thenThrow(Exception('DB error'));

      // Act
      final result = await repository.deleteAllTracks();

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );
    });
  });
}
