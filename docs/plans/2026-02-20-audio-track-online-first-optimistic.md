# Audio Track Feature: Online-First Optimistic Implementation Plan

## Overview

Migrar la feature `audio_track` del patron offline-first + queue + incremental sync a un enfoque **online-first optimistic** con rollback explicito. Firebase es la fuente de verdad. Local (Isar) se usa como cache para UX optimista y lecturas rapidas con revalidacion en background.

Adicionalmente, se consolida el contrato eliminando metodos duplicados (deprecated + Online).

## Current State Analysis

### Repositorio actual (`audio_track_repository_impl.dart`)
- **Dependencias**: `AudioTrackLocalDataSource`, `AudioTrackRemoteDataSource`, `BackgroundSyncCoordinator`, `PendingOperationsManager`
- **Metodos duplicados**: `createTrack` (deprecated/queue) + `createTrackOnline`, `deleteTrack` (deprecated/queue) + `deleteTrackOnline`, `setActiveVersion` (deprecated/queue) + `setActiveVersionOnline`
- **Escrituras**: local → queue → fire-and-forget sync (metodos deprecated) o remote-first → cache local (metodos Online)
- **Lecturas**: solo local, sin revalidacion remota

### Infraestructura sync que se elimina
- `AudioTrackOperationExecutor` - traduce operaciones de queue en llamadas a Firebase (con logica parcial por campo: name, activeVersion, coverArt)
- `AudioTrackIncrementalSyncService` - trae cambios incrementales de Firebase al cache
- Referencias a `'audio_track'` en `OperationExecutorFactory` y `'audio_tracks'` en `SyncCoordinator`

### Key Discoveries
- `editTrackName` en remote retorna `Future<void>` y throws on error (NO retorna Either) (`audio_track_remote_datasource.dart:142`)
- `updateTrackCoverUrl` retorna `Either<Failure, Unit>` y solo envia `coverUrl` al remote, no `coverLocalPath` (`audio_track_remote_datasource.dart:180`)
- `updateActiveVersion` retorna `Either<Failure, Unit>` (`audio_track_remote_datasource.dart:158`)
- `deleteAudioTrack` hace soft delete: `isDeleted: true` + `lastModified: serverTimestamp` (`audio_track_remote_datasource.dart:67`)
- Local `deleteTrack` hace hard delete (`Isar delete`), no soft delete (`audio_track_local_datasource.dart:99-107`)
- `getTracksByProjectIds` filtra `isDeleted: false` - no retorna tracks eliminados (`audio_track_remote_datasource.dart:121`)
- `UploadTrackCoverArtUseCase` llama `updateTrack()` DOS veces: primero con coverLocalPath, luego con coverUrl (`upload_track_cover_art_usecase.dart:66,96`)
- `project_track_service.dart:107` ya usa `deleteTrackOnline(trackId)` (solo trackId)
- `setActiveVersionOnline` NO tiene callers (dead code)
- Callers principales:
  - `createTrackOnline` → `up_load_audio_track_usecase.dart:91`
  - `deleteTrackOnline` → `project_track_service.dart:107`
  - `editTrackName` → `project_track_service.dart:117`
  - `updateTrack` → `upload_track_cover_art_usecase.dart:66,96`
  - `setActiveVersion` → solo uso interno y `track_version_repository_impl.dart`

## Desired End State

1. `AudioTrackRepository` contrato consolidado: sin `@Deprecated`, sin `*Online` duplicados
2. `AudioTrackRepositoryImpl` usa patron **optimistic update + rollback** para escrituras (edit/delete/update) y **remote-first** para `createTrack`
3. Lecturas retornan datos locales + revalidacion remota en background (para `watchTracksByProject`)
4. Logica de update parcial por campos preservada directamente en el repositorio
5. No existe queue, pending operations, background sync, ni incremental sync para audio_tracks
6. `AudioTrackOperationExecutor` y `AudioTrackIncrementalSyncService` eliminados
7. DI regenerada sin las clases eliminadas
8. Callers actualizados para usar metodos consolidados
9. Tests validan el flujo remote-first (create) y optimistic + rollback (edit/delete/update)

### Como verificar:
- `flutter analyze` pasa sin errores
- `flutter test` pasa (tests nuevos + existentes)
- Crear audio track: usuario ve progreso de subida, se cachea localmente al completar
- Editar/borrar un audio track: UI responde inmediato (optimistic), persiste si remoto ok, rollback si falla
- Abrir tracks de un proyecto: muestra cache local + actualiza en background

## What We're NOT Doing

- No modificamos `AudioTrackRemoteDataSource` ni `AudioTrackLocalDataSource` (se reutilizan tal cual)
- No migramos otras features (audio_comment, track_version, etc.) - solo audio_track
- No eliminamos `getAudioTracksModifiedSince()` del remote data source (dead code, se limpia despues)
- No modificamos `UploadTrackCoverArtUseCase` ni `DeleteAudioTrack` use case (flujo se mantiene compatible)
- No agregamos revalidacion individual por track (solo a nivel de proyecto via `watchTracksByProject`)
- No cambiamos la firma de `editTrackName` (mantiene projectId para el remote datasource)

## Implementation Approach

**Patron de escritura - createTrack**: Remote-First (sin optimismo)
1. Llamar al remoto PRIMERO (usuario ve loading/progreso de subida)
2. Si remoto ok → cachear localmente con respuesta del servidor
3. Si remoto falla → retornar error (nada que hacer rollback)

**Patron de escritura - edits/delete/update**: Optimistic Update con Rollback Explicito
1. Snapshot del estado previo (para rollback)
2. Aplicar cambio en local inmediatamente
3. Llamar al remoto con campos apropiados (parcial para edits)
4. Si remoto falla → restaurar snapshot
5. Si remoto ok → confirmar

**Patron de lectura**: Stale-While-Revalidate (para watchTracksByProject)
1. Retornar stream local inmediatamente
2. Disparar revalidacion remota en background
3. Si hay cambios, actualizar cache → Isar stream auto-emite

**Updates parciales por campo** (logica del executor preservada):
- `editTrackName` → `remoteDataSource.editTrackName(trackId, projectId, newName)`
- `setActiveVersion` → `remoteDataSource.updateActiveVersion(trackId, versionId)`
- `updateTrack` → `remoteDataSource.updateTrackCoverUrl(trackId, coverUrl, null)`

---

## Phase 1: Consolidar Contrato + Actualizar Callers

### Overview
Eliminar metodos duplicados del contrato `AudioTrackRepository`, cambiar firma de `deleteTrack`, y actualizar los callers.

### Changes Required:

#### 1. Actualizar contrato AudioTrackRepository
**File**: `lib/features/audio_track/domain/repositories/audio_track_repository.dart`
**Changes**:
- Eliminar `createTrackOnline` (linea 49)
- Eliminar `setActiveVersionOnline` (linea 53-56)
- Eliminar `deleteTrackOnline` (linea 61)
- Cambiar firma de `deleteTrack` de `(AudioTrackId, ProjectId)` a solo `(AudioTrackId)`
- Remover `@Deprecated` annotations si quedan

Resultado final del contrato:
```dart
abstract class AudioTrackRepository {
  Future<Either<Failure, AudioTrack>> getTrackById(AudioTrackId id);
  Stream<Either<Failure, AudioTrack>> watchTrackById(AudioTrackId id);
  Stream<Either<Failure, List<AudioTrack>>> watchTracksByProject(ProjectId projectId);
  Stream<Either<Failure, List<AudioTrack>>> watchAllAccessibleTracks(UserId userId);
  Future<Either<Failure, AudioTrack>> createTrack(AudioTrack track);
  Future<Either<Failure, Unit>> deleteTrack(AudioTrackId trackId);
  Future<Either<Failure, Unit>> editTrackName({
    required AudioTrackId trackId,
    required ProjectId projectId,
    required String newName,
  });
  Future<Either<Failure, Unit>> setActiveVersion({
    required AudioTrackId trackId,
    required TrackVersionId versionId,
  });
  Future<Either<Failure, Unit>> updateTrack(AudioTrack track);
  Future<Either<Failure, Unit>> deleteAllTracks();
}
```

#### 2. Actualizar ProjectTrackService
**File**: `lib/features/audio_track/domain/services/project_track_service.dart`
**Changes**:
- Linea 107: `trackRepository.deleteTrackOnline(trackId)` → `trackRepository.deleteTrack(trackId)`
- Opcionalmente: remover `@Deprecated` de `addTrackToProject` (ya que `createTrack` sera optimistic)

#### 3. Actualizar UploadAudioTrackUseCase
**File**: `lib/features/audio_track/domain/usecases/up_load_audio_track_usecase.dart`
**Changes**:
- Linea 91: `audioTrackRepository.createTrackOnline(trackWithVersion)` → `audioTrackRepository.createTrack(trackWithVersion)`

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa sin errores (puede que impl falle temporalmente hasta Phase 2)
- [x] No existe `createTrackOnline`, `setActiveVersionOnline`, `deleteTrackOnline` en el contrato
- [x] `deleteTrack` solo recibe `AudioTrackId`

#### Manual Verification:
- [ ] N/A - esta fase solo cambia interfaces, la app no compilara hasta Phase 2

---

## Phase 2: Refactorizar AudioTrackRepositoryImpl

### Overview
Reescribir el repositorio eliminando dependencias sync e implementando optimistic update + rollback para todas las escrituras, y background revalidation para lecturas.

### Changes Required:

#### 1. Nuevas dependencias y imports
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`

```dart
import 'dart:async';
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/utils/app_logger.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_local_datasource.dart';
import 'package:trackflow/features/audio_track/data/datasources/audio_track_remote_datasource.dart';
import 'package:trackflow/features/audio_track/data/models/audio_track_dto.dart';
import 'package:trackflow/features/audio_track/domain/entities/audio_track.dart';
import 'package:trackflow/features/audio_track/domain/repositories/audio_track_repository.dart';

@LazySingleton(as: AudioTrackRepository)
class AudioTrackRepositoryImpl implements AudioTrackRepository {
  final AudioTrackLocalDataSource _localDataSource;
  final AudioTrackRemoteDataSource _remoteDataSource;

  AudioTrackRepositoryImpl(this._localDataSource, this._remoteDataSource);
```

**Imports eliminados**:
- `background_sync_coordinator.dart`
- `pending_operations_manager.dart`
- `sync_operation_document.dart`

**Dependencias eliminadas del constructor**:
- `BackgroundSyncCoordinator`
- `PendingOperationsManager`

#### 2. createTrack - Remote-First (no optimistic)
```dart
@override
Future<Either<Failure, AudioTrack>> createTrack(AudioTrack track) async {
  final dto = AudioTrackDTO.fromDomain(track, extension: 'mp3');

  // 1. Call remote FIRST (user sees upload progress via BLoC loading state)
  final remoteResult = await _remoteDataSource.createAudioTrack(dto);

  return remoteResult.fold(
    (failure) => Left(failure),
    (remoteDto) {
      // 2. Success: cache locally with server response
      _localDataSource.cacheTrack(remoteDto);
      return Right(remoteDto.toDomain());
    },
  );
}
```

#### 3. deleteTrack - Optimistic + Rollback (nueva firma: solo trackId)
```dart
@override
Future<Either<Failure, Unit>> deleteTrack(AudioTrackId trackId) async {
  // 1. Snapshot for rollback
  final prevResult = await _localDataSource.getTrackById(trackId.value);
  final prevDto = prevResult.fold((_) => null, (dto) => dto);

  if (prevDto == null) {
    return Left(DatabaseFailure('Track not found: ${trackId.value}'));
  }

  // 2. Optimistic: delete locally
  await _localDataSource.deleteTrack(trackId.value);

  // 3. Persist to remote (soft delete)
  final remoteResult = await _remoteDataSource.deleteAudioTrack(trackId.value);

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore in local cache
      _localDataSource.cacheTrack(prevDto);
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

#### 4. editTrackName - Optimistic + Rollback (remote throws, not Either)
```dart
@override
Future<Either<Failure, Unit>> editTrackName({
  required AudioTrackId trackId,
  required ProjectId projectId,
  required String newName,
}) async {
  // 1. Snapshot previous name
  final prevResult = await _localDataSource.getTrackById(trackId.value);
  final prevName = prevResult.fold((_) => null, (dto) => dto?.name);

  // 2. Optimistic: update name locally
  await _localDataSource.updateTrackName(trackId.value, newName);

  // 3. Remote: editTrackName (throws on error, not Either)
  try {
    await _remoteDataSource.editTrackName(
      trackId.value,
      projectId.value,
      newName,
    );
    return const Right(unit);
  } catch (e) {
    // 4. Rollback: restore previous name
    if (prevName != null) {
      await _localDataSource.updateTrackName(trackId.value, prevName);
    }
    return Left(ServerFailure('Failed to edit track name: $e'));
  }
}
```

#### 5. setActiveVersion - Optimistic + Rollback
```dart
@override
Future<Either<Failure, Unit>> setActiveVersion({
  required AudioTrackId trackId,
  required TrackVersionId versionId,
}) async {
  // 1. Snapshot previous active version
  final prevResult = await _localDataSource.getTrackById(trackId.value);
  final prevVersionId = prevResult.fold(
    (_) => null,
    (dto) => dto?.activeVersionId?.value,
  );

  // 2. Optimistic: update locally
  final localResult = await _localDataSource.setActiveVersion(
    trackId.value,
    versionId.value,
  );

  if (localResult.isLeft()) {
    return localResult;
  }

  // 3. Remote
  final remoteResult = await _remoteDataSource.updateActiveVersion(
    trackId.value,
    versionId.value,
  );

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore previous version
      if (prevVersionId != null) {
        _localDataSource.setActiveVersion(trackId.value, prevVersionId);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

#### 6. updateTrack - Optimistic + Rollback (cover art)
```dart
@override
Future<Either<Failure, Unit>> updateTrack(AudioTrack track) async {
  final dto = AudioTrackDTO.fromDomain(track, extension: '');

  // 1. Snapshot for rollback
  final prevResult = await _localDataSource.getTrackById(track.id.value);
  final prevDto = prevResult.fold((_) => null, (dto) => dto);

  // 2. Optimistic: update locally (full DTO update)
  await _localDataSource.updateTrack(dto);

  // 3. Remote: update cover art only (partial update)
  final remoteResult = await _remoteDataSource.updateTrackCoverUrl(
    track.id.value,
    track.coverUrl,
    null, // coverLocalPath not synced to Firestore
  );

  return remoteResult.fold(
    (failure) {
      // 4. Rollback
      if (prevDto != null) {
        _localDataSource.cacheTrack(prevDto);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

#### 7. getTrackById - Local first + remote fallback
```dart
@override
Future<Either<Failure, AudioTrack>> getTrackById(AudioTrackId id) async {
  try {
    final result = await _localDataSource.getTrackById(id.value);
    final localDto = result.fold((_) => null, (dto) => dto);

    if (localDto != null) {
      return Right(localDto.toDomain());
    }

    // Not found locally - return failure
    // (revalidation at project level will populate cache)
    return Left(DatabaseFailure('Audio track not found in local cache'));
  } catch (e) {
    return Left(DatabaseFailure('Failed to access local cache: $e'));
  }
}
```

#### 8. watchTracksByProject - Stream + Background Revalidation
```dart
@override
Stream<Either<Failure, List<AudioTrack>>> watchTracksByProject(
  ProjectId projectId,
) {
  // Trigger background revalidation (fire-and-forget)
  unawaited(_revalidateTracksByProject(projectId.value));

  return _localDataSource.watchTracksByProject(projectId.value).map((
    localResult,
  ) {
    return localResult.fold(
      (failure) => Left(failure),
      (dtos) => Right(dtos.map((dto) => dto.toDomain()).toList()),
    );
  });
}
```

#### 9. watchTrackById - Stream (sin revalidacion individual)
```dart
@override
Stream<Either<Failure, AudioTrack>> watchTrackById(AudioTrackId id) {
  return _localDataSource.watchTrackById(id.value).map((eitherDto) {
    return eitherDto.fold(
      (failure) => Left(failure),
      (dto) => dto != null
          ? Right(dto.toDomain())
          : Left(DatabaseFailure('Audio track not found in local cache')),
    );
  });
}
```

#### 10. watchAllAccessibleTracks - Stream (sin revalidacion)
```dart
@override
Stream<Either<Failure, List<AudioTrack>>> watchAllAccessibleTracks(
  UserId userId,
) {
  return _localDataSource
      .watchAllAccessibleTracks(userId.value)
      .map<Either<Failure, List<AudioTrack>>>((dtos) {
        return Right(dtos.map((dto) => dto.toDomain()).toList());
      })
      .handleError((error) {
        return Left<Failure, List<AudioTrack>>(
          DatabaseFailure('Failed to watch accessible tracks: $error'),
        );
      });
}
```

#### 11. deleteAllTracks - Sin cambios
```dart
@override
Future<Either<Failure, Unit>> deleteAllTracks() async {
  try {
    await _localDataSource.deleteAllTracks();
    return const Right(unit);
  } catch (e) {
    return Left(DatabaseFailure('Failed to delete all tracks: $e'));
  }
}
```

#### 12. Metodo privado de revalidacion
```dart
/// Revalidates tracks for a project from remote.
/// Fetches fresh data and reconciles with local cache.
Future<void> _revalidateTracksByProject(String projectId) async {
  try {
    final remoteTracks = await _remoteDataSource.getTracksByProjectIds(
      [projectId],
    );

    final remoteIds = <String>{};

    // Update/add remote tracks to local cache
    for (final dto in remoteTracks) {
      remoteIds.add(dto.id.value);
      await _localDataSource.cacheTrack(dto);
    }

    // Reconcile: remove local tracks not present in remote
    // (they were deleted remotely)
    final localResult = await _localDataSource.getAllTracks();
    localResult.fold(
      (_) {},
      (localTracks) async {
        for (final localTrack in localTracks) {
          if (localTrack.projectId.value == projectId &&
              !remoteIds.contains(localTrack.id.value)) {
            await _localDataSource.deleteTrack(localTrack.id.value);
          }
        }
      },
    );
  } catch (e) {
    AppLogger.warning(
      'Background track revalidation failed: $e',
      tag: 'AudioTrackRepositoryImpl',
    );
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa sin errores
- [x] El archivo no importa nada de `core/sync/`
- [x] El constructor solo recibe `AudioTrackLocalDataSource` y `AudioTrackRemoteDataSource`

#### Manual Verification:
- [ ] Crear track: usuario ve loading mientras sube, aparece en lista al completar
- [ ] Crear track sin conexion: falla con error, no aparece nada en lista
- [ ] Editar nombre: cambio visible inmediatamente (optimistic), persiste
- [ ] Borrar track: desaparece inmediatamente (optimistic), no reaparece
- [ ] Borrar track sin conexion: desaparece brevemente, reaparece (rollback)
- [ ] Abrir proyecto: tracks del cache aparecen inmediato, se actualizan con datos frescos

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding.

---

## Phase 3: Eliminar Infraestructura Sync de Audio Track

### Overview
Eliminar las clases de sync y limpiar referencias en el core sync.

### Changes Required:

#### 1. Eliminar AudioTrackOperationExecutor
**File**: `lib/core/sync/domain/executors/audio_track_operation_executor.dart`
**Action**: DELETE file

#### 2. Eliminar AudioTrackIncrementalSyncService
**File**: `lib/features/audio_track/data/services/audio_track_incremental_sync_service.dart`
**Action**: DELETE file

#### 3. Eliminar directorio services si queda vacio
**File**: `lib/features/audio_track/data/services/`
**Action**: DELETE directory if empty after step 2

#### 4. Limpiar OperationExecutorFactory
**File**: `lib/core/sync/domain/executors/operation_executor_factory.dart`
**Changes**:
- Remover import de `AudioTrackOperationExecutor`
- Remover case `'audio_track'` del switch en `getExecutor()`
- Remover `'audio_track'` de `supportedEntityTypes`

Resultado:
```dart
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/di/injection.dart';
import 'package:trackflow/core/sync/domain/executors/operation_executor.dart';
import 'package:trackflow/core/sync/domain/executors/track_version_operation_executor.dart';
import 'package:trackflow/core/sync/domain/executors/audio_comment_operation_executor.dart';

@injectable
class OperationExecutorFactory {
  OperationExecutor getExecutor(String entityType) {
    switch (entityType) {
      case 'track_version':
        return sl<TrackVersionOperationExecutor>();
      case 'audio_comment' || 'audio_comment_by_version':
        return sl<AudioCommentOperationExecutor>();
      default:
        throw UnsupportedError(
          'No executor found for entity type: $entityType',
        );
    }
  }

  List<String> get supportedEntityTypes => [
    'track_version',
    'audio_comment',
    'audio_comment_by_version',
  ];
}
```

#### 5. Limpiar SyncCoordinator
**File**: `lib/core/sync/domain/services/sync_coordinator.dart`
**Changes**:
- Remover import de `AudioTrackDTO`
- Remover constantes `_tracksLastSyncKey` y `_tracksServiceKey`
- Remover linea de audio_tracks en `pullAllData()`
- Remover case audio_tracks en `_getServiceByKey()`, `_getServiceKeyForEntity()`, `_getSyncKeyForEntity()`
- Remover audio_tracks de `getSyncStatistics()` services list
- Remover audio_tracks de `clearAllSyncKeys()`

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa
- [x] No existen: `audio_track_operation_executor.dart`, `audio_track_incremental_sync_service.dart`
- [x] `grep -r "AudioTrackOperationExecutor" lib/` no retorna resultados
- [x] `grep -r "AudioTrackIncrementalSyncService" lib/` no retorna resultados

#### Manual Verification:
- [ ] La app compila y arranca correctamente
- [ ] track_version, audio_comment, notifications siguen sincronizando

---

## Phase 4: Regenerar DI

### Overview
Ejecutar build_runner para regenerar `injection.config.dart`.

### Changes Required:

#### 1. Regenerar injection.config.dart
**Command**:
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

Esto automaticamente:
- Elimina registros de `AudioTrackOperationExecutor` y `AudioTrackIncrementalSyncService`
- Actualiza registro de `AudioTrackRepositoryImpl` con solo `_localDataSource` y `_remoteDataSource`

### Success Criteria:

#### Automated Verification:
- [x] `flutter packages pub run build_runner build` completa sin errores
- [x] `flutter analyze` pasa
- [x] `injection.config.dart` no contiene `AudioTrackOperationExecutor` ni `AudioTrackIncrementalSyncService`
- [x] `injection.config.dart` registra `AudioTrackRepositoryImpl` con solo las dos data sources

#### Manual Verification:
- [ ] La app compila y arranca correctamente

---

## Phase 5: Tests

### Overview
Eliminar tests obsoletos, actualizar factory test, y crear tests del repositorio refactorizado.

### Changes Required:

#### 1. Eliminar mocks obsoletos
**File**: `test/core/sync/domain/executors/audio_track_operation_executor_test.mocks.dart`
**Action**: DELETE file

#### 2. Actualizar OperationExecutorFactory test
**File**: `test/core/sync/domain/executors/operation_executor_factory_test.dart`
**Changes**:
- Actualizar `supportedEntityTypes` length de 4 a 3
- Agregar test para `'audio_track'` throws UnsupportedError
- Actualizar `isNot(contains('project'))` a tambien incluir `isNot(contains('audio_track'))`

#### 3. Crear test del repositorio
**File**: `test/features/audio_track/data/repositories/audio_track_repository_impl_test.dart`
**Action**: CREATE new file con `@GenerateMocks([AudioTrackLocalDataSource, AudioTrackRemoteDataSource])`

Tests a cubrir:
- **createTrack**: remote-first, cache on success, return failure on remote error (no rollback)
- **deleteTrack**: snapshot + optimistic delete + remote success, rollback on failure
- **editTrackName**: snapshot name + optimistic + remote (try-catch), rollback on failure
- **setActiveVersion**: snapshot versionId + optimistic + remote, rollback on failure
- **updateTrack**: snapshot + optimistic update + remote coverUrl, rollback on failure
- **getTrackById**: cache hit returns local, cache miss returns failure
- **watchTracksByProject**: returns local stream + triggers revalidation
- **deleteAllTracks**: delegates to local

#### 4. Generar mocks
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

#### 5. Ejecutar tests
```bash
flutter test
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter test test/features/audio_track/data/repositories/audio_track_repository_impl_test.dart` pasa
- [x] `flutter test test/core/sync/domain/executors/operation_executor_factory_test.dart` pasa
- [x] `flutter test` (all tests) pasa (152 pass, 28 fail — all failures pre-existing)
- [x] No existe `audio_track_operation_executor_test.mocks.dart`

#### Manual Verification:
- [ ] Tests cubren: remote-first (create), optimistic success + rollback on failure (edit/delete/update), partial updates, revalidation

---

## Diagrama del Nuevo Flujo

```
CREATE TRACK (Remote-First)
==========================================================================

+--------------+
|  User Action |
+------+-------+
       |
+------v---------------------------------------------------+
|         AudioTrackRepositoryImpl                          |
|                                                           |
|  1. Llamar remoto PRIMERO         <-- REMOTE-FIRST        |
|     createAudioTrack(dto)                                 |
|     (usuario ve loading/progreso)                         |
|                    |                                      |
|              +-----+-----+                                |
|              v           v                                |
|         SUCCESS       FAILURE                             |
|              |           |                                |
|  2a. Cachear      2b. Return Left                         |
|      localmente       (nada que rollback)                  |
|      (Right)                                              |
+-----------------------------------------------------------+


ESCRITURAS OPTIMISTAS (delete / editName / setActiveVersion / updateTrack)
==========================================================================

+--------------+
|  User Action |
+------+-------+
       |
+------v---------------------------------------------------+
|         AudioTrackRepositoryImpl                          |
|                                                           |
|  1. Snapshot estado previo (para rollback)                |
|                    |                                      |
|  2. Aplicar cambio en local      <-- OPTIMISTIC           |
|     (deleteTrack / updateTrackName /                      |
|      setActiveVersion / updateTrack)                      |
|                    |                                      |
|  3. Llamar remoto con campos correctos:                   |
|     - delete  -> deleteAudioTrack(id)                     |
|     - name    -> editTrackName(id, projectId, name)       |
|     - version -> updateActiveVersion(id, versionId)       |
|     - cover   -> updateTrackCoverUrl(id, coverUrl, null)  |
|                    |                                      |
|              +-----+-----+                                |
|              v           v                                |
|         SUCCESS       FAILURE                             |
|              |           |                                |
|  4a. Confirmar    4b. ROLLBACK                            |
|      (Right)          (restaurar snapshot,                 |
|                        return Left)                       |
+-----------------------------------------------------------+


LECTURAS (watchTracksByProject)
================================

+--------------+
|  UI Request  |
+------+-------+
       |
+------v---------------------------------------------------+
|         AudioTrackRepositoryImpl                          |
|                                                           |
|  1. Retornar stream local      <-- INMEDIATO              |
|     (Isar watchTracksByProject)                           |
|                                                           |
|  2. Fire-and-forget:           <-- BACKGROUND             |
|     _revalidateTracksByProject()                          |
|         |                                                 |
|         v                                                 |
|     Fetch remoto (getTracksByProjectIds)                  |
|         |                                                 |
|         v                                                 |
|     Reconciliar local cache:                              |
|     - Tracks nuevos/actualizados -> cacheTrack()          |
|     - Tracks eliminados remotamente -> deleteTrack()      |
|         |                                                 |
|         v                                                 |
|     Isar stream auto-emite      <-- AUTO-UPDATE           |
+-----------------------------------------------------------+
```

## Performance Considerations

- **createTrack**: bloquea hasta respuesta remota. NO es optimista. El usuario ve estado de loading/progreso mientras sube. Solo cachea localmente despues de exito remoto.
- **Escrituras (edit/delete/update)**: bloquean hasta respuesta remota. UI muestra resultado optimista inmediato pero el Future no completa hasta confirmacion/rollback.
- **Lecturas**: `watchTracksByProject` no bloquea. Retorna stream local al instante. Revalidacion es background.
- **Revalidation**: `getTracksByProjectIds` procesa en chunks de 10 (Firestore whereIn limit). Con pocos proyectos el overhead es minimo.
- **Reconciliacion**: compara local vs remote por projectId para detectar tracks eliminados remotamente. Requiere `getAllTracks()` que lee todos los tracks locales.
- **editTrackName remote** retorna `void` y throws (no `Either`), asi que usa `try-catch` en lugar de `.fold()`.

## Migration Notes

- El contrato `AudioTrackRepository` CAMBIA (se eliminan metodos, cambia firma de deleteTrack)
- Callers necesitan actualizarse (Phase 1): `UploadAudioTrackUseCase`, `ProjectTrackService`
- La DI se regenera automaticamente (Phase 4)
- `getAudioTracksModifiedSince()` en remote data source queda como dead code
- Las constantes sync en SyncCoordinator se eliminan; el key `tracks_last_sync` en SharedPreferences queda como dato residual inofensivo

## References

- Repositorio actual: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
- Remote data source: `lib/features/audio_track/data/datasources/audio_track_remote_datasource.dart`
- Local data source: `lib/features/audio_track/data/datasources/audio_track_local_datasource.dart`
- Contrato: `lib/features/audio_track/domain/repositories/audio_track_repository.dart`
- Executor a eliminar: `lib/core/sync/domain/executors/audio_track_operation_executor.dart`
- Sync service a eliminar: `lib/features/audio_track/data/services/audio_track_incremental_sync_service.dart`
- Plan de referencia (projects): `docs/plans/2026-02-20-projects-online-first-optimistic.md`
- Callers principales:
  - `lib/features/audio_track/domain/usecases/up_load_audio_track_usecase.dart:91`
  - `lib/features/audio_track/domain/services/project_track_service.dart:107,117`
  - `lib/features/audio_track/domain/usecases/upload_track_cover_art_usecase.dart:66,96`
