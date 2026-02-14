import 'package:dartz/dartz.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/waveform/domain/entities/audio_waveform.dart';

abstract class WaveformRepository {
  /// Fetch waveform: local cache first, remote fallback
  Future<Either<Failure, AudioWaveform>> getWaveformByVersionId(
    AudioTrackId trackId,
    TrackVersionId versionId,
  );

  /// Delete waveform: remote first, then local cache
  Future<Either<Failure, Unit>> deleteWaveformsForVersion(
    AudioTrackId trackId,
    TrackVersionId versionId,
  );

  Stream<AudioWaveform> watchWaveformChanges(TrackVersionId versionId);

  Future<Either<Failure, Unit>> clearAllWaveforms();

  /// Store waveform using online-first approach: upload to Firebase first,
  /// then cache locally. Path: waveforms/{trackId}/{versionId}.json
  Future<Either<Failure, Unit>> storeCanonicalWaveformOnline({
    required AudioTrackId trackId,
    required AudioWaveform waveform,
  });
}
