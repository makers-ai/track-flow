import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/audio/domain/audio_file_repository.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/infrastructure/domain/directory_service.dart';
import 'package:trackflow/core/utils/app_logger.dart';
import 'package:trackflow/features/audio_cache/domain/repositories/audio_storage_repository.dart';
import 'package:trackflow/features/audio_comment/data/datasources/audio_comment_local_datasource.dart';
import 'package:trackflow/features/audio_comment/data/datasources/audio_comment_remote_datasource.dart';
import 'package:trackflow/features/audio_comment/data/models/audio_comment_dto.dart';
import 'package:trackflow/features/audio_comment/domain/entities/audio_comment.dart';
import 'package:trackflow/features/audio_comment/domain/repositories/audio_comment_repository.dart';
import 'package:trackflow/features/track_version/domain/repositories/track_version_repository.dart';

@LazySingleton(as: AudioCommentRepository)
class AudioCommentRepositoryImpl implements AudioCommentRepository {
  AudioCommentRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
    this._audioFileRepository,
    this._audioStorageRepository,
    this._trackVersionRepository,
  );

  final AudioCommentLocalDataSource _localDataSource;
  final AudioCommentRemoteDataSource _remoteDataSource;
  final AudioFileRepository _audioFileRepository;
  final AudioStorageRepository _audioStorageRepository;
  final TrackVersionRepository _trackVersionRepository;

  // ============================================================
  // WRITE METHODS (Online-First Optimistic + Rollback)
  // ============================================================

  @override
  Future<Either<Failure, Unit>> addComment(AudioComment comment) async {
    final dto = AudioCommentDTO.fromDomain(comment);

    // 1. Optimistic: cache locally for immediate UI feedback
    await _localDataSource.cacheComment(dto);

    // 2. Handle audio file: local cache + Firebase Storage upload
    String? audioStorageUrl;
    String? cachedAudioPath;

    if (comment.commentType != CommentType.text && comment.localAudioPath != null) {
      // Store audio in permanent local cache
      final trackId = AudioTrackId.fromUniqueString(comment.projectId.value);
      final versionId = TrackVersionId.fromUniqueString(comment.id.value);

      final audioFile = File(comment.localAudioPath!);
      final cacheResult = await _audioStorageRepository.storeAudio(
        trackId,
        versionId,
        audioFile,
        directoryType: DirectoryType.audioComments,
      );

      cachedAudioPath = cacheResult.fold(
        (failure) {
          AppLogger.error(
            'Failed to cache audio recording: ${failure.message}',
            tag: 'AudioCommentRepositoryImpl',
          );
          return null;
        },
        (cachedAudio) => cachedAudio.filePath,
      );

      // Upload to Firebase Storage
      if (cachedAudioPath != null) {
        final storagePath = 'audio_comments/${trackId.value}/${versionId.value}/${comment.id.value}.m4a';

        final uploadResult = await _audioFileRepository.uploadAudioFile(
          audioFile: File(cachedAudioPath),
          storagePath: storagePath,
          metadata: {
            'trackId': trackId.value,
            'versionId': versionId.value,
            'commentId': comment.id.value,
            'type': 'audio_comment',
          },
        );

        final uploadedUrl = uploadResult.fold(
          (failure) => null,
          (url) => url,
        );

        if (uploadedUrl == null) {
          // Upload failed — rollback local cache
          await _localDataSource.deleteCachedComment(comment.id.value);
          return Left(ServerFailure('Failed to upload audio file'));
        }

        audioStorageUrl = uploadedUrl;
      }
    }

    // 3. Build final DTO with audio URLs
    final finalDto = dto.copyWith(
      audioStorageUrl: audioStorageUrl,
      localAudioPath: cachedAudioPath,
    );

    // 4. Persist to remote (source of truth)
    final remoteResult = await _remoteDataSource.addComment(finalDto);

    return remoteResult.fold(
      (failure) {
        // 5. Rollback: remove from local cache
        _localDataSource.deleteCachedComment(comment.id.value);
        return Left(failure);
      },
      (_) {
        // 6. Success: update local cache with final DTO (contains audioStorageUrl + localAudioPath)
        _localDataSource.cacheComment(finalDto);
        return const Right(unit);
      },
    );
  }

  @override
  Future<Either<Failure, Unit>> deleteComment(AudioCommentId commentId) async {
    // 1. Snapshot for rollback
    final prevResult = await _localDataSource.getCommentById(commentId.value);
    final prevDto = prevResult.fold((_) => null, (dto) => dto);

    if (prevDto == null) {
      return Left(DatabaseFailure('Comment not found in local cache'));
    }

    // 2. Optimistic: delete locally
    await _localDataSource.deleteCachedComment(commentId.value);

    // 3. Persist to remote (soft delete)
    final remoteResult = await _remoteDataSource.deleteComment(
      commentId.value,
    );

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: re-insert previous DTO
        _localDataSource.cacheComment(prevDto);
        return Left(failure);
      },
      (_) {
        // 5. Fire-and-forget: clean up audio file from Storage
        if (prevDto.audioStorageUrl != null && prevDto.audioStorageUrl!.isNotEmpty) {
          unawaited(
            _deleteAudioFromStorage(prevDto.audioStorageUrl!),
          );
        }
        return const Right(unit);
      },
    );
  }

  @override
  Future<Either<Failure, Unit>> deleteCommentsByVersion(TrackVersionId versionId) async {
    // 1. Snapshot for rollback
    final snapshotResult = await _localDataSource.getCachedCommentsByVersion(versionId.value);

    final snapshotDtos = snapshotResult.fold((_) => <AudioCommentDTO>[], (l) => l);

    // 2. Optimistic: delete all locally
    await _localDataSource.deleteByVersion(versionId.value);

    // 3. Persist to remote (batch soft delete)
    final remoteResult = await _remoteDataSource.deleteByVersionId(versionId.value);

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: re-insert all saved DTOs
        for (final dto in snapshotDtos) {
          _localDataSource.cacheComment(dto);
        }
        return Left(failure);
      },
      (_) {
        // 5. Fire-and-forget: clean up audio files from Storage
        for (final dto in snapshotDtos) {
          if (dto.audioStorageUrl != null && dto.audioStorageUrl!.isNotEmpty) {
            unawaited(_deleteAudioFromStorage(dto.audioStorageUrl!));
          }
        }
        return const Right(unit);
      },
    );
  }

  @override
  Future<Either<Failure, Unit>> deleteByTrackId(AudioTrackId trackId) async {
    // 1. Get all versions for this track
    final versionsEither = await _trackVersionRepository.getVersionsByTrack(trackId);

    if (versionsEither.isLeft()) return versionsEither.map((_) => unit);

    final versions = versionsEither.getOrElse(() => []);

    if (versions.isEmpty) return const Right(unit);

    // 2. Snapshot ALL versions' comments for batch rollback
    final allSnapshots = <String, List<AudioCommentDTO>>{};

    for (final v in versions) {
      final snapshotResult = await _localDataSource.getCachedCommentsByVersion(
        v.id.value,
      );
      allSnapshots[v.id.value] = snapshotResult.fold(
        (_) => <AudioCommentDTO>[],
        (l) => l,
      );
    }

    // 3. Optimistic: delete all locally
    for (final v in versions) {
      await _localDataSource.deleteByVersion(v.id.value);
    }

    // 4. Persist to remote — fail fast on first error
    for (final v in versions) {
      final remoteResult = await _remoteDataSource.deleteByVersionId(
        v.id.value,
      );

      if (remoteResult.isLeft()) {
        // 5. Rollback ALL versions (restore all snapshots)
        for (final entry in allSnapshots.entries) {
          for (final dto in entry.value) {
            await _localDataSource.cacheComment(dto);
          }
        }
        return remoteResult;
      }
    }

    // 6. Fire-and-forget: clean up audio files from Storage
    for (final entry in allSnapshots.entries) {
      for (final dto in entry.value) {
        if (dto.audioStorageUrl != null && dto.audioStorageUrl!.isNotEmpty) {
          unawaited(_deleteAudioFromStorage(dto.audioStorageUrl!));
        }
      }
    }

    return const Right(unit);
  }

  @override
  Future<Either<Failure, Unit>> deleteAllComments() async {
    try {
      await _localDataSource.deleteAllComments();
      return const Right(unit);
    } catch (e) {
      return Left(DatabaseFailure('Failed to delete all comments: $e'));
    }
  }

  // ============================================================
  // READ METHODS (Local streams + Background Revalidation)
  // ============================================================

  @override
  Future<Either<Failure, AudioComment>> getCommentById(
    AudioCommentId commentId,
  ) async {
    try {
      final result = await _localDataSource.getCommentById(commentId.value);

      final localComment = result.fold(
        (failure) => null,
        (dto) => dto?.toDomain(),
      );

      if (localComment != null) {
        return Right(localComment);
      }

      return Left(DatabaseFailure('Audio comment not found in local cache'));
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to access local cache: ${e.toString()}'),
      );
    }
  }

  @override
  Stream<Either<Failure, List<AudioComment>>> watchCommentsByTrack(
    AudioTrackId trackId,
  ) {
    // Deprecated in favor of version-scoped watcher. Return empty stream.
    return Stream.value(const Right(<AudioComment>[]));
  }

  @override
  Stream<Either<Failure, List<AudioComment>>> watchCommentsByVersion(
    TrackVersionId versionId,
  ) {
    try {
      // Trigger background revalidation (fire-and-forget)
      unawaited(_revalidateCommentsByVersion(versionId.value));

      return _localDataSource.watchCommentsByVersion(versionId.value).map((
        localResult,
      ) {
        return localResult.fold(
          (failure) => Left(failure),
          (dtos) => Right(dtos.map((dto) => dto.toDomain()).toList()),
        );
      });
    } catch (e) {
      return Stream.value(
        Left(
          DatabaseFailure(
            'Failed to watch audio comments by version: ${e.toString()}',
          ),
        ),
      );
    }
  }

  @override
  Stream<Either<Failure, List<AudioComment>>> watchRecentComments({
    required UserId userId,
    required int limit,
  }) {
    try {
      return _localDataSource
          .watchRecentComments(userId: userId.value, limit: limit)
          .map<Either<Failure, List<AudioComment>>>((dtos) {
            return Right<Failure, List<AudioComment>>(
              dtos.map((dto) => dto.toDomain()).toList(),
            );
          })
          .handleError((error) {
            return Left<Failure, List<AudioComment>>(
              DatabaseFailure('Failed to watch recent comments: $error'),
            );
          });
    } catch (e) {
      return Stream.value(
        Left<Failure, List<AudioComment>>(
          DatabaseFailure('Failed to watch recent comments: $e'),
        ),
      );
    }
  }

  // ============================================================
  // Background Revalidation
  // ============================================================

  Future<void> _deleteAudioFromStorage(String storageUrl) async {
    try {
      await _audioFileRepository.deleteAudioFile(storageUrl: storageUrl);
    } catch (_) {
      // Audio file cleanup is best-effort; orphaned files can be
      // handled by storage lifecycle rules.
    }
  }

  Future<void> _revalidateCommentsByVersion(String versionId) async {
    try {
      final remoteComments = await _remoteDataSource.getCommentsByVersionId(
        versionId,
      );
      await _localDataSource.replaceCommentsForVersion(
        versionId,
        remoteComments,
      );
    } catch (e) {
      AppLogger.warning(
        'Background comment revalidation failed for version $versionId: $e',
        tag: 'AudioCommentRepositoryImpl',
      );
    }
  }
}
