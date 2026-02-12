import 'package:dartz/dartz.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/audio_track/domain/entities/audio_track.dart';

abstract class AudioTrackRepository {
  Future<Either<Failure, AudioTrack>> getTrackById(AudioTrackId id);

  /// Watch a single track by id. Emits updates when the track changes in local cache.
  Stream<Either<Failure, AudioTrack>> watchTrackById(AudioTrackId id);

  Stream<Either<Failure, List<AudioTrack>>> watchTracksByProject(
    ProjectId projectId,
  );

  /// Watch all tracks that the user has access to (across all accessible projects).
  /// Returns tracks from projects where the user is owner or collaborator.
  Stream<Either<Failure, List<AudioTrack>>> watchAllAccessibleTracks(
    UserId userId,
  );

  /// Create a new track with metadata only (no file upload)
  Future<Either<Failure, AudioTrack>> createTrack(AudioTrack track);

  Future<Either<Failure, Unit>> deleteTrack(
    AudioTrackId trackId,
    ProjectId projectId,
  );

  Future<Either<Failure, Unit>> editTrackName({
    required AudioTrackId trackId,
    required ProjectId projectId,
    required String newName,
  });

  Future<Either<Failure, Unit>> setActiveVersion({
    required AudioTrackId trackId,
    required TrackVersionId versionId,
  });

  /// Update an existing track
  Future<Either<Failure, Unit>> updateTrack(AudioTrack track);

  /// Delete all tracks from local cache
  Future<Either<Failure, Unit>> deleteAllTracks();

  /// Creates a new track directly in Firebase (online-first approach).
  /// Saves to Firestore first, then caches locally.
  Future<Either<Failure, AudioTrack>> createTrackOnline(AudioTrack track);

  /// Updates active version directly in Firebase (online-first approach).
  /// Updates Firestore first, then updates local cache.
  Future<Either<Failure, Unit>> setActiveVersionOnline({
    required AudioTrackId trackId,
    required TrackVersionId versionId,
  });

  /// Deletes a track using optimistic online-first approach.
  /// Removes from local cache immediately for instant UX, then hard deletes
  /// from Firestore. Rolls back local cache if remote deletion fails.
  Future<Either<Failure, Unit>> deleteTrackOnline(AudioTrackId trackId);
}
