# Playlist Remote-First Refactor Plan

**Date:** 2026-02-14
**Status:** Complete
**Feature:** Playlist
**Pattern:** Migrate from offline-first + queue + background sync → optimistic writes with rollback + local-first reads with remote revalidation

---

## Summary

Refactor `PlaylistRepositoryImpl` to eliminate offline-first sync infrastructure (`BackgroundSyncCoordinator`, `PendingOperationsManager`, queue operations) and replace with a remote-first pattern:

- **Writes** (add, update, delete): Optimistic local write first (instant UI), then call remote. On remote success → done. On remote failure → rollback local to previous state
- **Reads** (getAll, getById): Return local cache first (fast UX), then fire-and-forget a background remote fetch to revalidate and update local cache for next call

Additionally:
- **Add `userId` filtering** to remote `getAllPlaylists` query
- **Add `PlaylistRemoteDataSource`** as a new dependency to `PlaylistRepositoryImpl` (currently NOT injected)
- **Delete `playlist_operation_executor.dart`** and remove from factory/sync coordinator
- **Keep** `playlist_local_data_source.dart`, `playlist_document.dart` for caching
- **Create tests** (none exist currently)

---

## Phase 1: Domain Contract Updates

### 1.1 Update `PlaylistRepository` contract
**File:** `lib/features/playlist/domain/repositories/playlist_repository.dart`

- Add `String userId` parameter to `getAllPlaylists(String userId)`
- No other signature changes needed

```dart
abstract class PlaylistRepository {
  Future<Either<Failure, Unit>> addPlaylist(Playlist playlist);
  Future<Either<Failure, List<Playlist>>> getAllPlaylists(String userId);
  Future<Either<Failure, Playlist?>> getPlaylistById(PlaylistId id);
  Future<Either<Failure, Unit>> updatePlaylist(Playlist playlist);
  Future<Either<Failure, Unit>> deletePlaylist(PlaylistId id);
}
```

### 1.2 Update `GetPlaylists` use case
**File:** `lib/features/playlist/domain/usecases/get_playlists.dart`

- Add `String userId` parameter to `call()` method
- Pass through to repository

### 1.3 Update callers of `GetPlaylists`
- Search for all callers and pass userId from auth state

- [x] Task 1.1: Update domain contract with userId parameter
- [x] Task 1.2: Update GetPlaylists use case
- [x] Task 1.3: Update all callers of GetPlaylists/getAllPlaylists (no external callers found)

---

## Phase 2: Remote DataSource - Add userId Filtering

### 2.1 Update `PlaylistRemoteDataSource` abstract class and implementation
**File:** `lib/features/playlist/data/datasources/playlist_remote_data_source.dart`

- Add `String userId` parameter to `getAllPlaylists(String userId)`
- Filter Firestore query: `.where('userId', isEqualTo: userId)`
- Add `userId` field to `addPlaylist` data (include in Firestore document)

### 2.2 Update `PlaylistDto` to include userId
**File:** `lib/features/playlist/data/models/playlist_dto.dart`

- Add `String? userId` field
- Include in `toJson()` and `fromJson()`
- Include in `fromDomain()` (will need userId passed as parameter)

- [x] Task 2.1: Add userId filtering to remote datasource
- [x] Task 2.2: Add userId to PlaylistDto

---

## Phase 3: Repository Implementation Refactor

### 3.1 Rewrite `PlaylistRepositoryImpl`
**File:** `lib/features/playlist/data/repositories/playlist_repository_impl.dart`

**Remove:**
- `BackgroundSyncCoordinator` dependency
- `PendingOperationsManager` dependency
- `SyncOperationDocument` import
- `unawaited()` helper method
- All queue operations (`addCreateOperation`, `addUpdateOperation`, `addDeleteOperation`)
- All `_backgroundSyncCoordinator.pushUpstream()` calls

**Add:**
- `PlaylistRemoteDataSource` dependency (NEW - not currently injected)

**New behavior:**

#### Writes (add, update, delete) - Optimistic with rollback:
```
1. Snapshot current local state (for rollback)
2. Optimistic local write (immediate UI feedback)
3. Call remote datasource (await result)
4. If remote succeeds → done, local is already correct
5. If remote fails → rollback local to snapshot, return Left(failure)
```

#### Reads (getAll, getById) - Local-first with remote revalidation:
```
1. Read from local cache
2. Return local data immediately
3. Fire-and-forget: fetch from remote, update local cache
   (next call will return fresh data)
```

---

**`addPlaylist` - Optimistic create with rollback:**
```dart
@override
Future<Either<Failure, Unit>> addPlaylist(Playlist playlist) async {
  try {
    final dto = PlaylistDto.fromDomain(playlist);

    // 1. Optimistic local write
    await _localDataSource.addPlaylist(dto);

    // 2. Remote call
    final remoteResult = await _remoteDataSource.addPlaylist(dto);

    return remoteResult.fold(
      (failure) async {
        // 3. Rollback: remove optimistic local write
        await _localDataSource.deletePlaylist(dto.id);
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to add playlist: $e'));
  }
}
```

**`updatePlaylist` - Optimistic update with rollback:**
```dart
@override
Future<Either<Failure, Unit>> updatePlaylist(Playlist playlist) async {
  try {
    final dto = PlaylistDto.fromDomain(playlist);

    // 1. Snapshot for rollback
    final snapshotResult = await _localDataSource.getPlaylistById(dto.id);
    final snapshot = snapshotResult.fold((_) => null, (dto) => dto);

    // 2. Optimistic local write
    await _localDataSource.updatePlaylist(dto);

    // 3. Remote call
    final remoteResult = await _remoteDataSource.updatePlaylist(dto);

    return remoteResult.fold(
      (failure) async {
        // 4. Rollback to snapshot
        if (snapshot != null) {
          await _localDataSource.updatePlaylist(snapshot);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to update playlist: $e'));
  }
}
```

**`deletePlaylist` - Optimistic delete with rollback:**
```dart
@override
Future<Either<Failure, Unit>> deletePlaylist(PlaylistId id) async {
  try {
    // 1. Snapshot for rollback
    final snapshotResult = await _localDataSource.getPlaylistById(id.value);
    final snapshot = snapshotResult.fold((_) => null, (dto) => dto);

    // 2. Optimistic local delete
    await _localDataSource.deletePlaylist(id.value);

    // 3. Remote call
    final remoteResult = await _remoteDataSource.deletePlaylist(id.value);

    return remoteResult.fold(
      (failure) async {
        // 4. Rollback: re-insert deleted playlist
        if (snapshot != null) {
          await _localDataSource.addPlaylist(snapshot);
        }
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to delete playlist: $e'));
  }
}
```

**`getAllPlaylists` - Local-first with remote revalidation:**
```dart
@override
Future<Either<Failure, List<Playlist>>> getAllPlaylists(String userId) async {
  try {
    // 1. Return local cache immediately
    final localResult = await _localDataSource.getAllPlaylists();

    // 2. Fire-and-forget remote revalidation
    _revalidatePlaylistsFromRemote(userId);

    return localResult.fold(
      (failure) => Left(failure),
      (dtos) => Right(dtos.map((dto) => dto.toDomain()).toList()),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to get playlists: $e'));
  }
}

void _revalidatePlaylistsFromRemote(String userId) {
  _remoteDataSource.getAllPlaylists(userId).then((result) {
    result.fold(
      (failure) => AppLogger.warning('Remote revalidation failed: ${failure.message}'),
      (remoteDtos) async {
        for (final dto in remoteDtos) {
          await _localDataSource.addPlaylist(dto); // upsert
        }
      },
    );
  }).catchError((e) {
    AppLogger.warning('Remote revalidation error: $e');
  });
}
```

**`getPlaylistById` - Local-first with remote revalidation:**
```dart
@override
Future<Either<Failure, Playlist?>> getPlaylistById(PlaylistId id) async {
  try {
    // 1. Return local cache first
    final localResult = await _localDataSource.getPlaylistById(id.value);

    // 2. Fire-and-forget remote revalidation
    _revalidatePlaylistByIdFromRemote(id.value);

    return localResult.fold(
      (failure) => Left(failure),
      (dto) => Right(dto?.toDomain()),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to get playlist: $e'));
  }
}
```

- [x] Task 3.1: Rewrite PlaylistRepositoryImpl with optimistic writes + rollback + local-first reads

---

## Phase 4: Delete Sync Infrastructure

### 4.1 Delete `playlist_operation_executor.dart`
**File:** `lib/core/sync/domain/executors/playlist_operation_executor.dart`

### 4.2 Update `OperationExecutorFactory`
**File:** `lib/core/sync/domain/executors/operation_executor_factory.dart`

- Remove import of `playlist_operation_executor.dart`
- Remove `case 'playlist':` from `getExecutor()` switch
- Remove `'playlist'` from `supportedEntityTypes` list

### 4.3 Verify SyncCoordinator
**File:** `lib/core/sync/domain/services/sync_coordinator.dart`

- Confirm no playlist-specific entries exist (already verified during research: no playlist keys/entries in sync coordinator)

- [x] Task 4.1: Delete playlist_operation_executor.dart
- [x] Task 4.2: Update operation_executor_factory.dart
- [x] Task 4.3: Verify sync_coordinator.dart has no playlist references

---

## Phase 5: DI & Code Generation

### 5.1 Run build_runner
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

- This regenerates `injection.config.dart` to reflect:
  - New `PlaylistRemoteDataSource` dependency in `PlaylistRepositoryImpl`
  - Removed `BackgroundSyncCoordinator` and `PendingOperationsManager` dependencies
  - Deleted `PlaylistOperationExecutor` registration

### 5.2 Run flutter analyze
```bash
flutter analyze
```

- Fix any remaining compilation errors

- [x] Task 5.1: Run build_runner
- [x] Task 5.2: Run flutter analyze and fix errors (0 new issues)

---

## Phase 6: Tests

### 6.1 Create repository tests
**File:** `test/features/playlist/data/repositories/playlist_repository_impl_test.dart`

Test cases for writes (optimistic + rollback):
1. `addPlaylist` - should write locally first, then succeed on remote
2. `addPlaylist` - should rollback local write when remote fails (delete optimistic entry)
3. `updatePlaylist` - should write locally first, then succeed on remote
4. `updatePlaylist` - should rollback to snapshot when remote fails (restore previous state)
5. `deletePlaylist` - should delete locally first, then succeed on remote
6. `deletePlaylist` - should rollback by re-inserting snapshot when remote fails

Test cases for reads (local-first with revalidation):
7. `getAllPlaylists` - should return local data immediately
8. `getAllPlaylists` - should trigger background remote revalidation
9. `getAllPlaylists` - should return failure when local throws
10. `getPlaylistById` - should return local data immediately
11. `getPlaylistById` - should return null when not found locally

### 6.2 Run tests
```bash
flutter test test/features/playlist/data/repositories/playlist_repository_impl_test.dart
```

- [x] Task 6.1: Create playlist repository tests (11 tests)
- [x] Task 6.2: Run all tests and verify passing (11 playlist + 12 waveform = 23 total)

---

## Files Changed Summary

| File | Action |
|------|--------|
| `lib/features/playlist/domain/repositories/playlist_repository.dart` | Modify (add userId to getAllPlaylists) |
| `lib/features/playlist/domain/usecases/get_playlists.dart` | Modify (add userId param) |
| `lib/features/playlist/data/datasources/playlist_remote_data_source.dart` | Modify (add userId filtering) |
| `lib/features/playlist/data/models/playlist_dto.dart` | Modify (add userId field) |
| `lib/features/playlist/data/repositories/playlist_repository_impl.dart` | **Rewrite** (remote-first pattern) |
| `lib/core/sync/domain/executors/operation_executor_factory.dart` | Modify (remove playlist case) |
| `lib/core/sync/domain/executors/playlist_operation_executor.dart` | **Delete** |
| `lib/core/di/injection.config.dart` | Auto-regenerated |
| `test/features/playlist/data/repositories/playlist_repository_impl_test.dart` | **Create** |

## Files Kept (unchanged)

| File | Reason |
|------|--------|
| `lib/features/playlist/data/datasources/playlist_local_data_source.dart` | Kept for local cache |
| `lib/features/playlist/data/models/playlist_document.dart` | Kept for Isar cache model |
| `lib/features/playlist/presentation/bloc/playlist_bloc.dart` | No direct PlaylistRepository usage |
| All presentation widgets | No changes needed |
