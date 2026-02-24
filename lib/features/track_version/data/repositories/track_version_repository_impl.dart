import 'dart:io';
import 'dart:math';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';

import 'package:trackflow/features/track_version/data/datasources/track_version_local_data_source.dart';
import 'package:trackflow/features/track_version/data/datasources/track_version_remote_datasource.dart';
import 'package:trackflow/features/track_version/data/models/track_version_dto.dart';
import 'package:trackflow/features/track_version/domain/entities/track_version.dart';
import 'package:trackflow/features/track_version/domain/repositories/track_version_repository.dart';

@LazySingleton(as: TrackVersionRepository)
class TrackVersionRepositoryImpl implements TrackVersionRepository {
  final TrackVersionLocalDataSource _local;
  final TrackVersionRemoteDataSource _remote;

  TrackVersionRepositoryImpl(this._local, this._remote);

  // ============================================================
  // WRITE METHODS (Online-First Optimistic + Rollback)
  // ============================================================

  @override
  Future<Either<Failure, TrackVersion>> addVersionOnline({
    required AudioTrackId trackId,
    required File file,
    String? label,
    required Duration duration,
    required String createdBy,
  }) async {
    try {
      // 1. Calculate next version number from local data
      final existingVersionsResult = await _local.getVersionsByTrack(trackId);
      final nextVersionNumber = existingVersionsResult.fold(
        (failure) => 1,
        (versions) => versions.isEmpty ? 1 : versions.map((v) => v.versionNumber).reduce(max) + 1,
      );

      // 2. Create DTO for remote upload
      final versionId = TrackVersionId();
      final dto = TrackVersionDTO(
        id: versionId.value,
        trackId: trackId.value,
        versionNumber: nextVersionNumber,
        label: label,
        fileLocalPath: file.path,
        fileRemoteUrl: null,
        durationMs: duration.inMilliseconds,
        status: 'processing',
        createdAt: DateTime.now(),
        createdBy: createdBy,
        isDeleted: false,
      );

      // 3. Upload to Firebase (Storage + Firestore) - ONLINE FIRST
      final remoteResult = await _remote.createTrackVersion(dto, file);

      return await remoteResult.fold(
        (failure) => Left(failure),
        (uploadedDto) async {
          // 4. Cache locally only after remote success
          await _local.cacheVersion(uploadedDto);

          // 5. Return domain entity
          return Right(uploadedDto.toDomain());
        },
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to upload version online: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> setActiveVersion({
    required AudioTrackId trackId,
    required TrackVersionId versionId,
  }) async {
    try {
      // 1. Snapshot for rollback
      final snapshotResult = await _local.getVersionById(versionId.value);
      final prevDto = snapshotResult.fold((_) => null, (dto) => dto);

      if (prevDto == null) {
        return Left(DatabaseFailure('Version not found: ${versionId.value}'));
      }

      // 2. Optimistic: build updated DTO with status 'active' and cache locally
      final updatedDto = TrackVersionDTO(
        id: prevDto.id,
        trackId: prevDto.trackId,
        versionNumber: prevDto.versionNumber,
        label: prevDto.label,
        fileLocalPath: prevDto.fileLocalPath,
        fileRemoteUrl: prevDto.fileRemoteUrl,
        durationMs: prevDto.durationMs,
        waveformCachePath: prevDto.waveformCachePath,
        status: 'active',
        createdAt: prevDto.createdAt,
        createdBy: prevDto.createdBy,
        isDeleted: prevDto.isDeleted,
        version: (prevDto.version ?? 1) + 1,
        lastModified: DateTime.now(),
      );
      await _local.cacheVersion(updatedDto);

      // 3. Remote: update metadata in Firestore
      final remoteResult = await _remote.updateTrackVersionMetadata(updatedDto);

      return remoteResult.fold(
        (failure) {
          // 4. Rollback: restore original DTO in local cache
          _local.cacheVersion(prevDto);
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to set active version: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteVersion(TrackVersionId versionId) async {
    try {
      // 1. Snapshot for rollback
      final snapshotResult = await _local.getVersionById(versionId.value);
      final prevDto = snapshotResult.fold((_) => null, (dto) => dto);

      if (prevDto == null) {
        return Left(DatabaseFailure('Version not found: ${versionId.value}'));
      }

      // 2. Optimistic: delete from local cache
      await _local.deleteVersion(versionId);

      // 3. Remote: soft delete in Firestore
      final remoteResult = await _remote.deleteTrackVersion(versionId.value);

      return remoteResult.fold(
        (failure) {
          // 4. Rollback: re-cache the snapshot DTO
          _local.cacheVersion(prevDto);
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to delete version: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> renameVersion({
    required TrackVersionId versionId,
    required String? newLabel,
  }) async {
    try {
      // 1. Snapshot for rollback
      final snapshotResult = await _local.getVersionById(versionId.value);
      final prevDto = snapshotResult.fold((_) => null, (dto) => dto);

      if (prevDto == null) {
        return Left(DatabaseFailure('Version not found: ${versionId.value}'));
      }

      // 2. Optimistic: rename locally
      await _local.renameVersion(versionId: versionId, newLabel: newLabel);

      // 3. Build updated DTO for remote
      final updatedDto = TrackVersionDTO(
        id: prevDto.id,
        trackId: prevDto.trackId,
        versionNumber: prevDto.versionNumber,
        label: newLabel,
        fileLocalPath: prevDto.fileLocalPath,
        fileRemoteUrl: prevDto.fileRemoteUrl,
        durationMs: prevDto.durationMs,
        waveformCachePath: prevDto.waveformCachePath,
        status: prevDto.status,
        createdAt: prevDto.createdAt,
        createdBy: prevDto.createdBy,
        isDeleted: prevDto.isDeleted,
        version: (prevDto.version ?? 1) + 1,
        lastModified: DateTime.now(),
      );

      // 4. Remote: update metadata in Firestore
      final remoteResult = await _remote.updateTrackVersionMetadata(updatedDto);

      return remoteResult.fold(
        (failure) {
          // 5. Rollback: restore original DTO (restores previous label)
          _local.cacheVersion(prevDto);
          return Left(failure);
        },
        (_) => const Right(unit),
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to rename version: $e'));
    }
  }

  // ============================================================
  // READ METHODS (Local streams, unchanged)
  // ============================================================

  @override
  Stream<Either<Failure, List<TrackVersion>>> watchVersionsByTrack(
    AudioTrackId trackId,
  ) {
    return _local
        .watchVersionsByTrack(trackId)
        .map(
          (either) => either.map(
            (dtos) =>
                dtos.map((d) => d.toDomain()).toList()..sort((a, b) => b.versionNumber.compareTo(a.versionNumber)),
          ),
        );
  }

  @override
  Future<Either<Failure, List<TrackVersion>>> getVersionsByTrack(
    AudioTrackId trackId,
  ) async {
    final dtoEither = await _local.getVersionsByTrack(trackId);
    return dtoEither.map(
      (dtos) => dtos.map((dto) => dto.toDomain()).toList()..sort((a, b) => b.versionNumber.compareTo(a.versionNumber)),
    );
  }

  @override
  Future<Either<Failure, TrackVersion>> getActiveVersion(
    AudioTrackId trackId,
  ) async {
    final dtoEither = await _local.getActiveVersion(trackId);
    return dtoEither.map((dto) => dto.toDomain());
  }

  @override
  Future<Either<Failure, TrackVersion>> getById(TrackVersionId id) async {
    final dtoEither = await _local.getById(id);
    return dtoEither.map((dto) => dto.toDomain());
  }

  @override
  Future<Either<Failure, Unit>> clearCache() async {
    try {
      return await _local.clearCache();
    } catch (e) {
      return Left(DatabaseFailure('Failed to clear track versions cache: $e'));
    }
  }
}
