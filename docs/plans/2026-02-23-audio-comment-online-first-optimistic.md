# Audio Comment: Online-First Optimistic with Rollback Migration

## Overview

Migrate the `audio_comment` feature from the offline-first queue-based architecture (PendingOperationsManager + BackgroundSyncCoordinator + OperationExecutor) to the **online-first optimistic with rollback** pattern. This means: write local first for immediate UI feedback, then call remote immediately, and rollback local changes if remote fails. No queues, no executors, no background sync.

## Current State Analysis

The `AudioCommentRepositoryImpl` currently:
- Injects `BackgroundSyncCoordinator`, `PendingOperationsManager` (offline-first queue infra)
- Does NOT inject `AudioCommentRemoteDataSource` directly — all remote access goes through queue/executor
- Uses `AudioStorageRepository` for local audio caching
- Uses `TrackVersionRepository` for `deleteByTrackId` (get all versions)
- Has a custom `unawaited()` helper for fire-and-forget background sync triggers

The `AudioCommentOperationExecutor` handles:
- `_executeCreate`: uploads audio file to Firebase Storage via `AudioFileRepository`, then creates Firestore document
- `_executeDelete`: soft-deletes Firestore document, then deletes audio from Storage
- `_executeDeleteByVersion`: fetches comments for audio URLs, batch soft-deletes, then deletes audio files

### Key Discoveries:
- `AudioCommentRemoteDataSource` has all needed methods: `addComment`, `deleteComment`, `getCommentsByVersionId`, `deleteByVersionId` (`audio_comment_remote_datasource.dart`)
- `AudioFileRepository` handles upload/delete to Firebase Storage (`lib/core/audio/domain/audio_file_repository.dart`)
- Local datasource returns `Either<Failure, T>` for most methods (`audio_comment_local_datasource.dart`)
- `AudioTrackRepositoryImpl.createTrack` uses remote-first pattern for file uploads — we'll adapt this for audio comments (`audio_track_repository_impl.dart:25-39`)
- The executor factory maps `'audio_comment' || 'audio_comment_by_version'` to the executor (`operation_executor_factory.dart:24`)
- `SyncCoordinator` has `_commentsLastSyncKey` and `_commentsServiceKey` for audio comments (`sync_coordinator.dart:40,45`)

## Desired End State

`AudioCommentRepositoryImpl` follows the same online-first optimistic pattern as `AudioTrackRepositoryImpl`, `ProjectsRepositoryImpl`, and `NotificationRepositoryImpl`:
- Injects only: `_localDataSource`, `_remoteDataSource`, `_audioFileRepository`, `_audioStorageRepository`, `_trackVersionRepository`
- No queue/sync dependencies
- All write methods: local first → remote → rollback on failure
- `addComment` with audio: local cache → upload audio to Storage → create remote doc → rollback all on failure
- Read methods: local streams with background revalidation
- Executor and sync service files deleted
- Factory and coordinator cleaned up

### Verification:
- `flutter analyze` passes with no issues
- All existing tests pass or are updated
- No references to `BackgroundSyncCoordinator` or `PendingOperationsManager` in audio_comment code
- No references to `AudioCommentOperationExecutor` anywhere in codebase

## What We're NOT Doing

- NOT changing the remote datasource interface or Firestore schema
- NOT changing the local datasource (Isar) interface
- NOT changing the domain entity or repository contract
- NOT adding new methods to the remote datasource
- NOT modifying the BLoC/presentation layer
- NOT touching `TrackVersionOperationExecutor` (still used by track_version feature)

## Implementation Approach

Single phase: refactor the repository, delete dead code, update factory/coordinator, update tests.

Since `addComment` involves an audio file upload (async, potentially slow), it follows a **hybrid approach**: cache locally first for instant UI, then upload audio + create remote. If either fails, rollback the local cache. This matches the user's explicit requirement: "Guardar localmente primero → Subir audio a Firebase Storage → Crear en remote → Si falla upload o remote, rollback local."

---

## Phase 1: Full Migration

### Overview
Refactor `AudioCommentRepositoryImpl` to online-first optimistic, delete executor + sync service, clean up factory and coordinator.

### Changes Required:

#### 1. Refactor `AudioCommentRepositoryImpl`
**File**: `lib/features/audio_comment/data/repositories/audio_comment_repository_impl.dart`
**Changes**: Complete rewrite of constructor and all write methods

**New constructor** (replace old):
```dart
@LazySingleton(as: AudioCommentRepository)
class AudioCommentRepositoryImpl implements AudioCommentRepository {
  final AudioCommentLocalDataSource _localDataSource;
  final AudioCommentRemoteDataSource _remoteDataSource;
  final AudioFileRepository _audioFileRepository;
  final AudioStorageRepository _audioStorageRepository;
  final TrackVersionRepository _trackVersionRepository;

  AudioCommentRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
    this._audioFileRepository,
    this._audioStorageRepository,
    this._trackVersionRepository,
  );
```

**Write methods — Optimistic + Rollback:**

`addComment`:
1. Convert to DTO, cache locally (`_localDataSource.cacheComment`)
2. If audio comment with local audio path: store audio in permanent local cache via `_audioStorageRepository`, then upload to Firebase Storage via `_audioFileRepository.uploadAudioFile` → get `audioStorageUrl`
3. Update DTO with `audioStorageUrl` and `localAudioPath`
4. Call `_remoteDataSource.addComment(updatedDto)`
5. On success: update local cache with final DTO (containing both `audioStorageUrl` and `localAudioPath`)
6. On failure (upload or remote): rollback by deleting from local cache (`_localDataSource.deleteCachedComment`)

`deleteComment`:
1. Snapshot: `_localDataSource.getCommentById` → save `prevDto`
2. If not found, return failure
3. Optimistic: `_localDataSource.deleteCachedComment`
4. Remote: `_remoteDataSource.deleteComment` (soft delete)
5. On failure: rollback by re-inserting `prevDto` via `_localDataSource.cacheComment`
6. On success: fire-and-forget audio file cleanup from Storage (if `prevDto.audioStorageUrl` exists)

`deleteCommentsByVersion`:
1. Snapshot: `_localDataSource.getCachedCommentsByVersion` → save all DTOs
2. Optimistic: `_localDataSource.deleteByVersion`
3. Remote: `_remoteDataSource.deleteByVersionId` (batch soft delete)
4. On failure: rollback by re-inserting all saved DTOs
5. On success: fire-and-forget audio file cleanup from Storage for each DTO with `audioStorageUrl`

`deleteByTrackId`:
1. Get all versions via `_trackVersionRepository.getVersionsByTrack`
2. For each version: execute `deleteCommentsByVersion` pattern
3. If ANY version's remote call fails: rollback ALL versions (restore all snapshots)

`deleteAllComments`: Local-only (unchanged — just clears local cache)

**Read methods — Local with background revalidation:**

`watchCommentsByVersion`:
1. Trigger `unawaited(_revalidateCommentsByVersion(versionId.value))` (fire-and-forget)
2. Return `_localDataSource.watchCommentsByVersion` stream mapped to domain

`getCommentById`: Local-only read (unchanged)

`watchCommentsByTrack`: Deprecated, returns empty (unchanged)

`watchRecentComments`: Local-only stream (unchanged)

**New private revalidation method:**
```dart
Future<void> _revalidateCommentsByVersion(String versionId) async {
  try {
    final remoteComments = await _remoteDataSource.getCommentsByVersionId(versionId);
    await _localDataSource.replaceCommentsForVersion(versionId, remoteComments);
  } catch (e) {
    AppLogger.warning(
      'Background comment revalidation failed for version $versionId: $e',
      tag: 'AudioCommentRepositoryImpl',
    );
  }
}
```

**Remove**: custom `unawaited()` helper — use `dart:async`'s `unawaited()` instead.

#### 2. Delete `AudioCommentOperationExecutor`
**File**: `lib/core/sync/domain/executors/audio_comment_operation_executor.dart`
**Action**: DELETE entire file

#### 3. Delete `AudioCommentIncrementalSyncService`
**File**: `lib/features/audio_comment/data/services/audio_comment_incremental_sync_service.dart`
**Action**: DELETE entire file

#### 4. Update `OperationExecutorFactory`
**File**: `lib/core/sync/domain/executors/operation_executor_factory.dart`
**Changes**: Remove `audio_comment` and `audio_comment_by_version` cases

```dart
// BEFORE:
case 'audio_comment' || 'audio_comment_by_version':
  return sl<AudioCommentOperationExecutor>();

// AFTER: remove this case entirely

// Also update supportedEntityTypes:
List<String> get supportedEntityTypes => [
  'track_version',
];
```

Also remove the import of `audio_comment_operation_executor.dart`.

#### 5. Update `SyncCoordinator`
**File**: `lib/core/sync/domain/services/sync_coordinator.dart`
**Changes**: Remove all audio_comments references

- Remove `_commentsLastSyncKey` constant
- Remove `_commentsServiceKey` constant
- Remove `_commentsServiceKey` from `pullAllData`
- Remove `_commentsServiceKey` case from `_getServiceByKey`
- Remove `'audio_comments'` case from `_getServiceKeyForEntity` and `_getSyncKeyForEntity`
- Remove `_commentsLastSyncKey` from `clearAllSyncKeys`
- Remove `_commentsServiceKey` from `getSyncStatistics`
- Remove import of `AudioCommentDTO`
- Remove import of `IncrementalSyncService` if no longer needed (check if still used by track_versions)

#### 6. Update `OperationExecutorFactory` test
**File**: `test/core/sync/domain/executors/operation_executor_factory_test.dart`
**Changes**:
- Remove test for `audio_comment` entity type (it will now throw UnsupportedError)
- Update `supportedEntityTypes` test to expect only `['track_version']` with length 1
- Add test verifying `audio_comment` and `audio_comment_by_version` throw UnsupportedError

#### 7. Delete executor test mocks (if orphaned)
**File**: `test/core/sync/domain/executors/audio_comment_operation_executor_test.mocks.dart`
**Action**: DELETE if no corresponding test file exists (only mocks file found)

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes with no issues
- [x] `flutter test` passes (all existing + updated tests)
- [x] No references to `BackgroundSyncCoordinator` in `audio_comment_repository_impl.dart`
- [x] No references to `PendingOperationsManager` in `audio_comment_repository_impl.dart`
- [x] No references to `AudioCommentOperationExecutor` anywhere in codebase (except git history)
- [x] `audio_comment_operation_executor.dart` file deleted
- [x] `audio_comment_incremental_sync_service.dart` file deleted
- [x] `audio_comment_operation_executor_test.mocks.dart` file deleted
- [x] `OperationExecutorFactory` only supports `track_version`
- [x] `SyncCoordinator` has no `audio_comments` references

#### Manual Verification:
- [ ] Add a text comment → appears immediately in UI, persists after app restart
- [ ] Add an audio comment → audio uploads, comment appears with playback
- [ ] Delete a comment → disappears immediately from UI
- [ ] Delete a track version with comments → all comments removed
- [ ] Delete a track with multiple versions → all comments for all versions removed
- [ ] Kill network, add comment → rollback occurs, comment removed from UI, error shown
- [ ] Kill network, delete comment → rollback occurs, comment reappears in UI
- [ ] Open version with comments → local data shown instantly, then revalidated from remote
- [ ] Recent comments on dashboard still work correctly

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful.

---

## Testing Strategy

### Unit Tests:
- `operation_executor_factory_test.dart` updated to reflect removed entity types
- Verify factory only supports `track_version`

### Integration Tests:
- Audio comment add/delete flows should work end-to-end
- No regressions in existing comment functionality

### Manual Testing Steps:
1. Create text comment on a track version — verify instant UI, Firestore document created
2. Create audio comment — verify audio uploaded to Storage, Firestore doc has `audioStorageUrl`
3. Delete comment — verify soft delete in Firestore, comment gone from local
4. Delete version with comments — verify batch soft delete in Firestore
5. Airplane mode: create comment — verify rollback (comment disappears, error shown)
6. Airplane mode: delete comment — verify rollback (comment reappears)
7. Background revalidation: add comment directly in Firestore console → verify it appears in app after navigating to version

## References

- Migration pattern reference: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
- Notification migration: `docs/plans/2026-02-23-notifications-online-first-optimistic.md`
- Projects migration: `docs/plans/2026-02-20-projects-online-first-optimistic.md`
- Current executor (to be deleted): `lib/core/sync/domain/executors/audio_comment_operation_executor.dart`
- Remote datasource: `lib/features/audio_comment/data/datasources/audio_comment_remote_datasource.dart`
- Local datasource: `lib/features/audio_comment/data/datasources/audio_comment_local_datasource.dart`
