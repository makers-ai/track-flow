# User Profile Online-First Optimistic Refactor Plan

**Date:** 2026-02-14
**Status:** Complete
**Feature:** user_profile
**Pattern:** Migrate from offline-first → online-first optimistic writes with rollback + local-first reads with remote revalidation

---

## Summary

Refactor `UserProfileRepositoryImpl` to implement online-first optimistic updates with rollback:

- **Writes** (update only): Optimistic local write (instant UI), call remote, rollback on failure
- **Reads** (getUserProfile, findUserByEmail, profileExists): Local-first cache, fire-and-forget remote revalidation
- **Streams** (watchUserProfile): Keep as Isar reactive stream (unchanged)

Additionally:
- **Keep** `UserProfileLocalDataSource` and `UserProfileDocument` as pure cache layer
- **Keep** `UserProfileCacheRepositoryImpl` separate (bulk collaborator operations)
- **Delete** sync infrastructure: executor, incremental sync services
- **Remove** dead dependencies: `BackgroundSyncCoordinator`, `PendingOperationsManager`, `NetworkStateManager`, `FirebaseFirestore`, `SessionStorage`
- **Create tests** (none exist for repository)

---

## Phase 1: Rewrite UserProfileRepositoryImpl

### 1.1 Rewrite the repository
**File:** `lib/features/user_profile/data/repositories/user_profile_repository_impl.dart`

**Remove dependencies:**
- `BackgroundSyncCoordinator` (injected but never used - dead code)
- `PendingOperationsManager` (injected but never used - dead code)
- `NetworkStateManager` (no connectivity checks - online-first means just try remote)
- `FirebaseFirestore` (used in `profileExists` for direct doc check - replace with remote datasource)
- `SessionStorage` (marked as unused)

**Keep dependencies:**
- `UserProfileLocalDataSource` (Isar cache)
- `UserProfileRemoteDataSource` (Firebase)

**New constructor:**
```dart
@LazySingleton(as: UserProfileRepository)
class UserProfileRepositoryImpl implements UserProfileRepository {
  final UserProfileLocalDataSource _localDataSource;
  final UserProfileRemoteDataSource _remoteDataSource;

  UserProfileRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
  );
}
```

**Method changes:**

#### `updateUserProfile` - Optimistic with rollback:
```dart
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
          dto = dto.copyWith(avatarLocalPath: cachedPath, avatarUrl: cachedPath);
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
```

#### `getUserProfile` - Local-first with remote revalidation:
```dart
@override
Future<Either<Failure, UserProfile?>> getUserProfile(UserId userId) async {
  try {
    final localDto = await _localDataSource.watchUserProfile(userId.value).first;

    if (localDto != null) {
      // Fire-and-forget remote revalidation
      _revalidateProfileFromRemote(userId.value);
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
```

#### `watchUserProfile` - Keep as Isar reactive stream (no changes):
Same behavior, just cleaner logging.

#### `syncProfileFromRemote` - Simplified (no network check):
```dart
@override
Future<Either<Failure, UserProfile>> syncProfileFromRemote(UserId userId) async {
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
    return Left(DatabaseFailure('Failed to sync profile from remote: $e'));
  }
}
```

#### `profileExists` - Use remote datasource instead of direct Firestore:
```dart
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
    return Left(DatabaseFailure('Failed to check if profile exists: $e'));
  }
}
```

#### `findUserByEmail` - Local-first + remote fallback (no network check):
```dart
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
```

#### `clearProfileCache` - No changes needed.

#### Helper for fire-and-forget revalidation:
```dart
void _revalidateProfileFromRemote(String userId) {
  _remoteDataSource.getProfileById(userId).then((result) {
    result.fold(
      (failure) => AppLogger.warning(
        'Remote revalidation failed: ${failure.message}',
        tag: 'UserProfileRepository',
      ),
      (remoteDto) async {
        await _localDataSource.cacheUserProfile(remoteDto);
      },
    );
  }).catchError((e) {
    AppLogger.warning(
      'Remote revalidation error: $e',
      tag: 'UserProfileRepository',
    );
  });
}
```

- [x] Task 1.1: Rewrite UserProfileRepositoryImpl

---

## Phase 2: Clean up UserProfileCacheRepositoryImpl

### 2.1 Remove NetworkStateManager dependency
**File:** `lib/features/user_profile/data/repositories/user_profile_cache_repository_impl.dart`

**Remove:**
- `NetworkStateManager` dependency
- All `isConnected` checks

**Keep:**
- `UserProfileRemoteDataSource`
- `UserProfileLocalDataSource`

**Changes:**
- `getUserProfilesByIds`: Remove network check, just call remote directly
- `preloadProfiles`: Remove network check, just call remote directly
- All other methods: No changes needed

- [x] Task 2.1: Clean up UserProfileCacheRepositoryImpl

---

## Phase 3: Delete Sync Infrastructure

### 3.1 Delete files
- `lib/core/sync/domain/executors/user_profile_operation_executor.dart`
- `lib/features/user_profile/data/services/user_profile_incremental_sync_service.dart`
- `lib/features/user_profile/data/services/user_profile_collaborator_incremental_sync_service.dart`

### 3.2 Update OperationExecutorFactory
**File:** `lib/core/sync/domain/executors/operation_executor_factory.dart`

- Remove import of `user_profile_operation_executor.dart`
- Remove `case 'user_profile':` from `getExecutor()` switch
- Remove `'user_profile'` from `supportedEntityTypes` list

### 3.3 Update SyncCoordinator
**File:** `lib/core/sync/domain/services/sync_coordinator.dart`

- Remove import of `user_profile_dto.dart`
- Remove import of `user_profile_collaborator_incremental_sync_service.dart`
- Remove `_userProfileLastSyncKey` and `_userProfileServiceKey` constants
- Remove `_collaboratorsLastSyncKey` and `_collaboratorsServiceKey` constants
- Remove user_profile entries from `pullStartupData`
- Remove user_profile and collaborators entries from `pullAllData`
- Remove user_profile and collaborators entries from `getSyncStatistics`
- Remove user_profile and collaborators cases from `_getServiceByKey`
- Remove user_profile and collaborators cases from `_getServiceKeyForEntity`
- Remove user_profile and collaborators cases from `_getSyncKeyForEntity`
- Remove user_profile and collaborators entries from `clearAllSyncKeys`

- [x] Task 3.1: Delete sync files
- [x] Task 3.2: Update OperationExecutorFactory
- [x] Task 3.3: Update SyncCoordinator

---

## Phase 4: DI & Code Generation

### 4.1 Run build_runner
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

### 4.2 Run flutter analyze
```bash
flutter analyze
```

- [x] Task 4.1: Run build_runner
- [x] Task 4.2: Run flutter analyze and fix errors

---

## Phase 5: Tests

### 5.1 Create repository tests
**File:** `test/features/user_profile/data/repositories/user_profile_repository_impl_test.dart`

Test cases for writes (optimistic + rollback):
1. `updateUserProfile` - should write locally first, then succeed on remote, then merge remote DTO back
2. `updateUserProfile` - should rollback to snapshot when remote fails
3. `updateUserProfile` - should handle avatar normalization before optimistic write

Test cases for reads (local-first with revalidation):
4. `getUserProfile` - should return local cache when found
5. `getUserProfile` - should fetch from remote when not in local cache
6. `getUserProfile` - should trigger background remote revalidation when cache hit
7. `findUserByEmail` - should return local when found
8. `findUserByEmail` - should fallback to remote when not local
9. `profileExists` - should return true when found locally
10. `profileExists` - should check remote when not local

Test cases for other operations:
11. `syncProfileFromRemote` - should fetch remote and cache locally
12. `clearProfileCache` - should delegate to local datasource
13. `watchUserProfile` - should delegate to local datasource stream

### 5.2 Run tests
```bash
flutter test test/features/user_profile/data/repositories/user_profile_repository_impl_test.dart
```

- [x] Task 5.1: Create user profile repository tests
- [x] Task 5.2: Run all tests and verify passing

---

## Files Changed Summary

| File | Action |
|------|--------|
| `lib/features/user_profile/data/repositories/user_profile_repository_impl.dart` | **Rewrite** (online-first optimistic) |
| `lib/features/user_profile/data/repositories/user_profile_cache_repository_impl.dart` | Modify (remove NetworkStateManager) |
| `lib/core/sync/domain/executors/operation_executor_factory.dart` | Modify (remove user_profile case) |
| `lib/core/sync/domain/services/sync_coordinator.dart` | Modify (remove user_profile + collaborators) |
| `lib/core/sync/domain/executors/user_profile_operation_executor.dart` | **Delete** |
| `lib/features/user_profile/data/services/user_profile_incremental_sync_service.dart` | **Delete** |
| `lib/features/user_profile/data/services/user_profile_collaborator_incremental_sync_service.dart` | **Delete** |
| `lib/core/di/injection.config.dart` | Auto-regenerated |
| `test/features/user_profile/data/repositories/user_profile_repository_impl_test.dart` | **Create** |

## Files Kept (unchanged)

| File | Reason |
|------|--------|
| `lib/features/user_profile/data/datasources/user_profile_local_datasource.dart` | Kept as pure cache layer |
| `lib/features/user_profile/data/datasources/user_profile_remote_datasource.dart` | Kept (Firebase source of truth) |
| `lib/features/user_profile/data/models/user_profile_document.dart` | Kept for Isar cache model |
| `lib/features/user_profile/data/models/user_profile_dto.dart` | Kept (DTO) |
| `lib/features/user_profile/domain/repositories/user_profile_repository.dart` | No contract changes |
| `lib/features/user_profile/domain/repositories/user_profiles_cache_repository.dart` | No contract changes |
| All presentation layer files | No changes needed |
| All domain use cases | No changes needed |
