# Waveform Remote-First Refactor Implementation Plan

## Overview

Refactor the waveform feature to eliminate the offline-first + queue + background sync pattern and migrate to a remote-first approach with local cache. All write/delete operations call Firebase first and only persist locally after remote success. Read operations use local cache with remote fallback.

## Current State Analysis

### Repository (`waveform_repository_impl.dart`)
- Depends on 4 services: `WaveformLocalDataSource`, `WaveformRemoteDataSource`, `BackgroundSyncCoordinator`, `PendingOperationsManager`
- `getWaveformByVersionId`: reads from local Isar only (no remote fallback)
- `deleteWaveformsForVersion`: deletes locally first, queues remote deletion via `PendingOperationsManager`
- `storeCanonicalWaveform` (deprecated): saves locally first, queues remote upload
- `storeCanonicalWaveformOnline`: already remote-first (upload to Firebase, then cache locally)
- `watchWaveformChanges`: watches local Isar (keeps working)
- `clearAllWaveforms`: clears local Isar (keeps working)

### Key Discoveries:
- `WaveformRemoteDataSource.fetchCanonicalForVersion()` requires both `trackId` and `versionId` (`waveform_remote_datasource.dart:13-16`)
- Current domain contract `getWaveformByVersionId()` only takes `versionId` - needs `trackId` for remote fallback
- `GenerateAndStoreWaveform` use case already calls `storeCanonicalWaveformOnline` (`generate_and_store_waveform.dart:50`)
- `WaveformBloc` calls `GetWaveformByVersion` use case which delegates to `getWaveformByVersionId` (`waveform_bloc.dart:84`)
- `OperationExecutorFactory` references `WaveformOperationExecutor` at line 39-40
- `SyncCoordinator` references `WaveformIncrementalSyncService` at lines 52, 62, 153-158, 235-236
- `app_module.dart:78` registers `AudioWaveformDocumentSchema` in Isar (must keep)
- Existing tests (`delete_track_version_usecase_test.dart`, `delete_audio_track_usecase_test.dart`) mock `WaveformRepository` at domain level - no changes needed

## Desired End State

After this refactor:
- All write/delete operations go to Firebase first, then persist locally on success
- Read operations check local cache first, fallback to remote if not found
- No `PendingOperationsManager`, no `BackgroundSyncCoordinator`, no queue, no background sync
- `WaveformOperationExecutor` and `WaveformIncrementalSyncService` are deleted
- Domain contract updated: `getWaveformByVersionId` includes `AudioTrackId`, deprecated `storeCanonicalWaveform` removed
- Local datasource and Isar model preserved for caching

### Verification:
- `flutter analyze` passes with no errors
- `flutter test` passes
- `flutter packages pub run build_runner build --delete-conflicting-outputs` regenerates DI successfully
- Waveform loading in the app works (remote fetch + local cache)

## What We're NOT Doing

- Removing the local datasource or Isar model (they remain as cache)
- Changing the remote datasource implementation
- Adding retry logic or offline queue
- Modifying waveform presentation widgets
- Changing the audio waveform domain entity or value objects

## Implementation Approach

The refactor follows a bottom-up approach: first update the domain contract, then the repository implementation, then clean up sync infrastructure, then update DI, and finally update tests.

---

## Phase 1: Update Domain Contract

### Overview
Update `WaveformRepository` interface to reflect remote-first design: add `trackId` to `getWaveformByVersionId`, remove deprecated `storeCanonicalWaveform`.

### Changes Required:

#### 1. Domain Repository Contract
**File**: `lib/features/waveform/domain/repositories/waveform_repository.dart`
**Changes**: Add `AudioTrackId` parameter to `getWaveformByVersionId`, remove deprecated `storeCanonicalWaveform`

```dart
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
```

#### 2. Use Case Update
**File**: `lib/features/waveform/domain/usecases/get_waveform_by_version.dart`
**Changes**: Update `call()` to accept both `trackId` and `versionId`

```dart
@injectable
class GetWaveformByVersion {
  final WaveformRepository _repository;
  GetWaveformByVersion(this._repository);

  Future<Either<Failure, AudioWaveform>> call(
    AudioTrackId trackId,
    TrackVersionId versionId,
  ) {
    return _repository.getWaveformByVersionId(trackId, versionId);
  }
}
```

#### 3. WaveformBloc Update
**File**: `lib/features/waveform/presentation/bloc/waveform_bloc.dart`
**Changes**: Update `LoadWaveform` event to include `trackId`, update `_onLoadWaveform` to pass it through

In `waveform_event.dart` (part file), the `LoadWaveform` event needs a `trackId` field:
```dart
class LoadWaveform extends WaveformEvent {
  final AudioTrackId trackId;      // NEW
  final TrackVersionId versionId;
  final String? audioSourceHash;
  final String? audioFilePath;
  // ...
}
```

In `_onLoadWaveform`:
```dart
final result = await _getWaveformByVersion.call(event.trackId, event.versionId);
```

**Note**: All callers of `LoadWaveform` event (in presentation widgets) must be updated to pass `trackId`. Identify callers by searching for `LoadWaveform(` in the codebase.

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes (may have errors until Phase 2 completes)

#### Manual Verification:
- [x] Contract changes are consistent across domain, use case, and presentation layers

**Implementation Note**: Phase 1 and Phase 2 should be done together since the contract change will break the repository implementation.

---

## Phase 2: Refactor Repository Implementation

### Overview
Rewrite `WaveformRepositoryImpl` to remove sync dependencies and implement remote-first with local cache pattern.

### Changes Required:

#### 1. Repository Implementation
**File**: `lib/features/waveform/data/repositories/waveform_repository_impl.dart`
**Changes**: Remove `BackgroundSyncCoordinator` and `PendingOperationsManager` dependencies. Rewrite operations for remote-first pattern.

```dart
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
```

**Key changes:**
- Constructor only takes `WaveformLocalDataSource` + `WaveformRemoteDataSource`
- Removed imports: `BackgroundSyncCoordinator`, `PendingOperationsManager`, `SyncOperationDocument`, `dart:async`
- `getWaveformByVersionId`: local cache → remote fallback → cache on success
- `deleteWaveformsForVersion`: remote first → local delete on success
- `storeCanonicalWaveformOnline`: unchanged (already remote-first)
- Removed: deprecated `storeCanonicalWaveform` method

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes
- [x] No references to `PendingOperationsManager` or `BackgroundSyncCoordinator` in waveform feature

---

## Phase 3: Delete Sync Infrastructure Files

### Overview
Remove the waveform-specific sync files and clean up references in shared sync infrastructure.

### Changes Required:

#### 1. Delete files
- **Delete**: `lib/core/sync/domain/executors/waveform_operation_executor.dart`
- **Delete**: `lib/features/waveform/data/services/waveform_incremental_sync_service.dart`

#### 2. Update OperationExecutorFactory
**File**: `lib/core/sync/domain/executors/operation_executor_factory.dart`
**Changes**: Remove `audio_waveform` case and import

Remove the import:
```dart
// DELETE: import 'package:trackflow/core/sync/domain/executors/waveform_operation_executor.dart';
```

Remove from `getExecutor()` switch:
```dart
// DELETE:
// case 'audio_waveform':
//   return sl<WaveformOperationExecutor>();
```

Remove from `supportedEntityTypes`:
```dart
// DELETE: 'audio_waveform',
```

#### 3. Update SyncCoordinator
**File**: `lib/core/sync/domain/services/sync_coordinator.dart`
**Changes**: Remove all waveform sync entries

Remove:
- Import: `waveform_incremental_sync_service.dart` (line 13)
- Constants: `_waveformsLastSyncKey` (line 52), `_waveformsServiceKey` (line 62)
- `pullAllData`: Remove `_syncEntityByKey` call for waveforms (lines 153-158)
- `getSyncStatistics`: Remove `_waveformsServiceKey` from services list (line 212)
- `_getServiceByKey`: Remove `_waveformsServiceKey` case (lines 235-236)
- `_getServiceKeyForEntity`: Remove `'waveforms'` case (lines 327)
- `_getSyncKeyForEntity`: Remove `'waveforms'` case (line 351)
- `clearAllSyncKeys`: Remove `_waveformsLastSyncKey` removal (line 385)

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes
- [x] `grep -r "WaveformOperationExecutor" lib/` returns no results
- [x] `grep -r "WaveformIncrementalSyncService" lib/` returns no results
- [x] `grep -r "waveforms_last_sync" lib/` returns no results

---

## Phase 4: Update Dependency Injection

### Overview
Regenerate DI configuration to reflect the removed classes and updated constructor signatures.

### Changes Required:

#### 1. Regenerate injection.config.dart
Run `build_runner` to regenerate the DI configuration:
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

The generated `injection.config.dart` should automatically:
- Remove `WaveformLocalDataSourceImpl` factory → **keep** (still needed)
- Remove `WaveformIncrementalSyncService` lazy singleton → **removed** (file deleted)
- Remove `WaveformOperationExecutor` factory → **removed** (file deleted)
- Update `WaveformRepositoryImpl` factory to only inject `localDataSource` + `remoteDataSource` (no more `backgroundSyncCoordinator` + `pendingOperationsManager`)

#### 2. Verify DI registrations
After regeneration, verify in `injection.config.dart`:
- `WaveformLocalDataSource` registration still exists
- `WaveformRemoteDataSource` registration still exists
- `WaveformRepositoryImpl` only gets 2 dependencies
- No references to deleted classes

### Success Criteria:

#### Automated Verification:
- [x] `flutter packages pub run build_runner build --delete-conflicting-outputs` succeeds
- [x] `flutter analyze` passes
- [x] No `WaveformOperationExecutor` or `WaveformIncrementalSyncService` in `injection.config.dart`

---

## Phase 5: Update LoadWaveform Callers

### Overview
Find and update all callers of the `LoadWaveform` event to pass `trackId`.

### Changes Required:

#### 1. Find all callers
Search for `LoadWaveform(` across the presentation layer to identify widgets that dispatch this event.

#### 2. Update each caller
Each caller must provide `trackId` along with `versionId`. The `trackId` should be available from the parent context (project/track detail screens typically have this).

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes with zero errors
- [x] `flutter test` passes

#### Manual Verification:
- [ ] Waveform loads correctly when opening a track detail screen
- [ ] Waveform displays after first load (remote fetch + local cache)
- [ ] Subsequent loads use cached data (faster)

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation that waveform loading works end-to-end before proceeding.

---

## Phase 6: Update Tests

### Overview
No existing tests need structural changes since they mock `WaveformRepository` at the domain level. However, we should add a new test for the refactored `WaveformRepositoryImpl`.

### Changes Required:

#### 1. Existing tests - No changes needed
- `delete_track_version_usecase_test.dart`: Mocks `WaveformRepository` interface, not implementation
- `delete_audio_track_usecase_test.dart`: Same - mocks at domain level

#### 2. New test: WaveformRepositoryImpl
**File**: `test/features/waveform/data/repositories/waveform_repository_impl_test.dart`
**Test cases**:

```dart
@GenerateMocks([WaveformLocalDataSource, WaveformRemoteDataSource])
void main() {
  group('WaveformRepositoryImpl', () {
    // getWaveformByVersionId
    test('should return local waveform when found in cache');
    test('should fallback to remote when not in local cache');
    test('should cache waveform locally after remote fetch');
    test('should return failure when not found in local or remote');

    // deleteWaveformsForVersion
    test('should delete remote first then local');
    test('should propagate remote error without touching local');

    // storeCanonicalWaveformOnline
    test('should upload to remote first then cache locally');
    test('should propagate remote error without caching locally');

    // clearAllWaveforms
    test('should clear local cache');

    // watchWaveformChanges
    test('should delegate to local datasource');
  });
}
```

**Mock only**: `WaveformLocalDataSource`, `WaveformRemoteDataSource`
**No mocks for**: `PendingOperationsManager`, `BackgroundSyncCoordinator`, `WaveformOperationExecutor`

### Success Criteria:

#### Automated Verification:
- [x] `flutter test test/features/waveform/` passes
- [x] All test cases verify remote-first behavior
- [x] No references to sync/queue mocks in waveform tests

---

## Testing Strategy

### Unit Tests:
- Repository: verify local-cache-first read, remote fallback, cache-on-success
- Repository: verify remote-first write/delete, local-after-success
- Repository: verify error propagation from remote datasource

### Integration Tests:
- End-to-end waveform loading with Firebase Storage
- Cache invalidation behavior

### Manual Testing Steps:
1. Open a track with an existing waveform - should load from cache
2. Clear app data, open the same track - should fetch from remote and cache
3. Generate a new waveform - should upload to Firebase first, then appear locally
4. Delete a track version - waveform should be deleted from Firebase and local cache
5. Verify no pending operations or background sync activity in logs

## Performance Considerations

- Read operations maintain performance via local Isar cache (no network call for cached waveforms)
- First-time reads add one network round-trip (Firebase Storage fetch)
- Write/delete operations now wait for network (slightly slower than fire-and-forget queue, but more reliable)

## References

- Current repository: `lib/features/waveform/data/repositories/waveform_repository_impl.dart`
- Remote datasource: `lib/features/waveform/data/datasources/waveform_remote_datasource.dart`
- Local datasource: `lib/features/waveform/data/datasources/waveform_local_datasource.dart`
- Domain contract: `lib/features/waveform/domain/repositories/waveform_repository.dart`
- Use case: `lib/features/waveform/domain/usecases/get_waveform_by_version.dart`
- BLoC: `lib/features/waveform/presentation/bloc/waveform_bloc.dart`
- Similar refactor: `thoughts/shared/plans/2026-02-11-online-first-delete-audio-track.md`
