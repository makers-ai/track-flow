# Restore Incremental Sync Services - Implementation Plan

## Overview

Replace the current stale-while-revalidate (SWR) fetching pattern with the original Incremental Sync architecture from `track_flow_bk`. This affects 8 entity types. The write flow (online-first optimistic + rollback) remains unchanged.

## Current State Analysis

**Current project:**
- `SyncCoordinator` only manages 2 entities: `notifications`, `track_versions`
- 4 repositories use `_revalidate*()` methods that do full remote fetches on every watch/read: Projects, AudioTrack, AudioComment, UserProfile
- `TrackVersionIncrementalSyncService` already exists and works correctly
- `NotificationIncrementalSyncService` exists as a stub (no-op)
- All remote datasources already have `getModifiedSince()` methods ready

**Backup project (source of truth):**
- `SyncCoordinator` manages all 8 entity types with full service registry
- Repositories return local Isar streams WITHOUT triggering revalidation
- All 8 IncrementalSyncServices handle downstream pulling

### Key Discoveries:
- Remote datasources already have `ModifiedSince` methods: `project_remote_data_source.dart`, `audio_track_remote_datasource.dart`, `audio_comment_remote_datasource.dart`, `track_version_remote_datasource.dart`, `user_profile_remote_datasource.dart`
- `BackgroundSyncCoordinatorImpl` is nearly identical in both projects - only `SyncCoordinator` and service registration differ
- The `IncrementalSyncService<T>` abstract class and `IncrementalSyncResult<T>` value object already exist in current project

## Desired End State

- All 8 entities use IncrementalSyncService for downstream data fetching
- SyncCoordinator orchestrates all 8 services with SharedPreferences cursor tracking
- Repositories return local Isar streams without triggering revalidation
- Write flow remains online-first optimistic with rollback (unchanged)
- No revalidation-based full-fetch methods remain in repositories

### Verification:
- `flutter analyze` passes with no errors
- `flutter packages pub run build_runner build --delete-conflicting-outputs` succeeds
- All sync services are registered in DI and resolvable
- Repositories compile without revalidation methods
- Watch methods return local streams only

## What We're NOT Doing

- NOT changing the write/mutation flow (stays optimistic + rollback)
- NOT introducing queue-based offline system or PendingOperationsManager changes
- NOT adding operation executors
- NOT touching Playlist (out of scope)
- NOT touching Invitation (out of scope)
- NOT redesigning sync logic (faithful copy from backup)
- NOT modifying remote datasource `ModifiedSince` methods (they already exist)

## Implementation Approach

Copy the 6 missing IncrementalSyncService implementations from `track_flow_bk`, update the SyncCoordinator to register all 8 services, remove revalidation methods from repositories, and regenerate DI. Each phase is independently verifiable.

---

## Phase 1: Create 6 New IncrementalSyncService Files

### Overview
Copy the 6 missing sync service implementations from `track_flow_bk`. These are the core of the incremental sync architecture.

### Changes Required:

#### 1. ProjectIncrementalSyncService
**File**: `lib/features/projects/data/services/project_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/projects/data/services/project_incremental_sync_service.dart`
**DI**: `@LazySingleton(as: IncrementalSyncService<ProjectDTO>)`
**Dependencies**: `ProjectRemoteDataSource`, `ProjectsLocalDataSource`
**Key behavior**:
- `performIncrementalSync()`: calls `_remoteDataSource.getUserProjectsModifiedSince()`, separates active/deleted, updates local cache
- `performFullSync()`: calls `_remoteDataSource.getUserProjects()`, clears and replaces local cache
- `_updateLocalCache()`: upserts modified projects, removes deleted ones

#### 2. AudioTrackIncrementalSyncService
**File**: `lib/features/audio_track/data/services/audio_track_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/audio_track/data/services/audio_track_incremental_sync_service.dart`
**DI**: `@LazySingleton(as: IncrementalSyncService<AudioTrackDTO>)`
**Dependencies**: `AudioTrackRemoteDataSource`, `AudioTrackLocalDataSource`, `ProjectsLocalDataSource`
**Key behavior**:
- Derives project IDs from `_projectsLocalDataSource.getAllProjects()`
- `performIncrementalSync()`: calls `_remoteDataSource.getAudioTracksModifiedSince()` with project IDs
- Computes next cursor from max `lastModified` across returned items
- Does NOT advance cursor when there are no changes

#### 3. AudioCommentIncrementalSyncService
**File**: `lib/features/audio_comment/data/services/audio_comment_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/audio_comment/data/services/audio_comment_incremental_sync_service.dart`
**DI**: `@LazySingleton(as: IncrementalSyncService<AudioCommentDTO>)`
**Dependencies**: `AudioCommentRemoteDataSource`, `AudioCommentLocalDataSource`, `TrackVersionLocalDataSource`
**Key behavior**:
- Derives version IDs from `_versionLocalDataSource.getAllVersions()`
- `performIncrementalSync()`: calls `_remoteDataSource.getCommentsModifiedSince()` with version IDs
- `performFullSync()`: delegates to `performIncrementalSync()` with epoch-0 cursor

#### 4. WaveformIncrementalSyncService
**File**: `lib/features/waveform/data/services/waveform_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/waveform/data/services/waveform_incremental_sync_service.dart`
**DI**: `@LazySingleton()` (registered as concrete class, not interface - uses `dynamic` type parameter)
**Dependencies**: `TrackVersionLocalDataSource`, `WaveformLocalDataSource`, `WaveformRemoteDataSource`
**Key behavior**:
- Derived from track versions - no standalone `ModifiedSince` query
- Iterates local versions, checks if waveform exists locally, fetches remote canonical if missing
- `performFullSync()`: delegates to `performIncrementalSync()` with epoch-0

#### 5. UserProfileIncrementalSyncService
**File**: `lib/features/user_profile/data/services/user_profile_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/user_profile/data/services/user_profile_incremental_sync_service.dart`
**DI**: `@LazySingleton(as: IncrementalSyncService<UserProfileDTO>)`
**Dependencies**: `UserProfileRemoteDataSource`, `UserProfileLocalDataSource`
**Key behavior**:
- Special case: only syncs current user's profile (0 or 1 item)
- `getModifiedSince()`: compares remote vs local `updatedAt` timestamps
- `performFullSync()`: fetches remote profile and caches it

#### 6. UserProfileCollaboratorIncrementalSyncService
**File**: `lib/features/user_profile/data/services/user_profile_collaborator_incremental_sync_service.dart` (NEW)
**Source**: `track_flow_bk/lib/features/user_profile/data/services/user_profile_collaborator_incremental_sync_service.dart`
**DI**: `@lazySingleton` (registered as concrete class, not interface)
**Dependencies**: `UserProfileRemoteDataSource`, `UserProfileLocalDataSource`, `ProjectsLocalDataSource`
**Key behavior**:
- Derives collaborator IDs from local projects' `collaboratorIds`
- `performIncrementalSync()`: delegates to `performFullSync()` (collaborators are derived, not timestamp-based)
- `performFullSync()`: fetches all profiles for current collaborator IDs via `_remoteDataSource.getUserProfilesByIds()`

### Success Criteria:

#### Automated Verification:
- [x] All 6 new files exist in correct paths
- [x] `flutter analyze` has no errors related to new files
- [x] DI annotation is correct on each service

---

## Phase 2: Update SyncCoordinator

### Overview
Replace the current 2-entity SyncCoordinator with the backup's 8-entity version. This is the central orchestration point.

### Changes Required:

#### 1. SyncCoordinator
**File**: `lib/core/sync/domain/services/sync_coordinator.dart`
**Changes**: Replace entire content with backup version

Key changes from current to backup:
- Add 6 new SharedPreferences keys: `projects_last_sync`, `tracks_last_sync`, `comments_last_sync`, `user_profile_last_sync`, `collaborators_last_sync`, `waveforms_last_sync`
- Add 6 new service registry keys: `projects`, `audio_tracks`, `audio_comments`, `user_profile`, `collaborators`, `waveforms`
- Update `_getServiceByKey()` switch to resolve all 8 services from DI
- Update `pullStartupData()` to sync: `user_profile` (full), `projects` (incremental), `collaborators` (incremental)
- Update `pullAllData()` to sync all 8 entities in order: projects, audio_tracks, audio_comments, user_profile, collaborators, notifications, track_versions, waveforms
- Update `_getServiceKeyForEntity()` and `_getSyncKeyForEntity()` to handle all 8 entity types
- Update `clearAllSyncKeys()` to clear all 8 keys
- Update `getSyncStatistics()` to list all 8 services
- Add imports for: `ProjectDTO`, `AudioTrackDTO`, `AudioCommentDTO`, `UserProfileDTO`, `UserProfileCollaboratorIncrementalSyncService`, `WaveformIncrementalSyncService`

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes
- [x] SyncCoordinator resolves all 8 services

---

## Phase 3: Remove Revalidation from Repositories

### Overview
Remove `_revalidate*()` methods and their call sites from 4 repositories. Watch/read methods will return local streams only - sync coordinator handles data population.

### Changes Required:

#### 1. ProjectsRepositoryImpl
**File**: `lib/features/projects/data/repositories/projects_repository_impl.dart`
**Changes**:
- Remove `_revalidateProjects(String userId)` method (lines ~176-198)
- Remove `_revalidateProject(String projectId)` method (lines ~201-219)
- Remove `unawaited(_revalidateProjects(...))` call in `watchLocalProjects()` (line ~130)
- Remove `unawaited(_revalidateProject(...))` call in `watchProjectById()` (line ~148)
- Remove `unawaited(_revalidateProject(...))` call in `getProjectById()` (line ~108)
- In `getProjectById()`: keep the fallback that fetches from remote when not in local cache (this is not revalidation, it's cache-miss handling)
- Remove unused imports if any (`dart:async` for `unawaited` may still be needed for mutations)

#### 2. AudioTrackRepositoryImpl
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
**Changes**:
- Remove `_revalidateTracksByProject(String projectId)` method (lines ~269-289)
- Remove `unawaited(_revalidateTracksByProject(...))` call in `watchTracksByProject()` (line ~206)

#### 3. AudioCommentRepositoryImpl
**File**: `lib/features/audio_comment/data/repositories/audio_comment_repository_impl.dart`
**Changes**:
- Remove `_revalidateCommentsByVersion(String versionId)` method (lines ~367-382)
- Remove `unawaited(_revalidateCommentsByVersion(...))` call in `watchCommentsByVersion()` (line ~306)

#### 4. UserProfileRepositoryImpl
**File**: `lib/features/user_profile/data/repositories/user_profile_repository_impl.dart`
**Changes**:
- Remove `_revalidateProfileFromRemote(String userId)` method (lines ~188-208)
- Remove `_revalidateProfileFromRemote(userId.value)` call in `getUserProfile()` (line ~30)

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` passes
- [x] No `_revalidate` references remain in target repositories
- [x] All watch methods still return Isar streams
- [x] All mutation methods still use optimistic + rollback pattern (unchanged)

---

## Phase 4: Regenerate DI and Verify Compilation

### Overview
Run build_runner to regenerate `injection.config.dart` with the new sync service registrations, then verify everything compiles.

### Changes Required:

#### 1. Regenerate DI
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

This will:
- Register `ProjectIncrementalSyncService` as `IncrementalSyncService<ProjectDTO>`
- Register `AudioTrackIncrementalSyncService` as `IncrementalSyncService<AudioTrackDTO>`
- Register `AudioCommentIncrementalSyncService` as `IncrementalSyncService<AudioCommentDTO>`
- Register `WaveformIncrementalSyncService` as concrete singleton
- Register `UserProfileIncrementalSyncService` as `IncrementalSyncService<UserProfileDTO>`
- Register `UserProfileCollaboratorIncrementalSyncService` as concrete singleton

#### 2. Verify compilation
```bash
flutter analyze
```

### Success Criteria:

#### Automated Verification:
- [x] `build_runner` completes without errors
- [x] `flutter analyze` passes with no errors
- [x] `injection.config.dart` contains all 8 sync service registrations
- [x] No revalidation methods remain in target repositories (grep check)

#### Manual Verification:
- [ ] App starts without DI resolution errors
- [ ] Startup sync triggers user_profile, projects, collaborators
- [ ] Foreground sync triggers audio_tracks, track_versions, audio_comments, waveforms
- [ ] Full sync triggers all 8 entity types
- [ ] Watch streams still emit data from local cache
- [ ] Mutations still work (create, update, delete) with optimistic + rollback
- [ ] Sync logs appear in console showing incremental fetches

---

## Summary of All Files Changed

### New Files (6):
1. `lib/features/projects/data/services/project_incremental_sync_service.dart`
2. `lib/features/audio_track/data/services/audio_track_incremental_sync_service.dart`
3. `lib/features/audio_comment/data/services/audio_comment_incremental_sync_service.dart`
4. `lib/features/waveform/data/services/waveform_incremental_sync_service.dart`
5. `lib/features/user_profile/data/services/user_profile_incremental_sync_service.dart`
6. `lib/features/user_profile/data/services/user_profile_collaborator_incremental_sync_service.dart`

### Modified Files (5):
1. `lib/core/sync/domain/services/sync_coordinator.dart` - Full replacement with 8-entity version
2. `lib/features/projects/data/repositories/projects_repository_impl.dart` - Remove revalidation
3. `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart` - Remove revalidation
4. `lib/features/audio_comment/data/repositories/audio_comment_repository_impl.dart` - Remove revalidation
5. `lib/features/user_profile/data/repositories/user_profile_repository_impl.dart` - Remove revalidation

### Auto-Generated (1):
1. `lib/core/di/injection.config.dart` - Regenerated by build_runner

## Confirmation Checklist

- [x] Incremental sync fully replaces revalidation for all 8 entities
- [x] Optimistic online-first mutations remain intact (unchanged)
- [x] No executor pattern exists in mutation flow
- [x] No queue-based offline system introduced
- [x] No revalidation-based full-fetch calls remain in repositories
- [x] All 8 IncrementalSyncServices are registered and functional
- [x] SyncCoordinator orchestrates all 8 entity types
- [x] Project compiles successfully

## References

- Backup project: `/Users/yohanangulo/Documents/dev/flutter_projects/track_flow_bk/`
- Base sync class: `lib/core/sync/domain/services/incremental_sync_service.dart`
- Sync result VO: `lib/core/sync/domain/value_objects/incremental_sync_result.dart`
- Current sync coordinator: `lib/core/sync/domain/services/sync_coordinator.dart`
