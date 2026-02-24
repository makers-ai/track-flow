import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_local_datasource.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_remote_datasource.dart';
import 'package:trackflow/features/audio_track/data/models/audio_track_dto.dart';
import 'package:trackflow/features/audio_track/domain/entities/audio_track.dart';
import 'package:trackflow/features/audio_track/domain/repositories/audio_track_repository.dart';

@LazySingleton(as: AudioTrackRepository)
class AudioTrackRepositoryImpl implements AudioTrackRepository {
  final AudioTrackLocalDataSource _localDataSource;
  final AudioTrackRemoteDataSource _remoteDataSource;

  AudioTrackRepositoryImpl(this._localDataSource, this._remoteDataSource);

  // ---------------------------------------------------------------------------
  // createTrack — Remote-First (no optimistic)
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, AudioTrack>> createTrack(AudioTrack track) async {
    final dto = AudioTrackDTO.fromDomain(track, extension: 'mp3');

    // 1. Call remote FIRST (user sees upload progress via BLoC loading state)
    final remoteResult = await _remoteDataSource.createAudioTrack(dto);

    return remoteResult.fold(
      (failure) => Left(failure),
      (remoteDto) {
        // 2. Success: cache locally with server response
        _localDataSource.cacheTrack(remoteDto);
        return Right(remoteDto.toDomain());
      },
    );
  }

  // ---------------------------------------------------------------------------
  // deleteTrack — Optimistic + Rollback
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, Unit>> deleteTrack(AudioTrackId trackId) async {
    // 1. Snapshot for rollback
    final prevResult = await _localDataSource.getTrackById(trackId.value);
    final prevDto = prevResult.fold((_) => null, (dto) => dto);

    if (prevDto == null) {
      return Left(DatabaseFailure('Track not found: ${trackId.value}'));
    }

    // 2. Optimistic: delete locally
    await _localDataSource.deleteTrack(trackId.value);

    // 3. Persist to remote (soft delete)
    final remoteResult = await _remoteDataSource.deleteAudioTrack(trackId.value);

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: restore in local cache
        _localDataSource.cacheTrack(prevDto);
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  }

  // ---------------------------------------------------------------------------
  // editTrackName — Optimistic + Rollback (remote throws, not Either)
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, Unit>> editTrackName({
    required AudioTrackId trackId,
    required ProjectId projectId,
    required String newName,
  }) async {
    // 1. Snapshot previous name
    final prevResult = await _localDataSource.getTrackById(trackId.value);
    final prevName = prevResult.fold((_) => null, (dto) => dto?.name);

    // 2. Optimistic: update name locally
    await _localDataSource.updateTrackName(trackId.value, newName);

    // 3. Remote: editTrackName (throws on error, not Either)
    try {
      await _remoteDataSource.editTrackName(
        trackId.value,
        projectId.value,
        newName,
      );
      return const Right(unit);
    } catch (e) {
      // 4. Rollback: restore previous name
      if (prevName != null) {
        await _localDataSource.updateTrackName(trackId.value, prevName);
      }
      return Left(ServerFailure('Failed to edit track name: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // setActiveVersion — Optimistic + Rollback
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, Unit>> setActiveVersion({
    required AudioTrackId trackId,
    required TrackVersionId versionId,
  }) async {
    // 1. Snapshot previous active version
    final prevResult = await _localDataSource.getTrackById(trackId.value);
    final prevVersionId = prevResult.fold(
      (_) => null,
      (dto) => dto?.activeVersionId?.value,
    );

    // 2. Optimistic: update locally
    final localResult = await _localDataSource.setActiveVersion(
      trackId.value,
      versionId.value,
    );

    if (localResult.isLeft()) {
      return localResult;
    }

    // 3. Remote
    final remoteResult = await _remoteDataSource.updateActiveVersion(
      trackId.value,
      versionId.value,
    );

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: restore previous version
        if (prevVersionId != null) {
          _localDataSource.setActiveVersion(trackId.value, prevVersionId);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  }

  // ---------------------------------------------------------------------------
  // updateTrack — Optimistic + Rollback (cover art)
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, Unit>> updateTrack(AudioTrack track) async {
    final dto = AudioTrackDTO.fromDomain(track, extension: '');

    // 1. Snapshot for rollback
    final prevResult = await _localDataSource.getTrackById(track.id.value);
    final prevDto = prevResult.fold((_) => null, (dto) => dto);

    // 2. Optimistic: update locally (full DTO update)
    await _localDataSource.updateTrack(dto);

    // 3. Remote: update cover art only (partial update)
    final remoteResult = await _remoteDataSource.updateTrackCoverUrl(
      track.id.value,
      track.coverUrl,
      null, // coverLocalPath not synced to Firestore
    );

    return remoteResult.fold(
      (failure) {
        // 4. Rollback
        if (prevDto != null) {
          _localDataSource.cacheTrack(prevDto);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  }

  // ---------------------------------------------------------------------------
  // getTrackById — Local only
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, AudioTrack>> getTrackById(AudioTrackId id) async {
    try {
      final result = await _localDataSource.getTrackById(id.value);
      final localDto = result.fold((_) => null, (dto) => dto);

      if (localDto != null) {
        return Right(localDto.toDomain());
      }

      return Left(DatabaseFailure('Audio track not found in local cache'));
    } catch (e) {
      return Left(DatabaseFailure('Failed to access local cache: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // watchTracksByProject — Stream (sync coordinator handles population)
  // ---------------------------------------------------------------------------
  @override
  Stream<Either<Failure, List<AudioTrack>>> watchTracksByProject(
    ProjectId projectId,
  ) {
    return _localDataSource.watchTracksByProject(projectId.value).map((
      localResult,
    ) {
      return localResult.fold(
        (failure) => Left(failure),
        (dtos) => Right(dtos.map((dto) => dto.toDomain()).toList()),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // watchTrackById — Stream (no individual revalidation)
  // ---------------------------------------------------------------------------
  @override
  Stream<Either<Failure, AudioTrack>> watchTrackById(AudioTrackId id) {
    return _localDataSource.watchTrackById(id.value).map((eitherDto) {
      return eitherDto.fold(
        (failure) => Left(failure),
        (dto) => dto != null ? Right(dto.toDomain()) : Left(DatabaseFailure('Audio track not found in local cache')),
      );
    });
  }

  // ---------------------------------------------------------------------------
  // watchAllAccessibleTracks — Stream (no revalidation)
  // ---------------------------------------------------------------------------
  @override
  Stream<Either<Failure, List<AudioTrack>>> watchAllAccessibleTracks(
    UserId userId,
  ) {
    return _localDataSource
        .watchAllAccessibleTracks(userId.value)
        .map<Either<Failure, List<AudioTrack>>>((dtos) {
          return Right(dtos.map((dto) => dto.toDomain()).toList());
        })
        .handleError((error) {
          return Left<Failure, List<AudioTrack>>(
            DatabaseFailure('Failed to watch accessible tracks: $error'),
          );
        });
  }

  // ---------------------------------------------------------------------------
  // deleteAllTracks
  // ---------------------------------------------------------------------------
  @override
  Future<Either<Failure, Unit>> deleteAllTracks() async {
    try {
      await _localDataSource.deleteAllTracks();
      return const Right(unit);
    } catch (e) {
      return Left(DatabaseFailure('Failed to delete all tracks: $e'));
    }
  }

}
