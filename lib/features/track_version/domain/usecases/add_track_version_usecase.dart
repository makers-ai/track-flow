import 'dart:io';
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/app_flow/data/session_storage.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/infrastructure/domain/directory_service.dart';
import 'package:trackflow/features/track_version/domain/entities/track_version.dart';
import 'package:trackflow/features/track_version/domain/repositories/track_version_repository.dart';
import 'package:trackflow/features/audio_cache/domain/repositories/audio_storage_repository.dart';
import 'package:trackflow/features/audio_track/domain/services/audio_metadata_service.dart';
import 'package:trackflow/features/waveform/domain/usecases/generate_and_store_waveform.dart';

class AddTrackVersionParams {
  final AudioTrackId trackId;
  final File file;
  final String? label;
  final Duration? duration; // Add duration parameter

  AddTrackVersionParams({
    required this.trackId,
    required this.file,
    this.label,
    this.duration,
  });
}

@lazySingleton
class AddTrackVersionUseCase {
  final SessionStorage sessionStorage;
  final TrackVersionRepository trackVersionRepository;
  final AudioMetadataService audioMetadataService;
  final AudioStorageRepository audioStorageRepository;
  final GenerateAndStoreWaveform generateAndStoreWaveform;

  AddTrackVersionUseCase(
    this.sessionStorage,
    this.trackVersionRepository,
    this.audioMetadataService,
    this.audioStorageRepository,
    this.generateAndStoreWaveform,
  );

  Future<Either<Failure, TrackVersion>> call(
    AddTrackVersionParams params,
  ) async {
    try {
      final userId = await sessionStorage.getUserId();
      if (userId == null) {
        return Left(AuthenticationFailure('User not authenticated'));
      }

      // 1) Ensure file exists
      if (!await params.file.exists()) {
        return Left(ValidationFailure('Selected audio file does not exist'));
      }

      // 2) Extract duration if not provided
      final Duration duration;
      if (params.duration != null) {
        duration = params.duration!;
      } else {
        final durationEither = await audioMetadataService.extractDuration(
          params.file,
        );
        if (durationEither.isLeft()) {
          return durationEither.map((_) => throw Exception());
        }
        duration = durationEither.getOrElse(() => Duration.zero);
      }

      // 3) Upload version to Firebase directly (online-first approach)
      final addEither = await trackVersionRepository.addVersionOnline(
        trackId: params.trackId,
        file: params.file,
        label: params.label,
        duration: duration,
        createdBy: userId,
      );

      if (addEither.isLeft()) {
        return addEither;
      }

      final version = addEither.getOrElse(() => throw Exception());

      // 4) Cache audio locally for offline playback (best-effort, don't fail if this fails)
      final cacheEither = await audioStorageRepository.storeAudio(
        params.trackId,
        version.id,
        params.file,
        directoryType: DirectoryType.audioTracks,
      );

      // Best-effort: log but don't fail the operation if cache fails
      // The file is already uploaded to Firebase, so we can stream it later
      File? cachedFile;
      cacheEither.fold(
        (failure) {
          // Log warning but don't fail - file is already in Firebase
        },
        (cached) {
          cachedFile = File(cached.filePath);
        },
      );

      // 5) Fire-and-forget canonical waveform generation using cached file or original
      final waveformSourcePath = cachedFile?.path ?? params.file.path;
      () async {
        try {
          await generateAndStoreWaveform(
            GenerateAndStoreWaveformParams(
              trackId: params.trackId,
              versionId: version.id,
              audioFilePath: waveformSourcePath,
              targetSampleCount: null,
            ),
          );
        } catch (_) {
          // swallow - waveform is best-effort
        }
      }();

      return Right(version);
    } catch (e) {
      return Left(UnexpectedFailure('Failed to add track version: $e'));
    }
  }
}
