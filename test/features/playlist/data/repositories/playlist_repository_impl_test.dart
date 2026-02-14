import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:dartz/dartz.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/playlist/domain/entities/playlist.dart';
import 'package:trackflow/features/playlist/data/datasources/playlist_local_data_source.dart';
import 'package:trackflow/features/playlist/data/datasources/playlist_remote_data_source.dart';
import 'package:trackflow/features/playlist/data/models/playlist_dto.dart';
import 'package:trackflow/features/playlist/data/repositories/playlist_repository_impl.dart';

import 'playlist_repository_impl_test.mocks.dart';

@GenerateMocks([PlaylistLocalDataSource, PlaylistRemoteDataSource])
void main() {
  late PlaylistRepositoryImpl repository;
  late MockPlaylistLocalDataSource mockLocalDataSource;
  late MockPlaylistRemoteDataSource mockRemoteDataSource;

  late Playlist testPlaylist;
  late PlaylistDto testDto;
  late PlaylistId testPlaylistId;

  setUp(() {
    mockLocalDataSource = MockPlaylistLocalDataSource();
    mockRemoteDataSource = MockPlaylistRemoteDataSource();

    repository = PlaylistRepositoryImpl(mockLocalDataSource, mockRemoteDataSource);

    testPlaylistId = PlaylistId.fromUniqueString('playlist-123');

    testPlaylist = Playlist(
      id: testPlaylistId,
      name: 'Test Playlist',
      trackIds: ['track-1', 'track-2'],
      playlistSource: PlaylistSource.user,
    );

    testDto = PlaylistDto(
      id: 'playlist-123',
      name: 'Test Playlist',
      trackIds: ['track-1', 'track-2'],
      playlistSource: 'user',
    );
  });

  group('PlaylistRepositoryImpl', () {
    group('addPlaylist', () {
      test('should write locally first then succeed on remote', () async {
        // Arrange
        when(mockLocalDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.addPlaylist(testPlaylist);

        // Assert
        expect(result.isRight(), true);
        verify(mockLocalDataSource.addPlaylist(any)).called(1);
        verify(mockRemoteDataSource.addPlaylist(any)).called(1);
      });

      test('should rollback local write when remote fails', () async {
        // Arrange
        when(mockLocalDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.addPlaylist(any)).thenAnswer((_) async => Left(ServerFailure('Remote failed')));
        when(mockLocalDataSource.deletePlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.addPlaylist(testPlaylist);

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Verify rollback: local delete was called
        verify(mockLocalDataSource.deletePlaylist(testPlaylist.id.value)).called(1);
      });
    });

    group('updatePlaylist', () {
      test('should write locally first then succeed on remote', () async {
        // Arrange
        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.updatePlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.updatePlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.updatePlaylist(testPlaylist);

        // Assert
        expect(result.isRight(), true);
        verify(mockLocalDataSource.updatePlaylist(any)).called(1);
        verify(mockRemoteDataSource.updatePlaylist(any)).called(1);
      });

      test('should rollback to snapshot when remote fails', () async {
        // Arrange
        final snapshotDto = PlaylistDto(
          id: 'playlist-123',
          name: 'Original Name',
          trackIds: ['track-1'],
          playlistSource: 'user',
        );

        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(snapshotDto));
        when(mockLocalDataSource.updatePlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.updatePlaylist(any)).thenAnswer((_) async => Left(ServerFailure('Remote failed')));

        // Act
        final result = await repository.updatePlaylist(testPlaylist);

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Verify rollback: updatePlaylist called twice (optimistic + rollback)
        verify(mockLocalDataSource.updatePlaylist(any)).called(2);
      });
    });

    group('deletePlaylist', () {
      test('should delete locally first then succeed on remote', () async {
        // Arrange
        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.deletePlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.deletePlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.deletePlaylist(testPlaylistId);

        // Assert
        expect(result.isRight(), true);
        verify(mockLocalDataSource.deletePlaylist(testPlaylistId.value)).called(1);
        verify(mockRemoteDataSource.deletePlaylist(testPlaylistId.value)).called(1);
      });

      test('should rollback by re-inserting snapshot when remote fails', () async {
        // Arrange
        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.deletePlaylist(any)).thenAnswer((_) async => const Right(unit));
        when(mockRemoteDataSource.deletePlaylist(any)).thenAnswer((_) async => Left(ServerFailure('Remote failed')));
        when(mockLocalDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.deletePlaylist(testPlaylistId);

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // Verify rollback: re-inserted the snapshot
        verify(mockLocalDataSource.addPlaylist(testDto)).called(1);
      });
    });

    group('getAllPlaylists', () {
      test('should return local data immediately', () async {
        // Arrange
        when(mockLocalDataSource.getAllPlaylists()).thenAnswer((_) async => Right([testDto]));
        when(mockRemoteDataSource.getAllPlaylists(any)).thenAnswer((_) async => const Right([]));

        // Act
        final result = await repository.getAllPlaylists('user-123');

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (playlists) {
            expect(playlists.length, 1);
            expect(playlists.first.name, 'Test Playlist');
          },
        );
      });

      test('should trigger background remote revalidation', () async {
        // Arrange
        when(mockLocalDataSource.getAllPlaylists()).thenAnswer((_) async => Right([testDto]));
        when(mockRemoteDataSource.getAllPlaylists('user-123')).thenAnswer((_) async => Right([testDto]));
        when(mockLocalDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        await repository.getAllPlaylists('user-123');

        // Wait for fire-and-forget to complete
        await Future.delayed(const Duration(milliseconds: 100));

        // Assert: remote was called for revalidation
        verify(mockRemoteDataSource.getAllPlaylists('user-123')).called(1);
      });

      test('should return failure when local throws', () async {
        // Arrange
        when(mockLocalDataSource.getAllPlaylists()).thenThrow(Exception('Database error'));

        // Act
        final result = await repository.getAllPlaylists('user-123');

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<DatabaseFailure>()),
          (_) => fail('Should have returned failure'),
        );
      });
    });

    group('getPlaylistById', () {
      test('should return local data immediately', () async {
        // Arrange
        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(testDto));
        when(mockRemoteDataSource.getPlaylistById(any)).thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.addPlaylist(any)).thenAnswer((_) async => const Right(unit));

        // Act
        final result = await repository.getPlaylistById(testPlaylistId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (playlist) {
            expect(playlist, isNotNull);
            expect(playlist!.name, 'Test Playlist');
          },
        );
      });

      test('should return null when not found locally', () async {
        // Arrange
        when(mockLocalDataSource.getPlaylistById(any)).thenAnswer((_) async => const Right(null));
        when(mockRemoteDataSource.getPlaylistById(any)).thenAnswer((_) async => const Right(null));

        // Act
        final result = await repository.getPlaylistById(testPlaylistId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (playlist) => expect(playlist, isNull),
        );
      });
    });
  });
}
