import 'dart:async';
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/utils/app_logger.dart';
import 'package:trackflow/features/projects/data/datasources/project_local_data_source.dart';
import 'package:trackflow/features/projects/data/datasources/project_remote_data_source.dart';
import 'package:trackflow/features/projects/data/models/project_dto.dart';
import 'package:trackflow/features/projects/domain/entities/project.dart';
import 'package:trackflow/features/projects/domain/repositories/projects_repository.dart';
import 'package:trackflow/core/entities/unique_id.dart';

@LazySingleton(as: ProjectsRepository)
class ProjectsRepositoryImpl implements ProjectsRepository {
  ProjectsRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
  );

  final ProjectsLocalDataSource _localDataSource;
  final ProjectRemoteDataSource _remoteDataSource;

  @override
  Future<Either<Failure, Project>> createProject(Project project) async {
    final dto = ProjectDTO.fromDomain(project);

    // 1. Optimistic: cache locally for immediate UI feedback
    await _localDataSource.cacheProject(dto);

    // 2. Persist to remote (source of truth)
    final remoteResult = await _remoteDataSource.createProject(dto);

    return remoteResult.fold(
      (failure) {
        // 3. Rollback: remove optimistic cache on remote failure
        _localDataSource.removeCachedProject(project.id.value);
        return Left(failure);
      },
      (remoteDto) {
        // 4. Success: sync local with remote response if needed
        _localDataSource.cacheProject(remoteDto);
        return Right(project);
      },
    );
  }

  @override
  Future<Either<Failure, Unit>> updateProject(Project project) async {
    final dto = ProjectDTO.fromDomain(project);

    // 1. Snapshot previous state for rollback
    final prevResult = await _localDataSource.getCachedProject(project.id.value);

    final prevDto = prevResult.fold((_) => null, (dto) => dto);

    // 2. Optimistic: apply changes locally
    await _localDataSource.cacheProject(dto);

    // 3. Persist to remote (source of truth)
    final remoteResult = await _remoteDataSource.updateProject(dto);

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: restore previous state
        if (prevDto != null) {
          _localDataSource.cacheProject(prevDto);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  }

  @override
  Future<Either<Failure, Unit>> deleteProject(Project project) async {
    // 1. Snapshot for rollback
    final prevResult = await _localDataSource.getCachedProject(project.id.value);

    final prevDto = prevResult.fold((_) => null, (dto) => dto);

    // 2. Optimistic: soft delete locally (disappears from watches)
    await _localDataSource.removeCachedProject(project.id.value);

    // 3. Persist to remote (soft delete in Firestore)
    final remoteResult = await _remoteDataSource.deleteProject(project.id.value);

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: restore project in local cache
        if (prevDto != null) {
          _localDataSource.cacheProject(prevDto);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  }

  @override
  Future<Either<Failure, Project>> getProjectById(ProjectId projectId) async {
    // 1. Try local cache first
    final localResult = await _localDataSource.getCachedProject(projectId.value);

    final localDto = localResult.fold((_) => null, (dto) => dto);

    if (localDto != null && !localDto.isDeleted) {
      // 2. Return local immediately + trigger background revalidation
      unawaited(_revalidateProject(projectId.value));
      return Right(localDto.toDomain());
    }

    // 3. Not in cache → fetch from remote directly
    final remoteResult = await _remoteDataSource.getProjectById(
      projectId.value,
    );

    return remoteResult.fold(
      (failure) => Left(failure),
      (dto) {
        // 4. Cache for future reads
        _localDataSource.cacheProject(dto);
        return Right(dto.toDomain());
      },
    );
  }

  @override
  Stream<Either<Failure, List<Project>>> watchLocalProjects(UserId ownerId) {
    // Trigger background revalidation (fire-and-forget)
    unawaited(_revalidateProjects(ownerId.value));

    // Return local stream - auto-emits when cache is updated by revalidation
    return _localDataSource
        .watchAllProjects(ownerId.value)
        .map((either) {
          return either.map(
            (projects) => projects.map((project) => project.toDomain()).toList(),
          );
        })
        .handleError((error) {
          return left(DatabaseFailure('Local projects stream error: $error'));
        });
  }

  @override
  Stream<Either<Failure, Project?>> watchProjectById(ProjectId projectId) {
    // Trigger background revalidation (fire-and-forget)
    unawaited(_revalidateProject(projectId.value));

    return _localDataSource
        .watchProjectById(projectId.value)
        .map((either) => either.map((dto) => dto?.toDomain()))
        .handleError((error) {
          return left<Failure, Project?>(
            DatabaseFailure('Local project stream error: $error'),
          );
        });
  }

  @override
  Future<Either<Failure, Unit>> clearLocalCache() async {
    try {
      await _localDataSource.clearCache();
      return const Right(unit);
    } catch (e) {
      return Left(DatabaseFailure('Failed to clear projects cache: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Background revalidation (stale-while-revalidate)
  // ---------------------------------------------------------------------------

  /// Revalidates all projects for a user from remote.
  /// Updates local cache with fresh data. Isar watches auto-emit on changes.
  Future<void> _revalidateProjects(String userId) async {
    try {
      final remoteResult = await _remoteDataSource.getUserProjects(userId);

      await remoteResult.fold(
        (_) async {}, // Silently fail - local data still shown
        (remoteDtos) async {
          for (final dto in remoteDtos) {
            if (dto.isDeleted) {
              await _localDataSource.removeCachedProject(dto.id);
            } else {
              await _localDataSource.cacheProject(dto);
            }
          }
        },
      );
    } catch (e) {
      AppLogger.warning(
        'Background project revalidation failed: $e',
        tag: 'ProjectsRepositoryImpl',
      );
    }
  }

  /// Revalidates a single project from remote.
  Future<void> _revalidateProject(String projectId) async {
    try {
      final remoteResult = await _remoteDataSource.getProjectById(projectId);
      await remoteResult.fold(
        (_) async {}, // Silently fail
        (dto) async {
          if (dto.isDeleted) {
            await _localDataSource.removeCachedProject(dto.id);
          } else {
            await _localDataSource.cacheProject(dto);
          }
        },
      );
    } catch (e) {
      AppLogger.warning(
        'Background project revalidation failed: $e',
        tag: 'ProjectsRepositoryImpl',
      );
    }
  }
}
