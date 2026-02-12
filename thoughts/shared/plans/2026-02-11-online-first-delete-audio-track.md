# Online-First Optimistic Delete Audio Track - Implementation Plan

## Overview

Migrate `DeleteAudioTrack` use case from offline-first (local delete → queue sync → background push) to **online-first optimistic** (local delete immediately for instant UX → Firebase hard delete → rollback local on failure). This is part of the progressive removal of offline-first complexity from the app.

## Current State Analysis

### How it works now (offline-first):
1. `DeleteAudioTrack` use case calls `ProjectTrackService.deleteTrack()`
2. Service validates permissions, then calls `AudioTrackRepository.deleteTrack()`
3. `AudioTrackRepositoryImpl.deleteTrack()` (line 170):
   - Reads track from Isar (to capture data for sync payload)
   - **Deletes from Isar first** (line 187)
   - Queues a `PendingOperation` with all track metadata (line 190)
   - Triggers `BackgroundSyncCoordinator.pushUpstream()` fire-and-forget (line 219)
4. Eventually, `AudioTrackOperationExecutor` processes the queue and does a **soft delete** (`isDeleted: true`) in Firestore via `updateTrack()`

### Problems:
- Complex: involves pending operations queue, sync coordinator, operation executor
- Soft delete leaves orphan documents in Firestore
- Permission validation happens **after** related resources are cleaned up in the use case
- No rollback if local delete succeeds but queue fails

### Online-first patterns already established:
- `createTrackOnline` (`audio_track_repository_impl.dart:373`)
- `setActiveVersionOnline` (`audio_track_repository_impl.dart:394`)
- Both follow: remote first → fold → on success, update local cache

## Desired End State

`DeleteAudioTrack` use case calls a new `deleteTrackOnline` method that:
1. Saves track data in memory (for potential rollback)
2. **Deletes from local cache immediately** (optimistic — user sees instant feedback)
3. **Hard deletes** the Firestore document
4. If Firebase fails → **restores the track to local cache** (rollback)
5. No sync queue, no pending operations, no background coordinator involved

### Flow diagram:
```
track = localDataSource.getTrackById(id)   // save for rollback
localDataSource.deleteTrack(id)            // optimistic delete → UI updates
remoteDataSource.deleteAudioTrack(id)      // hard delete Firebase
  ├─ success → return Right(unit)
  └─ failure → localDataSource.cacheTrack(track)  // rollback
              return Left(failure)
```

### Verification:
- Deleting a track makes it disappear from UI immediately
- Firestore document is hard deleted (not soft delete)
- If Firebase fails, track reappears in UI (rollback)
- Existing tests pass after mock regeneration

## What We're NOT Doing

- Migrating version delete, comment delete, waveform delete, or cache delete to online-first (those are separate steps)
- Removing the offline-first `deleteTrack` method yet (will be deprecated, removed later)
- Changing the `deleteAudioTrack` remote datasource contract signature (it already exists and returns `Either<Failure, Unit>`)
- Modifying the use case orchestration order (steps 1-3 stay the same, only step 4 changes)

## Implementation Approach

Optimistic delete pattern: delete locally first for instant UX, then confirm with Firebase, rollback on failure.

---

## Phase 1: Change Remote Datasource to Hard Delete

### Overview
Modify `deleteAudioTrack` in the remote datasource to perform a Firestore document `.delete()` instead of `.update({'isDeleted': true})`.

### Changes Required:

#### 1. Remote Datasource Implementation
**File**: `lib/features/audio_track/data/datasources/audio_track_remote_datasource.dart`
**Lines**: 65-78

Replace the soft delete with a hard delete:

```dart
@override
Future<Either<Failure, Unit>> deleteAudioTrack(String trackId) async {
  try {
    await _firestore
        .collection(AudioTrackDTO.collection)
        .doc(trackId)
        .delete();

    return const Right(unit);
  } catch (e) {
    return Left(
      ServerFailure('Error deleting audio track: $e'),
    );
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes with no new warnings

---

## Phase 2: Add `deleteTrackOnline` to Repository

### Overview
Add the optimistic online-first delete method to the repository contract and implementation.

### Changes Required:

#### 1. Repository Contract
**File**: `lib/features/audio_track/domain/repositories/audio_track_repository.dart`

Add new method to the abstract class:

```dart
/// Deletes a track using optimistic online-first approach.
/// Removes from local cache immediately for instant UX, then hard deletes
/// from Firestore. Rolls back local cache if remote deletion fails.
Future<Either<Failure, Unit>> deleteTrackOnline(AudioTrackId trackId);
```

#### 2. Repository Implementation
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`

Add new method:

```dart
@override
Future<Either<Failure, Unit>> deleteTrackOnline(AudioTrackId trackId) async {
  try {
    // 1. Get track data before deletion (for rollback if remote fails)
    final trackResult = await localDataSource.getTrackById(trackId.value);
    final trackDto = trackResult.fold((_) => null, (dto) => dto);

    if (trackDto == null) {
      return Left(DatabaseFailure('Track not found: ${trackId.value}'));
    }

    // 2. Optimistic delete: remove from local cache immediately
    await localDataSource.deleteTrack(trackId.value);

    // 3. Hard delete from Firestore
    final remoteResult = await remoteDataSource.deleteAudioTrack(trackId.value);

    return remoteResult.fold(
      (failure) {
        // 4. Rollback: restore track in local cache
        localDataSource.cacheTrack(trackDto);
        return Left(failure);
      },
      (_) => const Right(unit),
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to delete track online: $e'));
  }
}
```

#### 3. Deprecate old method
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`

Add `@Deprecated` annotation to the existing `deleteTrack` method (line 169):

```dart
@Deprecated('Use deleteTrackOnline instead for online-first delete flow')
@override
Future<Either<Failure, Unit>> deleteTrack(
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes with no new errors

---

## Phase 3: Connect Service to Online-First Delete

### Overview
Update `ProjectTrackService` to use the new `deleteTrackOnline`.

### Changes Required:

#### 1. Domain Service
**File**: `lib/features/audio_track/domain/services/project_track_service.dart`
**Lines**: 91-110 (`deleteTrack` method)

Change the repository call at line 107 from `deleteTrack` to `deleteTrackOnline`:

```dart
Future<Either<Failure, Unit>> deleteTrack({
  required Project project,
  required UserId requester,
  required AudioTrackId trackId,
}) async {
  // 1. Verify user permissions
  final collaborator = project.collaborators.firstWhere(
    (c) => c.userId == requester,
    orElse: () => throw UserNotCollaboratorException(),
  );

  if (!collaborator.hasPermission(ProjectPermission.deleteTrack)) {
    return Left(ProjectPermissionException());
  }

  // 2. Optimistic hard delete (local first for UX, then Firebase, rollback on failure)
  final deleteResult = await trackRepository.deleteTrackOnline(trackId);

  return deleteResult.fold((failure) => Left(failure), (_) => Right(unit));
}
```

Note: `projectId` is no longer needed for the repository call since `deleteTrackOnline` only needs `trackId`. The service signature stays the same for backward compatibility with the use case.

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes
- [x] `flutter packages pub run build_runner build --delete-conflicting-outputs` completes
- [x] `flutter test` passes (after mock regeneration in Phase 4)

---

## Phase 4: Regenerate Mocks

### Overview
Since the `AudioTrackRepository` contract changed (new method), mocks need regeneration.

### Command:
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

### Files affected:
- `test/features/audio_track/domain/usecases/delete_audio_track_usecase_test.mocks.dart`
- `test/features/audio_track/domain/usecases/download_track_usecase_test.mocks.dart`
- `test/features/audio_track/domain/usecases/upload_track_cover_art_usecase_test.mocks.dart`
- `test/features/projects/domain/usecases/delete_project_usecase_test.mocks.dart`
- Any other test that mocks `AudioTrackRepository`

### Success Criteria:

#### Automated Verification:
- [x] `flutter packages pub run build_runner build --delete-conflicting-outputs` completes without errors
- [x] `flutter test` passes

---

## Testing Strategy

### Unit Tests:
- Verify `deleteTrackOnline` deletes locally first (optimistic)
- Verify remote success returns `Right(unit)` with track gone from both local and remote
- Verify remote failure triggers rollback (track restored in local cache)
- Verify `ProjectTrackService.deleteTrack` still validates permissions before calling repository

### Manual Testing:
1. Delete a track → confirm it disappears from UI immediately
2. Confirm Firestore document is hard deleted (not `isDeleted: true`)
3. Simulate network failure → confirm track reappears in UI after rollback
4. Verify no pending operations are created in the sync queue

## Edge Cases

- **Track not found locally**: Returns `DatabaseFailure` early, no remote call made.
- **Rollback `cacheTrack` fails**: Caught by outer try-catch, returns `DatabaseFailure`. Track would be missing locally but still in Firebase; next sync restores it.

## References

- Existing online-first pattern: `audio_track_repository_impl.dart:373` (`createTrackOnline`)
- Remote datasource: `audio_track_remote_datasource.dart:65` (`deleteAudioTrack`)
- Use case: `delete_audio_track_usecase.dart:124` (entry point for this change)
- Service: `project_track_service.dart:91` (`deleteTrack`)
