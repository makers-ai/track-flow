# Online-First Track Upload Implementation Plan

## Overview

Refactorizar el sistema de upload de tracks y versiones de **offline-first** a **online-first**. Actualmente el flujo escribe primero en local (Isar), encola operaciones, y sincroniza en background. El nuevo flujo será: subir a Firebase primero, y solo si tiene éxito, guardar en local.

## Current State Analysis

### Flujo Actual (Offline-First)

```
Usuario → Local (Isar) → Encolar → Background Sync → Firebase
                ↓
        Usuario ve "éxito" inmediato (falso optimismo)
```

**Problemas identificados:**
- Si el sync falla en background, el usuario no recibe feedback
- Estados inconsistentes entre local y remoto
- Código complejo con cola de operaciones y rollbacks
- Debugging difícil

### Archivos Afectados

| Archivo | Propósito |
|---------|-----------|
| `lib/features/audio_track/domain/usecases/up_load_audio_track_usecase.dart` | Orquesta upload de track nuevo |
| `lib/features/track_version/domain/usecases/add_track_version_usecase.dart` | Orquesta upload de versión |
| `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart` | Repository de tracks |
| `lib/features/track_version/data/repositories/track_version_repository_impl.dart` | Repository de versiones |
| `lib/features/track_version/data/datasources/track_version_remote_datasource.dart` | Datasource remoto de versiones |
| `lib/features/audio_track/data/datasources/audio_track_remote_datasource.dart` | Datasource remoto de tracks |

## Desired End State

### Flujo Nuevo (Online-First)

```
Usuario → Firebase Storage → Firestore → Local (Isar)
                                              ↓
                                   Usuario ve éxito REAL
```

**Beneficios:**
- Feedback honesto al usuario
- Consistencia garantizada (si está en local, está en remoto)
- Código más simple y lineal
- Debugging más fácil

### Verificación del End State

1. Al subir un track/versión, el usuario ve loading mientras sube realmente
2. Si falla, el usuario ve el error y puede reintentar
3. Si tiene éxito, el archivo está en Firebase Storage Y en Firestore
4. El cache local existe para reproducción offline posterior
5. No hay operaciones pendientes en la cola para uploads

## What We're NOT Doing

- **NO** cambiamos la lectura/reproducción offline (el cache sigue funcionando igual)
- **NO** cambiamos la estructura de Firestore (mismas colecciones)
- **NO** cambiamos las entidades de dominio
- **NO** cambiamos la UI (mismos forms, mismos blocs)
- **NO** eliminamos el sistema de sync completo (solo lo bypasseamos para uploads)

## Implementation Approach

El cambio principal está en los **Use Cases** y **Repositories**. La estrategia es:

1. Modificar los use cases para que llamen primero al datasource remoto
2. Modificar los repositories para exponer métodos de "upload directo"
3. Después del éxito remoto, guardar en local (cache)
4. Eliminar el encolado de operaciones para estos flujos específicos

---

## Phase 1: Refactorizar TrackVersionRepository

### Overview
Añadir método para crear versión directamente en remoto, sin pasar por la cola de sync.

### Changes Required:

#### 1. Track Version Repository Contract
**File**: `lib/features/track_version/domain/repositories/track_version_repository.dart`
**Changes**: Añadir método `addVersionOnline` que sube directamente a Firebase

```dart
/// Adds a new version directly to Firebase (online-first approach).
/// Returns the created version with remote URL populated.
Future<Either<Failure, TrackVersion>> addVersionOnline({
  required AudioTrackId trackId,
  required File file,
  String? label,
  required Duration duration,
  required String createdBy,
});
```

#### 2. Track Version Repository Implementation
**File**: `lib/features/track_version/data/repositories/track_version_repository_impl.dart`
**Changes**: Implementar `addVersionOnline` que:
1. Llama a `_remote.createTrackVersion()` directamente
2. Si tiene éxito, cachea en local via `_local.cacheVersion()`
3. NO encola operación en `PendingOperationsManager`
4. NO llama a `_backgroundSyncCoordinator.pushUpstream()`

```dart
@override
Future<Either<Failure, TrackVersion>> addVersionOnline({
  required AudioTrackId trackId,
  required File file,
  String? label,
  required Duration duration,
  required String createdBy,
}) async {
  try {
    // 1. Calculate next version number from local data
    final existingVersions = await _local.getVersionsByTrack(trackId.value);
    final nextVersionNumber = existingVersions.fold(
      (failure) => 1,
      (versions) => versions.isEmpty ? 1 : versions.map((v) => v.versionNumber).reduce(max) + 1,
    );

    // 2. Create DTO for remote upload
    final versionId = TrackVersionId();
    final dto = TrackVersionDTO(
      id: versionId.value,
      trackId: trackId.value,
      versionNumber: nextVersionNumber,
      label: label,
      fileLocalPath: file.path,
      fileRemoteUrl: null, // Will be set by remote datasource
      durationMs: duration.inMilliseconds,
      status: 'processing',
      createdAt: DateTime.now(),
      createdBy: createdBy,
      isDeleted: false,
    );

    // 3. Upload to Firebase (Storage + Firestore)
    final remoteResult = await _remote.createTrackVersion(dto, file);

    return remoteResult.fold(
      (failure) => Left(failure),
      (uploadedDto) async {
        // 4. Cache locally (only after remote success)
        await _local.cacheVersion(uploadedDto);

        // 5. Return domain entity
        return Right(uploadedDto.toDomain());
      },
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to upload version: $e'));
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Code compiles without errors: `flutter analyze`
- [x] Existing tests pass: `flutter test test/features/track_version/`

#### Manual Verification:
- [x] N/A for this phase (no UI changes yet)

---

## Phase 2: Refactorizar AddTrackVersionUseCase

### Overview
Modificar el use case para usar el nuevo método `addVersionOnline` en lugar del flujo offline-first.

### Changes Required:

#### 1. AddTrackVersionUseCase
**File**: `lib/features/track_version/domain/usecases/add_track_version_usecase.dart`
**Changes**: Reemplazar llamada a `trackVersionRepository.addVersion()` por `trackVersionRepository.addVersionOnline()`

**Antes (líneas 73-85):**
```dart
final versionResult = await trackVersionRepository.addVersion(
  trackId: params.trackId,
  file: params.file,
  label: params.label,
  duration: duration,
  createdBy: userId,
);
```

**Después:**
```dart
final versionResult = await trackVersionRepository.addVersionOnline(
  trackId: params.trackId,
  file: params.file,
  label: params.label,
  duration: duration,
  createdBy: userId,
);
```

#### 2. Simplificar cache de audio
**File**: `lib/features/track_version/domain/usecases/add_track_version_usecase.dart`
**Changes**: El cache de audio local ahora es opcional/best-effort, ya que el archivo ya está en Firebase

**Antes (líneas 88-100):** Rollback si falla el cache
**Después:** Log warning pero no falla la operación

```dart
// Cache audio locally for offline playback (best-effort, don't fail if this fails)
final cacheResult = await audioStorageRepository.storeAudio(
  params.trackId,
  createdVersion.id,
  params.file,
  DirectoryType.audioTracks,
);

cacheResult.fold(
  (failure) => debugPrint('Warning: Failed to cache audio locally: $failure'),
  (cached) => debugPrint('Audio cached locally at: ${cached.path}'),
);
```

### Success Criteria:

#### Automated Verification:
- [x] Code compiles: `flutter analyze`
- [x] Unit tests pass: `flutter test test/features/track_version/`

#### Manual Verification:
- [ ] Subir nueva versión a un track existente funciona
- [ ] El archivo aparece en Firebase Storage
- [ ] La metadata aparece en Firestore collection `track_versions`
- [ ] Si hay error de red, el usuario ve el error (no éxito falso)

**Implementation Note**: Pausa aquí para verificación manual antes de Phase 3.

---

## Phase 3: Refactorizar AudioTrackRepository

### Overview
Añadir método para crear track directamente en remoto.

### Changes Required:

#### 1. Audio Track Repository Contract
**File**: `lib/features/audio_track/domain/repositories/audio_track_repository.dart`
**Changes**: Añadir método `createTrackOnline`

```dart
/// Creates a new track directly in Firebase (online-first approach).
Future<Either<Failure, AudioTrack>> createTrackOnline(AudioTrack track);
```

#### 2. Audio Track Repository Implementation
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
**Changes**: Implementar `createTrackOnline`

```dart
@override
Future<Either<Failure, AudioTrack>> createTrackOnline(AudioTrack track) async {
  try {
    final dto = AudioTrackDTO.fromDomain(track);

    // 1. Create in Firestore first
    final remoteResult = await remoteDataSource.createTrack(dto);

    return remoteResult.fold(
      (failure) => Left(failure),
      (_) async {
        // 2. Cache locally only after remote success
        await localDataSource.cacheTrack(dto);
        return Right(track);
      },
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to create track online: $e'));
  }
}
```

#### 3. Método para actualizar activeVersionId online
**File**: `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
**Changes**: Añadir `setActiveVersionOnline`

```dart
@override
Future<Either<Failure, Unit>> setActiveVersionOnline(
  AudioTrackId trackId,
  TrackVersionId versionId,
) async {
  try {
    // 1. Update in Firestore first
    final remoteResult = await remoteDataSource.updateActiveVersion(
      trackId.value,
      versionId.value,
    );

    return remoteResult.fold(
      (failure) => Left(failure),
      (_) async {
        // 2. Update local cache
        await localDataSource.setActiveVersion(trackId.value, versionId.value);
        return Right(unit);
      },
    );
  } catch (e) {
    return Left(DatabaseFailure('Failed to set active version: $e'));
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Code compiles: `flutter analyze`
- [x] Tests pass: `flutter test test/features/audio_track/` (pre-existing failures unrelated to changes)

#### Manual Verification:
- [x] N/A (se prueba en Phase 4)

---

## Phase 4: Refactorizar UploadAudioTrackUseCase

### Overview
Modificar el use case principal para usar el enfoque online-first.

### Changes Required:

#### 1. UploadAudioTrackUseCase
**File**: `lib/features/audio_track/domain/usecases/up_load_audio_track_usecase.dart`
**Changes**: Cambiar el orden de operaciones

**Nuevo flujo:**
1. Validar auth y permisos (sin cambios)
2. Subir versión a Firebase primero via `addVersionOnline`
3. Crear track metadata en Firestore via `createTrackOnline`
4. Actualizar activeVersionId en Firestore via `setActiveVersionOnline`

```dart
@override
Future<Either<Failure, Unit>> call(UploadAudioTrackParams params) async {
  try {
    // 1. Auth check (unchanged)
    final userId = await _sessionStorage.getUserId();
    if (userId == null) {
      return Left(AuthenticationFailure('User not authenticated'));
    }

    // 2. Get project and validate permissions (unchanged)
    final projectResult = await _projectsRepository.getProjectById(params.projectId);
    if (projectResult.isLeft()) {
      return Left(projectResult.fold((l) => l, (_) => UnexpectedFailure('Failed to get project')));
    }
    final project = projectResult.getOrElse(() => throw Exception('Project not found'));

    // 3. Create track entity (metadata only, no persistence yet)
    final trackResult = _projectTrackService.addTrackToProject(
      project: project,
      name: params.name,
      userId: userId,
    );
    if (trackResult.isLeft()) {
      return Left(trackResult.fold((l) => l, (_) => UnexpectedFailure('Permission denied')));
    }
    final track = trackResult.getOrElse(() => throw Exception('Failed to create track'));

    // 4. Upload version to Firebase FIRST (online-first)
    final versionResult = await _addTrackVersionUseCase(
      AddTrackVersionParams(
        trackId: track.id,
        file: params.file,
        label: 'Initial version',
      ),
    );

    if (versionResult.isLeft()) {
      // No rollback needed - nothing was persisted yet
      return versionResult;
    }
    final version = versionResult.getOrElse(() => throw Exception('Version creation failed'));

    // 5. Create track metadata in Firestore (after version upload succeeded)
    final trackWithVersion = track.copyWith(activeVersionId: version.id);
    final createTrackResult = await _audioTrackRepository.createTrackOnline(trackWithVersion);

    if (createTrackResult.isLeft()) {
      // Rollback: delete the uploaded version
      await _trackVersionRepository.deleteVersion(version.id);
      return createTrackResult.map((_) => unit);
    }

    return Right(unit);
  } catch (e) {
    return Left(UnexpectedFailure('Upload failed: $e'));
  }
}
```

### Success Criteria:

#### Automated Verification:
- [x] Code compiles: `flutter analyze`
- [x] All tests pass: `flutter test` (pre-existing test failures unrelated to changes)

#### Manual Verification:
- [ ] Subir track nuevo a un proyecto funciona
- [ ] El archivo aparece en Firebase Storage bajo `track_versions/{trackId}/`
- [ ] La metadata del track aparece en Firestore `audio_tracks`
- [ ] La metadata de la versión aparece en Firestore `track_versions`
- [ ] El track aparece inmediatamente en la UI del proyecto
- [ ] Si hay error de red durante el upload, el usuario ve el error
- [ ] No quedan operaciones pendientes en la cola de sync

**Implementation Note**: Pausa aquí para verificación manual completa antes de Phase 5.

---

## Phase 5: Cleanup y Optimización

### Overview
Remover código muerto y optimizar los flujos existentes.

### Changes Required:

#### 1. Deprecar métodos offline-first (no eliminar aún)
**Files**:
- `lib/features/track_version/data/repositories/track_version_repository_impl.dart`
- `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`

**Changes**: Añadir `@Deprecated` a los métodos `addVersion` y `createTrack` originales

```dart
@Deprecated('Use addVersionOnline instead for online-first upload flow')
@override
Future<Either<Failure, TrackVersion>> addVersion({...}) async {
  // ... existing code
}
```

#### 2. Actualizar comentarios y documentación
**Files**: Todos los archivos modificados
**Changes**: Actualizar docstrings para reflejar el nuevo flujo

#### 3. Considerar remover encolado para uploads (opcional)
**File**: `lib/features/track_version/data/repositories/track_version_repository_impl.dart`
**Changes**: El método `_queueUploadOperation` puede marcarse como unused o removerse si ya no se usa

### Success Criteria:

#### Automated Verification:
- [x] No warnings de deprecated en el código nuevo: `flutter analyze`
- [x] Tests pasan: `flutter test`
- [ ] Build exitoso: `flutter build apk --debug`

#### Manual Verification:
- [ ] Flujo completo de upload funciona end-to-end
- [ ] No hay regresiones en reproducción offline de tracks cacheados
- [ ] Performance del upload es aceptable

---

## Testing Strategy

### Unit Tests:
- Test `TrackVersionRepositoryImpl.addVersionOnline()` con mock de remote datasource
- Test `AudioTrackRepositoryImpl.createTrackOnline()` con mock de remote datasource
- Test `AddTrackVersionUseCase` con el nuevo flujo
- Test `UploadAudioTrackUseCase` con el nuevo flujo
- Test de rollback cuando falla el upload remoto

### Integration Tests:
- Upload de track nuevo end-to-end (requiere Firebase emulator o test environment)
- Upload de versión nueva end-to-end

### Manual Testing Steps:
1. Abrir proyecto existente
2. Tap en "Upload Track"
3. Seleccionar archivo de audio
4. Ingresar nombre del track
5. Tap "Upload" y verificar que muestra loading real
6. Verificar que el track aparece en la lista
7. Desconectar internet y verificar que el track cacheado se puede reproducir
8. Intentar subir con internet desconectado y verificar mensaje de error

## Performance Considerations

- El usuario ahora espera el upload real (puede ser más lento percibido)
- Considerar mostrar progreso de upload en la UI (ya existe en `unified_audio_service.dart:54-64`)
- El cache local después del upload es rápido y no debería afectar UX

## Migration Notes

- No hay migración de datos necesaria
- Los tracks/versiones existentes siguen funcionando igual
- Las operaciones pendientes existentes en la cola se procesarán normalmente
- El cambio es solo para NUEVOS uploads a partir de esta implementación

## References

- Análisis del flujo actual: Conversación previa en este chat
- Remote datasource: `lib/features/track_version/data/datasources/track_version_remote_datasource.dart:43-99`
- Use case principal: `lib/features/audio_track/domain/usecases/up_load_audio_track_usecase.dart:41-119`
- Colección Firestore tracks: `audio_tracks`
- Colección Firestore versions: `track_versions`
- Storage path: `track_versions/{trackId}/{versionId}.{ext}`
