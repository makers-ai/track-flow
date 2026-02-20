# Projects Feature: Online-First Optimistic Implementation Plan

## Overview

Migrar la feature `projects` del patron offline-first + queue + incremental sync a un enfoque **online-first optimistic** con rollback explicito. Firebase es la fuente de verdad. Local (Isar) se usa exclusivamente como cache para UX optimista y lecturas rapidas con revalidacion en background.

## Current State Analysis

### Repositorio actual (`projects_repository_impl.dart`)
- **Dependencias**: `ProjectsLocalDataSource`, `BackgroundSyncCoordinator`, `PendingOperationsManager`
- **NO** tiene acceso directo a `ProjectRemoteDataSource` (el remoto se accede solo via `ProjectOperationExecutor`)
- **Escrituras**: guarda local → encola operacion → fire-and-forget sync
- **Lecturas**: solo tocan el cache local, nunca el remoto

### Infraestructura sync que se elimina
- `ProjectOperationExecutor` - traduce operaciones de queue en llamadas a Firebase
- `ProjectIncrementalSyncService` - trae cambios incrementales de Firebase al cache
- Referencias a `'project'` en `OperationExecutorFactory` y `SyncCoordinator`

### Key Discoveries
- `ProjectRemoteDataSource.createProject()` retorna `Either<Failure, ProjectDTO>` (`project_remote_data_source.dart:34`)
- `ProjectRemoteDataSource.updateProject()` retorna `Either<Failure, Unit>` - NO retorna el DTO actualizado (`project_remote_data_source.dart:68`)
- `ProjectRemoteDataSource.deleteProject(projectId)` ya hace soft delete: `isDeleted: true` + server timestamps (`project_remote_data_source.dart:99-107`)
- `ProjectsLocalDataSource.removeCachedProject()` hace soft delete local: `isDeleted = true` (`project_local_data_source.dart:71-78`)
- `watchAllProjects` filtra `isDeletedEqualTo(false)` - soft-deleted desaparecen del stream automaticamente (`project_local_data_source.dart:101`)
- `getUserProjects()` en remote NO filtra por `isDeleted` - retorna todos incluyendo borrados (`project_remote_data_source.dart:160-219`)
- No existen tests para `ProjectsRepositoryImpl` actualmente
- El contrato `ProjectsRepository` NO necesita cambiar - mismas firmas, cambio solo en implementacion

## Desired End State

Despues de completar este plan:

1. `ProjectsRepositoryImpl` usa patron **optimistic update + rollback** para escrituras
2. Lecturas retornan datos locales inmediatamente + revalidacion remota en background
3. No existe queue, pending operations, background sync, ni incremental sync para projects
4. `ProjectOperationExecutor` y `ProjectIncrementalSyncService` eliminados
5. DI regenerada sin las clases eliminadas
6. Tests del repositorio validan el flujo optimistic + rollback

### Como verificar:
- `flutter analyze` pasa sin errores
- `flutter test` pasa (tests nuevos + existentes)
- Al crear/editar/borrar un proyecto, la UI responde inmediato (optimistic) y si falla el remoto, se revierte
- Al abrir la lista de proyectos, se muestra cache local + se actualiza en background con datos frescos de Firebase

## What We're NOT Doing

- No modificamos el contrato `ProjectsRepository` (mismas firmas publicas)
- No modificamos `ProjectRemoteDataSource` ni `ProjectsLocalDataSource` (se reutilizan tal cual)
- No tocamos el sistema sync core mas alla de limpiar las referencias a projects
- No agregamos metodos nuevos a los data sources existentes
- No migramos otras features (audio_track, audio_comment, etc.) - solo projects
- No eliminamos `getUserProjectsModifiedSince()` del remote data source (queda como dead code, se puede limpiar despues)

## Implementation Approach

**Estrategia**: Optimistic Update con Rollback Explicito + Stale-While-Revalidate para lecturas.

**Patron de escritura**:
1. Snapshot del estado previo (para rollback)
2. Aplicar cambio en local inmediatamente (optimistic)
3. Llamar al remoto
4. Si remoto falla → restaurar snapshot (rollback)
5. Si remoto tiene exito → confirmar

**Patron de lectura**:
1. Retornar datos locales inmediatamente
2. Disparar revalidacion remota en background (fire-and-forget)
3. Si hay cambios, actualizar cache local → Isar stream auto-emite

**Soft Delete (Decision)**:
- **Firebase**: mantiene soft delete (`isDeleted: true`) via `deleteProject()` existente
- **Local**: usa `removeCachedProject()` existente que hace soft delete (`isDeleted = true`)
- `watchAllProjects` ya filtra `isDeletedEqualTo(false)` → proyecto desaparece de la UI
- Rollback: re-cachear el snapshot original (con `isDeleted = false`) → proyecto reaparece

---

## Phase 1: Refactorizar ProjectsRepositoryImpl

### Overview
Reescribir el repositorio para eliminar todas las dependencias del sistema sync y implementar el flujo online-first optimistic.

### Changes Required:

#### 1. Nuevas dependencias del constructor
**File**: `lib/features/projects/data/repositories/projects_repository_impl.dart`
**Changes**: Reemplazar `BackgroundSyncCoordinator` y `PendingOperationsManager` por `ProjectRemoteDataSource`

```dart
import 'dart:async';
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/utils/app_logger.dart';
import 'package:trackflow/features/projects/data/datasources/project_local_data_source.dart';
import 'package:trackflow/features/projects/data/datasources/project_remote_data_source.dart';
import 'package:trackflow/features/projects/data/models/project_dto.dart';
import 'package:trackflow/features/projects/domain/entities/project.dart';
import 'package:trackflow/features/projects/domain/repositories/projects_repository.dart';
import 'package:trackflow/core/entities/unique_id.dart';

@LazySingleton(as: ProjectsRepository)
class ProjectsRepositoryImpl implements ProjectsRepository {
  final ProjectsLocalDataSource _localDataSource;
  final ProjectRemoteDataSource _remoteDataSource;

  ProjectsRepositoryImpl({
    required ProjectsLocalDataSource localDataSource,
    required ProjectRemoteDataSource remoteDataSource,
  }) : _localDataSource = localDataSource,
       _remoteDataSource = remoteDataSource;
```

**Imports eliminados**:
- `package:trackflow/core/sync/domain/services/background_sync_coordinator.dart`
- `package:trackflow/core/sync/domain/services/pending_operations_manager.dart`
- `package:trackflow/core/sync/data/models/sync_operation_document.dart`

#### 2. createProject - Optimistic + Rollback
```dart
@override
Future<Either<Failure, Project>> createProject(Project project) async {
  final dto = ProjectDTO.fromDomain(project);

  // 1. Optimistic: cache locally for immediate UI feedback
  await _localDataSource.cacheProject(dto);

  // 2. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.createProject(dto);

  return remoteResult.fold(
    (failure) {
      // 3. Rollback: remove optimistic cache on remote failure
      _localDataSource.removeCachedProject(project.id.value);
      return Left(failure);
    },
    (remoteDto) {
      // 4. Success: sync local with remote response if needed
      _localDataSource.cacheProject(remoteDto);
      return Right(project);
    },
  );
}
```

#### 3. updateProject - Snapshot + Optimistic + Rollback
```dart
@override
Future<Either<Failure, Unit>> updateProject(Project project) async {
  final dto = ProjectDTO.fromDomain(project);

  // 1. Snapshot previous state for rollback
  final prevResult = await _localDataSource.getCachedProject(
    project.id.value,
  );
  final prevDto = prevResult.fold((_) => null, (dto) => dto);

  // 2. Optimistic: apply changes locally
  await _localDataSource.cacheProject(dto);

  // 3. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.updateProject(dto);

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore previous state
      if (prevDto != null) {
        _localDataSource.cacheProject(prevDto);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

#### 4. deleteProject - Optimistic Soft Delete + Rollback
```dart
@override
Future<Either<Failure, Unit>> deleteProject(Project project) async {
  // 1. Snapshot for rollback
  final prevResult = await _localDataSource.getCachedProject(
    project.id.value,
  );
  final prevDto = prevResult.fold((_) => null, (dto) => dto);

  // 2. Optimistic: soft delete locally (disappears from watches)
  await _localDataSource.removeCachedProject(project.id.value);

  // 3. Persist to remote (soft delete in Firestore)
  final remoteResult = await _remoteDataSource.deleteProject(
    project.id.value,
  );

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore project in local cache
      if (prevDto != null) {
        _localDataSource.cacheProject(prevDto);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

#### 5. getProjectById - Local First + Remote Fallback + Background Revalidation
```dart
@override
Future<Either<Failure, Project>> getProjectById(ProjectId projectId) async {
  // 1. Try local cache first
  final localResult = await _localDataSource.getCachedProject(
    projectId.value,
  );
  final localDto = localResult.fold((_) => null, (dto) => dto);

  if (localDto != null && !localDto.isDeleted) {
    // 2. Return local immediately + trigger background revalidation
    unawaited(_revalidateProject(projectId.value));
    return Right(localDto.toDomain());
  }

  // 3. Not in cache → fetch from remote directly
  final remoteResult = await _remoteDataSource.getProjectById(
    projectId.value,
  );

  return remoteResult.fold(
    (failure) => Left(failure),
    (dto) {
      // 4. Cache for future reads
      _localDataSource.cacheProject(dto);
      return Right(dto.toDomain());
    },
  );
}
```

#### 6. watchLocalProjects - Stream + Background Revalidation
```dart
@override
Stream<Either<Failure, List<Project>>> watchLocalProjects(UserId ownerId) {
  // Trigger background revalidation (fire-and-forget)
  unawaited(_revalidateProjects(ownerId.value));

  // Return local stream - auto-emits when cache is updated by revalidation
  return _localDataSource
      .watchAllProjects(ownerId.value)
      .map((either) {
        return either.map(
          (projects) =>
              projects.map((project) => project.toDomain()).toList(),
        );
      })
      .handleError((error) {
        return left<Failure, List<Project>>(
          DatabaseFailure('Local projects stream error: $error'),
        );
      });
}
```

#### 7. watchProjectById - Stream + Background Revalidation
```dart
@override
Stream<Either<Failure, Project?>> watchProjectById(ProjectId projectId) {
  // Trigger background revalidation (fire-and-forget)
  unawaited(_revalidateProject(projectId.value));

  return _localDataSource
      .watchProjectById(projectId.value)
      .map((either) => either.map((dto) => dto?.toDomain()))
      .handleError((error) {
        return left<Failure, Project?>(
          DatabaseFailure('Local project stream error: $error'),
        );
      });
}
```

#### 8. clearLocalCache - Sin cambios
```dart
@override
Future<Either<Failure, Unit>> clearLocalCache() async {
  try {
    await _localDataSource.clearCache();
    return const Right(unit);
  } catch (e) {
    return Left(DatabaseFailure('Failed to clear projects cache: $e'));
  }
}
```

#### 9. Metodos privados de revalidacion
```dart
/// Revalidates all projects for a user from remote.
/// Updates local cache with fresh data. Isar watches auto-emit on changes.
Future<void> _revalidateProjects(String userId) async {
  try {
    final remoteResult = await _remoteDataSource.getUserProjects(userId);
    await remoteResult.fold(
      (_) async {}, // Silently fail - local data still shown
      (remoteDtos) async {
        for (final dto in remoteDtos) {
          if (dto.isDeleted) {
            await _localDataSource.removeCachedProject(dto.id);
          } else {
            await _localDataSource.cacheProject(dto);
          }
        }
      },
    );
  } catch (e) {
    AppLogger.warning(
      'Background project revalidation failed: $e',
      tag: 'ProjectsRepositoryImpl',
    );
  }
}

/// Revalidates a single project from remote.
Future<void> _revalidateProject(String projectId) async {
  try {
    final remoteResult = await _remoteDataSource.getProjectById(projectId);
    await remoteResult.fold(
      (_) async {}, // Silently fail
      (dto) async {
        if (dto.isDeleted) {
          await _localDataSource.removeCachedProject(dto.id);
        } else {
          await _localDataSource.cacheProject(dto);
        }
      },
    );
  } catch (e) {
    AppLogger.warning(
      'Background project revalidation failed: $e',
      tag: 'ProjectsRepositoryImpl',
    );
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa sin errores
- [x] `flutter test` pasa (no debe romper tests existentes)
- [x] El archivo no importa nada de `core/sync/`
- [x] El constructor solo recibe `ProjectsLocalDataSource` y `ProjectRemoteDataSource`

#### Manual Verification:
- [ ] Crear proyecto: aparece en la lista inmediatamente, persiste despues de recargar
- [ ] Crear proyecto sin conexion: aparece brevemente, desaparece al fallar el remoto (rollback)
- [ ] Editar proyecto: cambio visible inmediatamente, persiste despues de recargar
- [ ] Editar proyecto sin conexion: cambio aparece brevemente, se revierte al fallar (rollback)
- [ ] Borrar proyecto: desaparece inmediatamente, no reaparece despues de recargar
- [ ] Borrar proyecto sin conexion: desaparece brevemente, reaparece al fallar (rollback)
- [ ] Abrir lista de proyectos: muestra datos del cache inmediatamente, se actualiza con datos frescos en segundos

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to the next phase.

---

## Phase 2: Eliminar Infraestructura Sync de Projects

### Overview
Eliminar las clases especificas de sync para projects y limpiar las referencias en el core sync.

### Changes Required:

#### 1. Eliminar ProjectOperationExecutor
**File**: `lib/core/sync/domain/executors/project_operation_executor.dart`
**Action**: DELETE file

#### 2. Eliminar ProjectIncrementalSyncService
**File**: `lib/features/projects/data/services/project_incremental_sync_service.dart`
**Action**: DELETE file

#### 3. Limpiar OperationExecutorFactory
**File**: `lib/core/sync/domain/executors/operation_executor_factory.dart`
**Changes**: Remover el case `'project'` del switch y de `supportedEntityTypes`

Antes:
```dart
case 'project':
  return sl<ProjectOperationExecutor>();
```

Despues: eliminar ese case.

Antes en `supportedEntityTypes`:
```dart
List<String> get supportedEntityTypes => [
  'project',
  'audio_track',
  'track_version',
  'audio_comment',
  'audio_comment_by_version',
];
```

Despues:
```dart
List<String> get supportedEntityTypes => [
  'audio_track',
  'track_version',
  'audio_comment',
  'audio_comment_by_version',
];
```

Remover el import de `ProjectOperationExecutor`.

#### 4. Limpiar SyncCoordinator
**File**: `lib/core/sync/domain/services/sync_coordinator.dart`
**Changes**:

Remover constantes:
```dart
// ELIMINAR estas lineas:
static const String _projectsLastSyncKey = 'projects_last_sync';
static const String _projectsServiceKey = 'projects';
```

Remover del metodo `pullStartupData`:
```dart
// ANTES: solo sincronizaba projects
Future<void> pullStartupData(String userId) async {
  await _syncEntityByKey(
    _projectsServiceKey,
    _projectsLastSyncKey,
    'projects',
    userId,
    isFullSync: false,
  );
}

// DESPUES: vacio (projects ya no usa este sistema)
Future<void> pullStartupData(String userId) async {
  AppLogger.sync(
    'COORDINATOR',
    'Startup sync for user: $userId (no critical entities to sync)',
  );
}
```

Remover la linea de projects del metodo `pullAllData`:
```dart
// ELIMINAR esta linea de pullAllData:
await _syncEntityByKey(_projectsServiceKey, _projectsLastSyncKey, 'projects', userId);
```

Remover cases de projects en `_getServiceByKey`, `_getServiceKeyForEntity`, y `_getSyncKeyForEntity`.

Remover el import de `ProjectDTO`.

#### 5. Eliminar directorio de services si queda vacio
**File**: `lib/features/projects/data/services/`
**Action**: Si `project_incremental_sync_service.dart` era el unico archivo, eliminar el directorio `services/`.

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa sin errores
- [x] `flutter test` pasa
- [x] No existen los archivos: `project_operation_executor.dart`, `project_incremental_sync_service.dart`
- [x] `grep -r "ProjectOperationExecutor" lib/` no retorna resultados
- [x] `grep -r "ProjectIncrementalSyncService" lib/` no retorna resultados

#### Manual Verification:
- [ ] La app compila y ejecuta correctamente
- [ ] Las otras features de sync (audio_track, audio_comment, track_version) siguen funcionando

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to the next phase.

---

## Phase 3: Regenerar DI

### Overview
Ejecutar build_runner para regenerar `injection.config.dart` sin las clases eliminadas.

### Changes Required:

#### 1. Regenerar injection.config.dart
**Command**:
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```

Esto automaticamente:
- Elimina el registro de `ProjectOperationExecutor` (linea ~827-828 del config actual)
- Elimina el registro de `ProjectIncrementalSyncService` (linea ~785-789 del config actual)
- Actualiza el registro de `ProjectsRepositoryImpl` para usar las nuevas dependencias:

```dart
// ANTES (generado):
gh.lazySingleton<ProjectsRepository>(
    () => ProjectsRepositoryImpl(
          localDataSource: gh<ProjectsLocalDataSource>(),
          backgroundSyncCoordinator: gh<BackgroundSyncCoordinator>(),
          pendingOperationsManager: gh<PendingOperationsManager>(),
        ));

// DESPUES (se regenerara como):
gh.lazySingleton<ProjectsRepository>(
    () => ProjectsRepositoryImpl(
          localDataSource: gh<ProjectsLocalDataSource>(),
          remoteDataSource: gh<ProjectRemoteDataSource>(),
        ));
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter packages pub run build_runner build --delete-conflicting-outputs` completa sin errores
- [x] `flutter analyze` pasa
- [x] `injection.config.dart` no contiene `ProjectOperationExecutor` ni `ProjectIncrementalSyncService`
- [x] `injection.config.dart` registra `ProjectsRepositoryImpl` con `localDataSource` y `remoteDataSource`

#### Manual Verification:
- [ ] La app compila y arranca correctamente

---

## Phase 4: Tests

### Overview
Eliminar tests obsoletos, actualizar tests afectados, y crear tests nuevos para el repositorio refactorizado.

### Changes Required:

#### 1. Eliminar test del executor
**File**: `test/core/sync/domain/executors/project_operation_executor_test.dart`
**Action**: DELETE file

**File**: `test/core/sync/domain/executors/project_operation_executor_test.mocks.dart`
**Action**: DELETE file (si existe)

#### 2. Actualizar test del OperationExecutorFactory
**File**: `test/core/sync/domain/executors/operation_executor_factory_test.dart`
**Changes**:

- Remover test que verifica `'project'` retorna `ProjectOperationExecutor`
- Actualizar assertion de `supportedEntityTypes` para no incluir `'project'`
- Actualizar test de consistencia que itera sobre todos los tipos

```dart
// ANTES:
test('should return ProjectOperationExecutor for project', () {
  final executor = factory.getExecutor('project');
  expect(executor, isA<ProjectOperationExecutor>());
});

// DESPUES: eliminar este test

// ANTES (supported types):
expect(types, contains('project'));
expect(types.length, 5);

// DESPUES:
expect(types, isNot(contains('project')));
expect(types.length, 4);
```

#### 3. Crear tests del repositorio refactorizado
**File**: `test/features/projects/data/repositories/projects_repository_impl_test.dart`
**Action**: CREATE new file

```dart
import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/projects/data/datasources/project_local_data_source.dart';
import 'package:trackflow/features/projects/data/datasources/project_remote_data_source.dart';
import 'package:trackflow/features/projects/data/models/project_dto.dart';
import 'package:trackflow/features/projects/data/repositories/projects_repository_impl.dart';
import 'package:trackflow/features/projects/domain/entities/project.dart';
import 'package:trackflow/core/entities/unique_id.dart';

import 'projects_repository_impl_test.mocks.dart';

@GenerateMocks([ProjectsLocalDataSource, ProjectRemoteDataSource])
void main() {
  late ProjectsRepositoryImpl repository;
  late MockProjectsLocalDataSource mockLocal;
  late MockProjectRemoteDataSource mockRemote;

  // Helper to create test data
  final testDto = ProjectDTO(
    id: 'test-id',
    name: 'Test Project',
    description: 'Description',
    ownerId: 'owner-1',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: null,
    collaboratorIds: [],
    collaborators: [],
    isDeleted: false,
    version: 1,
    lastModified: null,
  );

  setUp(() {
    mockLocal = MockProjectsLocalDataSource();
    mockRemote = MockProjectRemoteDataSource();
    repository = ProjectsRepositoryImpl(
      localDataSource: mockLocal,
      remoteDataSource: mockRemote,
    );
  });

  // ============================================================
  // createProject
  // ============================================================
  group('createProject', () {
    test('should cache locally, call remote, and return project on success',
        () async {
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.createProject(any))
          .thenAnswer((_) async => Right(testDto));

      final project = testDto.toDomain();
      final result = await repository.createProject(project);

      expect(result.isRight(), true);
      verify(mockLocal.cacheProject(any)).called(2); // optimistic + sync with remote
      verify(mockRemote.createProject(any)).called(1);
    });

    test('should rollback local cache when remote fails', () async {
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.createProject(any))
          .thenAnswer((_) async => Left(ServerFailure('Network error')));
      when(mockLocal.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));

      final project = testDto.toDomain();
      final result = await repository.createProject(project);

      expect(result.isLeft(), true);
      verify(mockLocal.cacheProject(any)).called(1); // optimistic only
      verify(mockLocal.removeCachedProject('test-id')).called(1); // rollback
    });
  });

  // ============================================================
  // updateProject
  // ============================================================
  group('updateProject', () {
    test('should snapshot, update locally, call remote on success', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateProject(any))
          .thenAnswer((_) async => const Right(unit));

      final project = testDto.toDomain();
      final result = await repository.updateProject(project);

      expect(result.isRight(), true);
      verify(mockLocal.getCachedProject('test-id')).called(1); // snapshot
      verify(mockLocal.cacheProject(any)).called(1); // optimistic update
      verify(mockRemote.updateProject(any)).called(1);
    });

    test('should rollback to snapshot when remote fails', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.updateProject(any))
          .thenAnswer((_) async => Left(ServerFailure('Network error')));

      final project = testDto.toDomain();
      final result = await repository.updateProject(project);

      expect(result.isLeft(), true);
      verify(mockLocal.cacheProject(any)).called(2); // optimistic + rollback
    });
  });

  // ============================================================
  // deleteProject
  // ============================================================
  group('deleteProject', () {
    test('should soft-delete locally, call remote on success', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteProject(any))
          .thenAnswer((_) async => const Right(unit));

      final project = testDto.toDomain();
      final result = await repository.deleteProject(project);

      expect(result.isRight(), true);
      verify(mockLocal.removeCachedProject('test-id')).called(1);
      verify(mockRemote.deleteProject('test-id')).called(1);
    });

    test('should restore project when remote fails', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemote.deleteProject(any))
          .thenAnswer((_) async => Left(ServerFailure('Network error')));
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      final project = testDto.toDomain();
      final result = await repository.deleteProject(project);

      expect(result.isLeft(), true);
      verify(mockLocal.removeCachedProject('test-id')).called(1); // optimistic
      verify(mockLocal.cacheProject(testDto)).called(1); // rollback
    });
  });

  // ============================================================
  // getProjectById
  // ============================================================
  group('getProjectById', () {
    test('should return local project and trigger revalidation', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      // Revalidation (background, not awaited)
      when(mockRemote.getProjectById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-id'),
      );

      expect(result.isRight(), true);
      verify(mockLocal.getCachedProject('test-id')).called(1);
    });

    test('should fetch from remote when not in local cache', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => const Right(null));
      when(mockRemote.getProjectById(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocal.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-id'),
      );

      expect(result.isRight(), true);
      verify(mockRemote.getProjectById('test-id')).called(1);
    });

    test('should return failure when not in cache and remote fails', () async {
      when(mockLocal.getCachedProject(any))
          .thenAnswer((_) async => const Right(null));
      when(mockRemote.getProjectById(any))
          .thenAnswer((_) async => Left(ServerFailure('Not found')));

      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-id'),
      );

      expect(result.isLeft(), true);
    });
  });
}
```

**Nota**: Despues de crear este archivo, ejecutar:
```bash
flutter packages pub run build_runner build --delete-conflicting-outputs
```
para generar el archivo `.mocks.dart`.

### Success Criteria:

#### Automated Verification:
- [x] `flutter test test/features/projects/data/repositories/projects_repository_impl_test.dart` pasa
- [x] `flutter test test/core/sync/domain/executors/operation_executor_factory_test.dart` pasa
- [x] `flutter test` (all tests) pasa
- [x] No existen: `project_operation_executor_test.dart`, `project_operation_executor_test.mocks.dart`

#### Manual Verification:
- [ ] Los tests cubren los escenarios criticos: optimistic success, rollback on failure, revalidation

---

## Testing Strategy

### Unit Tests (Phase 4):
- **Escrituras - exito**: local actualizado + remoto llamado + estado consistente
- **Escrituras - fallo remoto**: rollback correcto al estado previo
- **Lecturas - cache hit**: retorna local + dispara revalidacion
- **Lecturas - cache miss**: fetches from remote + cache result
- **Revalidation**: actualiza cache silenciosamente sin afectar retornos

### Manual Testing Steps:
1. Crear proyecto con conexion → aparece en lista, persiste al recargar
2. Crear proyecto sin conexion → aparece brevemente, desaparece (rollback visible)
3. Editar nombre de proyecto con conexion → cambio persiste
4. Editar proyecto, cortar conexion durante la llamada → cambio se revierte
5. Borrar proyecto con conexion → desaparece permanentemente
6. Borrar proyecto sin conexion → reaparece despues del rollback
7. Abrir lista de proyectos → datos locales aparecen inmediatamente, datos frescos llegan en background
8. Verificar que audio_track, audio_comment, track_version siguen sincronizando normalmente

---

## Diagrama del Nuevo Flujo

```
ESCRITURAS (create / update / delete)
══════════════════════════════════════

┌─────────────┐
│ User Action │
└──────┬──────┘
       ▼
┌──────────────────────────────────────────────────┐
│         ProjectsRepositoryImpl                    │
│                                                   │
│  1. Snapshot estado previo (update/delete only)   │
│                    │                              │
│  2. Aplicar cambio en local     ◄── OPTIMISTIC    │
│     (cacheProject / removeCachedProject)          │
│                    │                              │
│  3. Llamar remoto (Firebase)    ◄── SOURCE OF     │
│                    │                 TRUTH         │
│              ┌─────┴─────┐                        │
│              ▼           ▼                        │
│         SUCCESS       FAILURE                     │
│              │           │                        │
│  4a. Confirmar    4b. ROLLBACK                    │
│      (return         (restaurar                   │
│       Right)          snapshot,                   │
│                       return Left)                │
└──────────────────────────────────────────────────┘


LECTURAS (watch / get)
══════════════════════

┌─────────────┐
│  UI Request │
└──────┬──────┘
       ▼
┌──────────────────────────────────────────────────┐
│         ProjectsRepositoryImpl                    │
│                                                   │
│  1. Retornar datos locales     ◄── INMEDIATO      │
│     (Isar cache / stream)                         │
│                                                   │
│  2. Fire-and-forget:           ◄── BACKGROUND     │
│     _revalidateProjects()                         │
│         │                                         │
│         ▼                                         │
│     Fetch remoto (getUserProjects)                │
│         │                                         │
│         ▼                                         │
│     Actualizar cache local                        │
│         │                                         │
│         ▼                                         │
│     Isar stream auto-emite     ◄── AUTO-UPDATE    │
│     (UI se actualiza sola)                        │
└──────────────────────────────────────────────────┘
```

## Performance Considerations

- **Escrituras**: bloquean hasta que el remoto responde (trade-off vs offline-first). La UI muestra el resultado optimista inmediatamente pero el `Future` no completa hasta tener confirmacion o rollback.
- **Lecturas**: no bloquean. Retornan datos locales al instante. La revalidacion es background.
- **Revalidation**: `getUserProjects()` hace 2 queries paralelos a Firestore (owned + collaborator). Con pocos proyectos (<50) el overhead es minimo.
- **Watch re-emission**: Isar solo emite si los datos realmente cambiaron. Si la revalidacion trae los mismos datos, no hay re-emission innecesaria.

## Migration Notes

- El contrato `ProjectsRepository` no cambia → los use cases, BLoCs, y todas las features que dependen de el NO necesitan modificacion.
- La DI se regenera automaticamente → no hay manual wiring.
- `getUserProjectsModifiedSince()` en `ProjectRemoteDataSource` queda como dead code (no tiene callers despues de eliminar el sync service). Se puede limpiar en un refactor futuro.
- Las constantes `_projectsLastSyncKey` y `_projectsServiceKey` en `SyncCoordinator` se eliminan. El key `projects_last_sync` en SharedPreferences queda como dato residual inofensivo.

## References

- Repositorio actual: `lib/features/projects/data/repositories/projects_repository_impl.dart`
- Remote data source: `lib/features/projects/data/datasources/project_remote_data_source.dart`
- Local data source: `lib/features/projects/data/datasources/project_local_data_source.dart`
- Contrato: `lib/features/projects/domain/repositories/projects_repository.dart`
- Executor a eliminar: `lib/core/sync/domain/executors/project_operation_executor.dart`
- Sync service a eliminar: `lib/features/projects/data/services/project_incremental_sync_service.dart`
- Sync architecture docs: `docs/sync_architecture.md`
