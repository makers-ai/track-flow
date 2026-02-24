import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/utils/image_utils.dart';
import 'package:trackflow/features/user_profile/data/datasources/user_profile_local_datasource.dart';
import 'package:trackflow/features/user_profile/data/datasources/user_profile_remote_datasource.dart';
import 'package:trackflow/features/user_profile/data/models/user_profile_dto.dart';
import 'package:trackflow/features/user_profile/domain/entities/user_profile.dart';
import 'package:trackflow/features/user_profile/domain/repositories/user_profile_repository.dart';

@LazySingleton(as: UserProfileRepository)
class UserProfileRepositoryImpl implements UserProfileRepository {
  UserProfileRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
  );

  final UserProfileLocalDataSource _localDataSource;
  final UserProfileRemoteDataSource _remoteDataSource;

  @override
  Future<Either<Failure, UserProfile?>> getUserProfile(UserId userId) async {
    try {
      final localDto = await _localDataSource.watchUserProfile(userId.value).first;

      if (localDto != null) {
        return Right(localDto.toDomain());
      }

      // Not in cache - fetch from remote
      final remoteResult = await _remoteDataSource.getProfileById(userId.value);
      return remoteResult.fold(
        (failure) => Left(failure),
        (remoteDto) async {
          await _localDataSource.cacheUserProfile(remoteDto);
          return Right(remoteDto.toDomain());
        },
      );
    } catch (e) {
      return Left(ServerFailure('Failed to get user profile: $e'));
    }
  }

  @override
  Future<Either<Failure, Unit>> updateUserProfile(UserProfile profile) async {
    try {
      var dto = UserProfileDTO.fromDomain(profile);

      // Normalize avatar if local path
      final isLocalAvatar = dto.avatarUrl.isNotEmpty && !dto.avatarUrl.startsWith('http');
      if (isLocalAvatar) {
        try {
          final cachedPath = await ImageUtils.saveLocalImage(dto.avatarUrl);
          if (cachedPath != null) {
            dto = dto.copyWith(
              avatarLocalPath: cachedPath,
              avatarUrl: cachedPath,
            );
          }
        } catch (_) {}
      }

      // 1. Snapshot for rollback
      final snapshot = await _localDataSource.watchUserProfile(dto.id).first;

      // 2. Optimistic local write
      await _localDataSource.cacheUserProfile(dto);

      // 3. Remote call
      final remoteResult = await _remoteDataSource.updateProfile(dto);

      return remoteResult.fold(
        (failure) async {
          // 4. Rollback to snapshot
          if (snapshot != null) {
            await _localDataSource.cacheUserProfile(snapshot);
          }
          return Left(failure);
        },
        (remoteDto) async {
          // 5. Merge remote DTO (with http avatarUrl) back to local
          final merged = remoteDto.copyWith(avatarLocalPath: dto.avatarLocalPath);
          await _localDataSource.cacheUserProfile(merged);
          return const Right(unit);
        },
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to update user profile: $e'));
    }
  }

  @override
  Stream<Either<Failure, UserProfile?>> watchUserProfile(
    UserId userId,
  ) async* {
    try {
      await for (final dto in _localDataSource.watchUserProfile(userId.value)) {
        if (dto != null) {
          yield Right(dto.toDomain());
        } else {
          yield const Right(null);
        }
      }
    } catch (e) {
      yield Left(DatabaseFailure('Failed to watch user profile: $e'));
    }
  }

  @override
  Future<Either<Failure, UserProfile>> syncProfileFromRemote(
    UserId userId,
  ) async {
    try {
      final remoteResult = await _remoteDataSource.getProfileById(userId.value);
      return remoteResult.fold(
        (failure) => Left(failure),
        (remoteDto) async {
          await _localDataSource.cacheUserProfile(remoteDto);
          return Right(remoteDto.toDomain());
        },
      );
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to sync profile from remote: $e'),
      );
    }
  }

  @override
  Future<Either<Failure, Unit>> clearProfileCache() async {
    try {
      await _localDataSource.clearCache();
      return const Right(unit);
    } catch (e) {
      return Left(ServerFailure('Failed to clear profile cache: $e'));
    }
  }

  @override
  Future<Either<Failure, bool>> profileExists(UserId userId) async {
    try {
      // Check local first
      final localDto = await _localDataSource.watchUserProfile(userId.value).first;
      if (localDto != null) return const Right(true);

      // Check remote
      final remoteResult = await _remoteDataSource.getProfileById(userId.value);
      return remoteResult.fold(
        (failure) => const Right(false),
        (remoteDto) async {
          await _localDataSource.cacheUserProfile(remoteDto);
          return const Right(true);
        },
      );
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to check if profile exists: $e'),
      );
    }
  }

  @override
  Future<Either<Failure, UserProfile?>> findUserByEmail(String email) async {
    try {
      final localDto = await _localDataSource.findUserByEmail(email);
      if (localDto != null) return Right(localDto.toDomain());

      final remoteResult = await _remoteDataSource.findUserByEmail(email);
      return remoteResult.fold(
        (failure) => Left(failure),
        (remoteDto) async {
          if (remoteDto != null) {
            await _localDataSource.cacheUserProfile(remoteDto);
            return Right(remoteDto.toDomain());
          }
          return const Right(null);
        },
      );
    } catch (e) {
      return Left(DatabaseFailure('Failed to find user by email: $e'));
    }
  }

}
