import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/track_version/data/datasources/track_version_local_data_source.dart';
import 'package:trackflow/features/track_version/data/datasources/track_version_remote_datasource.dart';
import 'package:trackflow/features/track_version/data/models/track_version_dto.dart';
import 'package:trackflow/features/track_version/data/repositories/track_version_repository_impl.dart';

import 'track_version_repository_impl_test.mocks.dart';

@GenerateMocks([TrackVersionLocalDataSource, TrackVersionRemoteDataSource])
void main() {
  late TrackVersionRepositoryImpl repository;
  late MockTrackVersionLocalDataSource mockLocal;
  late MockTrackVersionRemoteDataSource mockRemote;

  late TrackVersionDTO testDto;
  final testVersionId = TrackVersionId.fromUniqueString('test-version-id');
  final testTrackId = AudioTrackId.fromUniqueString('test-track-id');

  setUp(() {
    mockLocal = MockTrackVersionLocalDataSource();
    mockRemote = MockTrackVersionRemoteDataSource();
    repository = TrackVersionRepositoryImpl(mockLocal, mockRemote);

    testDto = TrackVersionDTO(
      id: 'test-version-id',
      trackId: 'test-track-id',
      versionNumber: 1,
      label: 'Original Label',
      fileLocalPath: '/path/to/file.mp3',
      fileRemoteUrl: 'https://storage.example.com/file.mp3',
      durationMs: 120000,
      status: 'ready',
      createdAt: DateTime(2025, 1, 1),
      createdBy: 'test-user-id',
      isDeleted: false,
      version: 1,
      lastModified: DateTime(2025, 1, 1),
    );
  });

  // ---------------------------------------------------------------------------
  // setActiveVersion
  // ---------------------------------------------------------------------------
  group('setActiveVersion', () {
    test('should snapshot, cache updated DTO, call remote, return success', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackVersionMetadata(any)).thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.setActiveVersion(
        trackId: testTrackId,
        versionId: testVersionId,
      );

      // Assert
      expect(result.isRight(), true);

      // Verify: 1) snapshot, 2) optimistic cache, 3) remote call
      final verifications = verifyInOrder([
        mockLocal.getVersionById('test-version-id'),
        mockLocal.cacheVersion(any),
        mockRemote.updateTrackVersionMetadata(any),
      ]);
      for (final v in verifications) {
        v.called(1);
      }
    });

    test('should rollback when remote fails', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackVersionMetadata(any)).thenAnswer(
        (_) async => const Left(ServerFailure('Remote failed')),
      );

      // Act
      final result = await repository.setActiveVersion(
        trackId: testTrackId,
        versionId: testVersionId,
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify rollback: cacheVersion called twice (optimistic + rollback)
      verify(mockLocal.cacheVersion(any)).called(2);
    });

    test('should return failure when version not found', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => const Right(null));

      // Act
      final result = await repository.setActiveVersion(
        trackId: testTrackId,
        versionId: testVersionId,
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify no remote call was made
      verifyNever(mockRemote.updateTrackVersionMetadata(any));
    });
  });

  // ---------------------------------------------------------------------------
  // deleteVersion
  // ---------------------------------------------------------------------------
  group('deleteVersion', () {
    test('should snapshot, delete locally, call remote, return success', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(mockLocal.deleteVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteTrackVersion(any)).thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.deleteVersion(testVersionId);

      // Assert
      expect(result.isRight(), true);

      final verifications = verifyInOrder([
        mockLocal.getVersionById('test-version-id'),
        mockLocal.deleteVersion(testVersionId),
        mockRemote.deleteTrackVersion('test-version-id'),
      ]);
      for (final v in verifications) {
        v.called(1);
      }
    });

    test('should rollback when remote fails', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(mockLocal.deleteVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockLocal.cacheVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteTrackVersion(any)).thenAnswer(
        (_) async => const Left(ServerFailure('Remote failed')),
      );

      // Act
      final result = await repository.deleteVersion(testVersionId);

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify rollback: re-cache the snapshot
      verify(mockLocal.cacheVersion(testDto)).called(1);
    });

    test('should return failure when version not found', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => const Right(null));

      // Act
      final result = await repository.deleteVersion(testVersionId);

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );

      verifyNever(mockLocal.deleteVersion(any));
      verifyNever(mockRemote.deleteTrackVersion(any));
    });
  });

  // ---------------------------------------------------------------------------
  // renameVersion
  // ---------------------------------------------------------------------------
  group('renameVersion', () {
    test('should snapshot, rename locally, call remote, return success', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(
        mockLocal.renameVersion(versionId: anyNamed('versionId'), newLabel: anyNamed('newLabel')),
      ).thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackVersionMetadata(any)).thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.renameVersion(
        versionId: testVersionId,
        newLabel: 'New Label',
      );

      // Assert
      expect(result.isRight(), true);

      final verifications = verifyInOrder([
        mockLocal.getVersionById('test-version-id'),
        mockLocal.renameVersion(versionId: testVersionId, newLabel: 'New Label'),
        mockRemote.updateTrackVersionMetadata(any),
      ]);
      for (final v in verifications) {
        v.called(1);
      }
    });

    test('should rollback when remote fails', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => Right(testDto));
      when(
        mockLocal.renameVersion(versionId: anyNamed('versionId'), newLabel: anyNamed('newLabel')),
      ).thenAnswer((_) async => const Right(unit));
      when(mockLocal.cacheVersion(any)).thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateTrackVersionMetadata(any)).thenAnswer(
        (_) async => const Left(ServerFailure('Remote failed')),
      );

      // Act
      final result = await repository.renameVersion(
        versionId: testVersionId,
        newLabel: 'New Label',
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify rollback: re-cache the original DTO (restores original label)
      verify(mockLocal.cacheVersion(testDto)).called(1);
    });

    test('should return failure when version not found', () async {
      // Arrange
      when(mockLocal.getVersionById(any)).thenAnswer((_) async => const Right(null));

      // Act
      final result = await repository.renameVersion(
        versionId: testVersionId,
        newLabel: 'New Label',
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );

      verifyNever(mockLocal.renameVersion(versionId: anyNamed('versionId'), newLabel: anyNamed('newLabel')));
      verifyNever(mockRemote.updateTrackVersionMetadata(any));
    });
  });

  // ---------------------------------------------------------------------------
  // addVersionOnline
  // ---------------------------------------------------------------------------
  group('addVersionOnline', () {
    test('should call remote then cache locally on success', () async {
      // Arrange
      final uploadedDto = TrackVersionDTO(
        id: 'new-version-id',
        trackId: 'test-track-id',
        versionNumber: 1,
        fileRemoteUrl: 'https://storage.example.com/uploaded.mp3',
        status: 'ready',
        createdAt: DateTime(2025, 1, 1),
        createdBy: 'test-user-id',
      );

      when(mockLocal.getVersionsByTrack(any)).thenAnswer((_) async => const Right(<TrackVersionDTO>[]));
      when(mockRemote.createTrackVersion(any, any)).thenAnswer((_) async => Right(uploadedDto));
      when(mockLocal.cacheVersion(any)).thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.addVersionOnline(
        trackId: testTrackId,
        file: File('/path/to/audio.mp3'),
        duration: const Duration(minutes: 2),
        createdBy: 'test-user-id',
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockRemote.createTrackVersion(any, any)).called(1);
      verify(mockLocal.cacheVersion(uploadedDto)).called(1);
    });

    test('should return failure when remote fails without caching locally', () async {
      // Arrange
      when(mockLocal.getVersionsByTrack(any)).thenAnswer((_) async => const Right(<TrackVersionDTO>[]));
      when(mockRemote.createTrackVersion(any, any)).thenAnswer(
        (_) async => const Left(ServerFailure('Upload failed')),
      );

      // Act
      final result = await repository.addVersionOnline(
        trackId: testTrackId,
        file: File('/path/to/audio.mp3'),
        duration: const Duration(minutes: 2),
        createdBy: 'test-user-id',
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify no local caching happened
      verifyNever(mockLocal.cacheVersion(any));
    });
  });

  // ---------------------------------------------------------------------------
  // clearCache
  // ---------------------------------------------------------------------------
  group('clearCache', () {
    test('should delegate to local data source', () async {
      // Arrange
      when(mockLocal.clearCache()).thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.clearCache();

      // Assert
      expect(result.isRight(), true);
      verify(mockLocal.clearCache()).called(1);
    });

    test('should return failure when local data source throws', () async {
      // Arrange
      when(mockLocal.clearCache()).thenThrow(Exception('Database error'));

      // Act
      final result = await repository.clearCache();

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );
    });
  });
}
