import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:dartz/dartz.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/utils/app_logger.dart';

import '../../domain/entities/playlist.dart';
import '../../domain/repositories/playlist_repository.dart';
import '../datasources/playlist_local_data_source.dart';
import '../datasources/playlist_remote_data_source.dart';
import '../models/playlist_dto.dart';

@LazySingleton(as: PlaylistRepository)
class PlaylistRepositoryImpl implements PlaylistRepository {
  PlaylistRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
  );

  final PlaylistLocalDataSource _localDataSource;
  final PlaylistRemoteDataSource _remoteDataSource;

  @override
  Future<Either<Failure, Unit>> addPlaylist(Playlist playlist) async {
    try {
      final dto = PlaylistDto.fromDomain(playlist);

      // 1. Optimistic local write
      await _localDataSource.addPlaylist(dto);

      // 2. Remote call
      final remoteResult = await _remoteDataSource.addPlaylist(dto);

      return remoteResult.fold(
        (failure) async {
          // 3. Rollback: remove optimistic local write
          await _localDataSource.deletePlaylist(dto.id);
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to add playlist: $e'));
    }
  }

  @override
  Future<Either<Failure, List<Playlist>>> getAllPlaylists(String userId) async {
    try {
      // 1. Return local cache immediately
      final localResult = await _localDataSource.getAllPlaylists();

      // 2. Fire-and-forget remote revalidation
      _revalidatePlaylistsFromRemote(userId);

      return localResult.fold(
        (failure) => Left(failure),
        (dtos) => Right(dtos.map((dto) => dto.toDomain()).toList()),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to get playlists: $e'));
    }
  }

  @override
  Future<Either<Failure, Playlist?>> getPlaylistById(PlaylistId id) async {
    try {
      // 1. Return local cache first
      final localResult = await _localDataSource.getPlaylistById(id.value);

      // 2. Fire-and-forget remote revalidation
      _revalidatePlaylistByIdFromRemote(id.value);

      return localResult.fold(
        (failure) => Left(failure),
        (dto) => Right(dto?.toDomain()),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to get playlist: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> updatePlaylist(Playlist playlist) async {
    try {
      final dto = PlaylistDto.fromDomain(playlist);

      // 1. Snapshot for rollback
      final snapshotResult = await _localDataSource.getPlaylistById(dto.id);
      final snapshot = snapshotResult.fold((_) => null, (dto) => dto);

      // 2. Optimistic local write
      await _localDataSource.updatePlaylist(dto);

      // 3. Remote call
      final remoteResult = await _remoteDataSource.updatePlaylist(dto);

      return remoteResult.fold(
        (failure) async {
          // 4. Rollback to snapshot
          if (snapshot != null) {
            await _localDataSource.updatePlaylist(snapshot);
          }
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to update playlist: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deletePlaylist(PlaylistId id) async {
    try {
      // 1. Snapshot for rollback
      final snapshotResult = await _localDataSource.getPlaylistById(id.value);
      final snapshot = snapshotResult.fold((_) => null, (dto) => dto);

      // 2. Optimistic local delete
      await _localDataSource.deletePlaylist(id.value);

      // 3. Remote call
      final remoteResult = await _remoteDataSource.deletePlaylist(id.value);

      return remoteResult.fold(
        (failure) async {
          // 4. Rollback: re-insert deleted playlist
          if (snapshot != null) {
            await _localDataSource.addPlaylist(snapshot);
          }
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to delete playlist: $e'));
    }
  }

  void _revalidatePlaylistsFromRemote(String userId) {
    _remoteDataSource
        .getAllPlaylists(userId)
        .then((result) {
          result.fold(
            (failure) => AppLogger.warning(
              'Remote revalidation failed: ${failure.message}',
              tag: 'PlaylistRepositoryImpl',
            ),
            (remoteDtos) async {
              for (final dto in remoteDtos) {
                await _localDataSource.addPlaylist(dto);
              }
            },
          );
        })
        .catchError((e) {
          AppLogger.warning(
            'Remote revalidation error: $e',
            tag: 'PlaylistRepositoryImpl',
          );
        });
  }

  void _revalidatePlaylistByIdFromRemote(String id) {
    _remoteDataSource
        .getPlaylistById(id)
        .then((result) {
          result.fold(
            (failure) => AppLogger.warning(
              'Remote revalidation failed for playlist $id: ${failure.message}',
              tag: 'PlaylistRepositoryImpl',
            ),
            (remoteDto) async {
              if (remoteDto != null) {
                await _localDataSource.addPlaylist(remoteDto);
              }
            },
          );
        })
        .catchError((e) {
          AppLogger.warning(
            'Remote revalidation error for playlist $id: $e',
            tag: 'PlaylistRepositoryImpl',
          );
        });
  }
}
