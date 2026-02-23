import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/app_flow/data/session_storage.dart';
import 'package:trackflow/features/audio_track/domain/services/project_track_service.dart';
import 'package:trackflow/features/projects/domain/repositories/projects_repository.dart';
import 'package:trackflow/features/track_version/domain/usecases/add_track_version_usecase.dart';
import 'package:trackflow/features/audio_track/domain/repositories/audio_track_repository.dart';
import 'package:trackflow/features/track_version/domain/repositories/track_version_repository.dart';

class UploadAudioTrackParams {
  final ProjectId projectId;
  final File file;
  final String name;

  UploadAudioTrackParams({
    required this.projectId,
    required this.file,
    required this.name,
  });
}

@lazySingleton
class UploadAudioTrackUseCase {
  final ProjectTrackService projectTrackService; // Permits
  final ProjectsRepository projectsRepository;
  final SessionStorage sessionStorage;
  final AddTrackVersionUseCase addTrackVersionUseCase;
  final AudioTrackRepository audioTrackRepository;
  final TrackVersionRepository trackVersionRepository; // For rollback

  UploadAudioTrackUseCase(
    this.projectTrackService,
    this.projectsRepository,
    this.sessionStorage,
    this.addTrackVersionUseCase,
    this.audioTrackRepository,
    this.trackVersionRepository,
  );

  Future<Either<Failure, Unit>> call(UploadAudioTrackParams params) async {
    try {
      // 1. Auth check
      final userId = await sessionStorage.getUserId();
      if (userId == null) {
        return Left(AuthenticationFailure('User not authenticated'));
      }

      // 2. Get project
      final projectResult = await projectsRepository.getProjectById(params.projectId);
      if (projectResult.isLeft()) {
        return projectResult.map((_) => unit);
      }
      final project = projectResult.getOrElse(() => throw Exception());

      // 3. Create track entity (validates permissions, NO persistence yet)
      final trackEntityResult = projectTrackService.createTrackEntity(
        project: project,
        requester: UserId.fromUniqueString(userId),
        name: params.name,
        activeVersionId: null, // Will be updated after version upload
      );

      if (trackEntityResult.isLeft()) {
        return trackEntityResult.map((_) => unit);
      }
      final track = trackEntityResult.getOrElse(() => throw Exception());

      // 4. Upload version to Firebase FIRST (online-first approach)
      // This uploads file to Storage + creates version in Firestore
      final versionResult = await addTrackVersionUseCase.call(
        AddTrackVersionParams(
          trackId: track.id,
          file: params.file,
          label: 'Initial version',
        ),
      );

      if (versionResult.isLeft()) {
        // No rollback needed - nothing was persisted yet
        return versionResult.map((_) => unit);
      }
      final version = versionResult.getOrElse(() => throw Exception());

      // 5. Create track metadata in Firestore (after version upload succeeded)
      // Use copyWith to set the activeVersionId
      final trackWithVersion = track.copyWith(activeVersionId: version.id);
      final createTrackResult = await audioTrackRepository.createTrack(trackWithVersion);

      if (createTrackResult.isLeft()) {
        // Rollback: delete the uploaded version since track creation failed
        await trackVersionRepository.deleteVersion(version.id);
        return createTrackResult.map((_) => unit);
      }

      return Right(unit);
    } catch (e) {
      return Left(UnexpectedFailure('Upload failed: $e'));
    }
  }
}
