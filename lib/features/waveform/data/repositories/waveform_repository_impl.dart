import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/waveform/domain/entities/audio_waveform.dart';
import 'package:trackflow/features/waveform/domain/repositories/waveform_repository.dart';
import 'package:trackflow/features/waveform/data/datasources/waveform_local_datasource.dart';
import 'package:trackflow/features/waveform/data/datasources/waveform_remote_datasource.dart';

@Injectable(as: WaveformRepository)
class WaveformRepositoryImpl implements WaveformRepository {
  final WaveformLocalDataSource _localDataSource;
  final WaveformRemoteDataSource _remoteDataSource;

  WaveformRepositoryImpl({
    required WaveformLocalDataSource localDataSource,
    required WaveformRemoteDataSource remoteDataSource,
  }) : _localDataSource = localDataSource,
       _remoteDataSource = remoteDataSource;

  @override
  Future<Either<Failure, AudioWaveform>> getWaveformByVersionId(
    AudioTrackId trackId,
    TrackVersionId versionId,
  ) async {
    try {
      // 1. Try local cache first
      final localWaveform = await _localDataSource.getWaveformByVersionId(versionId);
      if (localWaveform != null) {
        return Right(localWaveform);
      }

      // 2. Fallback to remote
      final remoteWaveform = await _remoteDataSource.fetchCanonicalForVersion(
        trackId: trackId.value,
        versionId: versionId,
      );

      if (remoteWaveform == null) {
        return Left(
          ServerFailure('Waveform not found for version: ${versionId.value}'),
        );
      }

      // 3. Cache locally after remote success
      await _localDataSource.saveWaveform(remoteWaveform);

      return Right(remoteWaveform);
    } catch (e) {
      return Left(ServerFailure('Failed to get waveform: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteWaveformsForVersion(
    AudioTrackId trackId,
    TrackVersionId versionId,
  ) async {
    try {
      // 1. Delete from remote FIRST
      await _remoteDataSource.deleteWaveformsForVersion(
        trackId: trackId.value,
        versionId: versionId,
      );

      // 2. Delete from local cache after remote success
      await _localDataSource.deleteWaveformsForVersion(versionId);

      return const Right(unit);
    } catch (e) {
      return Left(ServerFailure('Failed to delete waveform: $e'));
    }
  }

  @override
  Stream<AudioWaveform> watchWaveformChanges(TrackVersionId versionId) {
    return _localDataSource.watchWaveformChanges(versionId);
  }

  @override
  Future<Either<Failure, Unit>> clearAllWaveforms() async {
    try {
      await _localDataSource.clearAll();
      return const Right(unit);
    } catch (e) {
      return Left(ServerFailure('Failed to clear waveforms: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> storeCanonicalWaveformOnline({
    required AudioTrackId trackId,
    required AudioWaveform waveform,
  }) async {
    try {
      // 1. Upload to Firebase Storage FIRST (remote-first)
      await _remoteDataSource.uploadCanonical(
        trackId: trackId.value,
        waveform: waveform,
      );

      // 2. Cache locally only after remote success
      await _localDataSource.saveWaveform(waveform);

      return const Right(unit);
    } catch (e) {
      return Left(ServerFailure('Failed to store canonical waveform online: $e'));
    }
  }
}
