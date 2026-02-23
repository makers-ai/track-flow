# Notifications: Online-First Optimistic Implementation Plan

## Overview

Migrar `NotificationRepositoryImpl` del patron actual (local-first con sync oportunista sin rollback) al patron **online-first optimistic con rollback** ya establecido en el proyecto. Firebase es la fuente de verdad. Si el remoto falla, se revierte el cambio local inmediatamente.

## Current State Analysis

### Repositorio actual (`notification_repository_impl.dart`)
- **Dependencias**: `NotificationLocalDataSource`, `NotificationRemoteDataSource`, `NetworkStateManager`
- **Escrituras**: guarda local → verifica conectividad → si hay red intenta remoto → si falla log warning y retorna exito
- **Lecturas**: streams de Isar (local only) + `syncNotificationsFromRemote()` para pull manual
- **Problema**: si el remoto falla, el cambio local queda "huerfano" y nunca se sincroniza (no hay queue ni retry)

### Key Discoveries:
- Los 6 metodos de escritura tienen el mismo patron: `try { local → if(isConnected) { remote } } catch { log warning }` → siempre retornan `Right` (`notification_repository_impl.dart:28-412`)
- `deleteNotification` NO toma snapshot antes de borrar - si el remoto falla, el dato se pierde localmente (`notification_repository_impl.dart:175-215`)
- `deleteAllNotifications` SI lee los datos antes de borrar (`getNotificationsForUser` en linea 367) pero nunca los usa para rollback
- `markAllNotificationsAsRead` NO captura cuales notificaciones eran unread antes del cambio (`notification_repository_impl.dart:132-172`)
- `markNotificationAsRead` y `markAsUnread` tienen la notificacion original en scope pero no la usan para rollback
- `NotificationRemoteDataSource` retorna `Either<Failure, T>` en todos sus metodos → usamos `.fold()` para rollback (no try-catch)
- `NotificationLocalDataSource` retorna `Future<void>` (puede lanzar excepciones de Isar, pero en practica es extremadamente raro)
- Ya existen 4 repos migrados con este patron: `ProjectsRepositoryImpl`, `AudioTrackRepositoryImpl`, `PlaylistRepositoryImpl`, `UserProfileRepositoryImpl`

## Desired End State

Despues de completar este plan:

1. `NotificationRepositoryImpl` usa patron **optimistic update + rollback** para las 6 operaciones de escritura
2. Si el remoto falla en cualquier escritura, el cambio local se revierte y se retorna `Left(failure)` al caller
3. Las operaciones de lectura (`watchNotifications`, `getNotificationById`, `syncNotificationsFromRemote`) NO cambian
4. El contrato `NotificationRepository` NO cambia (mismas firmas publicas)
5. Los metodos helper privados `markNotificationAsRead` y `markAllNotificationsAsRead` se eliminan (codigo inlined en los `@override`)

### Como verificar:
- `flutter analyze` pasa sin errores
- La app compila y ejecuta correctamente
- Al crear/marcar/borrar una notificacion con conexion: cambio persiste
- Al crear/marcar/borrar una notificacion sin conexion: cambio aparece brevemente, se revierte (rollback visible), y se retorna error al caller

## What We're NOT Doing

- No modificamos el contrato `NotificationRepository` (mismas firmas publicas)
- No modificamos `NotificationRemoteDataSource` ni `NotificationLocalDataSource`
- No cambiamos los metodos de lectura (`watchNotifications`, `watchUnreadNotifications`, `getNotificationById`, etc.)
- No cambiamos `syncNotificationsFromRemote()` (se mantiene como esta)
- No eliminamos `NotificationIncrementalSyncService` (placeholder, se puede limpiar en otro momento)
- No eliminamos `NetworkStateManager` del constructor (lo sigue usando `syncNotificationsFromRemote`)
- No agregamos background revalidation a las lecturas (puede ser un refactor futuro)
- No migramos otros features

## Implementation Approach

**Patron de escritura (igual que Projects/AudioTrack):**
1. Snapshot del estado previo (para rollback)
2. Aplicar cambio en local inmediatamente (optimistic)
3. Llamar al remoto directamente (sin check de conectividad)
4. Si remoto falla → restaurar snapshot (rollback) + return `Left(failure)`
5. Si remoto tiene exito → return `Right(result)`

**Batch operations** (`markAllAsRead`, `deleteAllNotifications`):
- Si CUALQUIER operacion remota del batch falla → rollback de TODO el batch

---

## Phase 1: Refactorizar NotificationRepositoryImpl

### Overview
Reescribir los 6 metodos de escritura para seguir el patron online-first optimistic con rollback. Eliminar los metodos helper privados redundantes.

### Changes Required:

#### 1. Imports y cleanup de metodos privados
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Eliminar los metodos privados `markNotificationAsRead()` (lineas 75-130) y `markAllNotificationsAsRead()` (lineas 132-172). Su logica se inlinea en los `@override`.

---

#### 2. createNotification - Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar metodo completo (lineas 28-73)

```dart
@override
Future<Either<Failure, Notification>> createNotification(
  Notification notification,
) async {
  final notificationDto = NotificationDto.fromDomain(notification);

  // 1. Optimistic: cache locally for immediate feedback
  await _localDataSource.cacheNotification(notificationDto);

  // 2. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.createNotification(
    notificationDto,
  );

  return remoteResult.fold(
    (failure) {
      // 3. Rollback: remove optimistic cache
      _localDataSource.deleteNotification(notification.id.value);
      return Left(failure);
    },
    (_) => Right(notification),
  );
}
```

**Cambios clave vs actual:**
- Eliminado: `try-catch` externo
- Eliminado: `if (isConnected)` guard
- Eliminado: `AppLogger.warning` que tragaba el error
- Agregado: rollback via `deleteNotification` en el fold de failure
- Cambiado: retorna `Left(failure)` en vez de `Right(notification)` cuando falla

---

#### 3. markAsRead - Snapshot + Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar `markAsRead` (lineas 294-298) y eliminar `markNotificationAsRead` (lineas 75-130)

```dart
@override
Future<Either<Failure, Notification>> markAsRead(
  NotificationId notificationId,
) async {
  // 1. Snapshot for rollback
  final prevDto = await _localDataSource.getNotificationById(
    notificationId.value,
  );

  if (prevDto == null) {
    return Left(ServerFailure('Notification not found'));
  }

  final originalNotification = prevDto.toDomain();

  // 2. Optimistic: mark as read locally
  final readNotification = originalNotification.markAsRead();
  final readDto = NotificationDto.fromDomain(readNotification);
  await _localDataSource.updateNotification(readDto);

  // 3. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.updateNotification(readDto);

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore original state
      _localDataSource.updateNotification(prevDto);
      return Left(failure);
    },
    (_) => Right(readNotification),
  );
}
```

**Cambios clave vs actual:**
- Snapshot via `_localDataSource.getNotificationById()` directo (no pasa por `getNotificationById` del repo que podria hacer un round-trip remoto)
- Rollback con el `prevDto` original
- Sin `try-catch`, sin `isConnected` check
- Metodo privado `markNotificationAsRead` eliminado

---

#### 4. markAsUnread - Snapshot + Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar metodo completo (lineas 300-356)

```dart
@override
Future<Either<Failure, Notification>> markAsUnread(
  NotificationId notificationId,
) async {
  // 1. Snapshot for rollback
  final prevDto = await _localDataSource.getNotificationById(
    notificationId.value,
  );

  if (prevDto == null) {
    return Left(ServerFailure('Notification not found'));
  }

  final originalNotification = prevDto.toDomain();

  // 2. Optimistic: mark as unread locally
  final unreadNotification = originalNotification.markAsUnread();
  final unreadDto = NotificationDto.fromDomain(unreadNotification);
  await _localDataSource.updateNotification(unreadDto);

  // 3. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.updateNotification(unreadDto);

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore original state
      _localDataSource.updateNotification(prevDto);
      return Left(failure);
    },
    (_) => Right(unreadNotification),
  );
}
```

---

#### 5. markAllAsRead - Batch Snapshot + Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar `markAllAsRead` (lineas 358-361) y eliminar `markAllNotificationsAsRead` (lineas 132-172)

```dart
@override
Future<Either<Failure, Unit>> markAllAsRead(UserId userId) async {
  // 1. Snapshot: capture all unread notifications for rollback
  final unreadDtos = await _localDataSource.getUnreadNotificationsForUser(
    userId.value,
  );

  if (unreadDtos.isEmpty) {
    return const Right(unit);
  }

  // 2. Optimistic: mark all as read locally
  await _localDataSource.markAllNotificationsAsRead(userId.value);

  // 3. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.markAllNotificationsAsRead(
    userId.value,
  );

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: restore all original DTOs (with isRead=false)
      for (final dto in unreadDtos) {
        _localDataSource.updateNotification(dto);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

**Cambios clave vs actual:**
- Snapshot via `getUnreadNotificationsForUser()` ANTES del `markAllNotificationsAsRead` local
- Early return si no hay unread (evita llamada remota innecesaria)
- Rollback: re-inserta cada DTO original (con `isRead: false`)
- Metodo privado `markAllNotificationsAsRead` eliminado

---

#### 6. deleteNotification - Snapshot + Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar metodo completo (lineas 174-215)

```dart
@override
Future<Either<Failure, Unit>> deleteNotification(
  NotificationId notificationId,
) async {
  // 1. Snapshot for rollback (CRITICAL: must read before delete)
  final prevDto = await _localDataSource.getNotificationById(
    notificationId.value,
  );

  // 2. Optimistic: delete locally
  await _localDataSource.deleteNotification(notificationId.value);

  // 3. Persist to remote (source of truth)
  final remoteResult = await _remoteDataSource.deleteNotification(
    notificationId.value,
  );

  return remoteResult.fold(
    (failure) {
      // 4. Rollback: re-insert notification
      if (prevDto != null) {
        _localDataSource.cacheNotification(prevDto);
      }
      return Left(failure);
    },
    (_) => const Right(unit),
  );
}
```

**Cambios clave vs actual:**
- NUEVO: snapshot via `getNotificationById` ANTES del delete (el actual no tenia esto)
- Rollback via `cacheNotification(prevDto)` que re-inserta en Isar

---

#### 7. deleteAllNotifications - Batch Snapshot + Optimistic + Rollback
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
**Changes**: Reemplazar metodo completo (lineas 364-412)

```dart
@override
Future<Either<Failure, Unit>> deleteAllNotifications(UserId userId) async {
  // 1. Snapshot for rollback
  final notifications = await _localDataSource.getNotificationsForUser(
    userId.value,
  );

  if (notifications.isEmpty) {
    return const Right(unit);
  }

  // 2. Optimistic: delete all locally
  for (final notification in notifications) {
    await _localDataSource.deleteNotification(notification.id);
  }

  // 3. Persist to remote (source of truth) - fail fast on first error
  for (final notification in notifications) {
    final remoteResult = await _remoteDataSource.deleteNotification(
      notification.id,
    );

    if (remoteResult.isLeft()) {
      // 4. Rollback: re-insert ALL notifications
      for (final dto in notifications) {
        await _localDataSource.cacheNotification(dto);
      }
      return remoteResult.fold(
        (failure) => Left(failure),
        (_) => const Right(unit),
      );
    }
  }

  return const Right(unit);
}
```

**Cambios clave vs actual:**
- Early return si la lista esta vacia
- Fail-fast: si CUALQUIER delete remoto falla, rollback de TODO el batch
- El snapshot (`notifications`) ya existia en el codigo actual pero nunca se usaba para rollback

---

#### 8. Metodos que NO cambian
Los siguientes metodos se mantienen exactamente como estan:

| Metodo | Razon |
|--------|-------|
| `getNotificationById()` | Lectura local + fallback remoto |
| `watchNotifications()` | Stream de Isar (local only) |
| `watchUnreadNotifications()` | Stream de Isar (local only) |
| `getUnreadNotificationsCount()` | Lectura local |
| `getTotalNotificationsCount()` | Lectura local |
| `syncNotificationsFromRemote()` | Pull manual desde Firebase (mantener como esta) |
| `syncNotificationFromRemote()` | Helper privado para fallback remoto |
| `_shouldUpdateNotification()` | Helper privado de sync |

---

#### 9. Archivo final completo
**File**: `lib/core/notifications/data/repositories/notification_repository_impl.dart`

El archivo final tendra esta estructura:

```dart
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/core/network/network_state_manager.dart';
import 'package:trackflow/core/notifications/data/datasources/notification_local_datasource.dart';
import 'package:trackflow/core/notifications/data/datasources/notification_remote_datasource.dart';
import 'package:trackflow/core/notifications/data/models/notification_dto.dart';
import 'package:trackflow/core/notifications/domain/entities/notification.dart';
import 'package:trackflow/core/notifications/domain/entities/notification_id.dart';
import 'package:trackflow/core/notifications/domain/repositories/notification_repository.dart';
import 'package:trackflow/core/utils/app_logger.dart';

@LazySingleton(as: NotificationRepository)
class NotificationRepositoryImpl implements NotificationRepository {
  NotificationRepositoryImpl(
    this._localDataSource,
    this._remoteDataSource,
    this._networkStateManager,
  );

  final NotificationLocalDataSource _localDataSource;
  final NotificationRemoteDataSource _remoteDataSource;
  final NetworkStateManager _networkStateManager;

  // ============================================================
  // WRITE METHODS (Online-First Optimistic + Rollback)
  // ============================================================

  // createNotification        → Optimistic + Rollback (no snapshot needed)
  // markAsRead                → Snapshot + Optimistic + Rollback
  // markAsUnread              → Snapshot + Optimistic + Rollback
  // markAllAsRead             → Batch Snapshot + Optimistic + Rollback
  // deleteNotification        → Snapshot + Optimistic + Rollback
  // deleteAllNotifications    → Batch Snapshot + Optimistic + Rollback

  // ============================================================
  // READ METHODS (unchanged - local streams + sync pull)
  // ============================================================

  // getNotificationById       → Local first + remote fallback
  // watchNotifications        → Isar stream
  // watchUnreadNotifications  → Isar stream
  // getUnreadNotificationsCount → Local count
  // getTotalNotificationsCount  → Local count
  // syncNotificationsFromRemote → Pull from Firebase to local cache
}
```

### Success Criteria:

#### Automated Verification:
- [x] `flutter analyze` pasa sin errores
- [ ] La app compila: `flutter build apk --debug` o `flutter run`
- [x] No existen los metodos privados `markNotificationAsRead()` ni `markAllNotificationsAsRead()` en el archivo
- [x] Ningun metodo de escritura contiene `AppLogger.warning('Failed to sync...')` ni `AppLogger.warning('Background sync failed...')`
- [x] Ningun metodo de escritura contiene `_networkStateManager.isConnected` (solo los metodos de lectura/sync lo usan)

#### Manual Verification:
- [ ] Crear notificacion con conexion: persiste en local y remoto
- [ ] Crear notificacion sin conexion: aparece brevemente, desaparece al fallar (rollback)
- [ ] Marcar como leida con conexion: cambio persiste
- [ ] Marcar como leida sin conexion: cambio se revierte (rollback)
- [ ] Borrar notificacion con conexion: desaparece permanentemente
- [ ] Borrar notificacion sin conexion: reaparece al fallar (rollback)
- [ ] Mark all as read con conexion: todas se marcan como leidas
- [ ] Mark all as read sin conexion: todas se revierten a su estado original (rollback)
- [ ] Las lecturas (watchNotifications, syncFromRemote) siguen funcionando igual

---

## Diagrama del Nuevo Flujo

```
ESCRITURAS (create / markAsRead / markAsUnread / delete)
══════════════════════════════════════════════════════════

┌─────────────┐
│ User Action │
└──────┬──────┘
       ▼
┌──────────────────────────────────────────────────┐
│      NotificationRepositoryImpl                   │
│                                                   │
│  1. Snapshot estado previo (update/delete only)   │
│     _localDataSource.getNotificationById()        │
│                    │                              │
│  2. Aplicar cambio en local     ◄── OPTIMISTIC    │
│     (cacheNotification / updateNotification /     │
│      deleteNotification)                          │
│                    │                              │
│  3. Llamar remoto (Firebase)    ◄── SOURCE OF     │
│     (sin check de conectividad)      TRUTH        │
│                    │                              │
│              ┌─────┴─────┐                        │
│              ▼           ▼                        │
│         SUCCESS       FAILURE                     │
│              │           │                        │
│  4a. return      4b. ROLLBACK                     │
│      Right          (restaurar                    │
│                      snapshot)                    │
│                      return Left                  │
└──────────────────────────────────────────────────┘


BATCH OPERATIONS (markAllAsRead / deleteAll)
════════════════════════════════════════════

┌─────────────┐
│ User Action │
└──────┬──────┘
       ▼
┌──────────────────────────────────────────────────┐
│      NotificationRepositoryImpl                   │
│                                                   │
│  1. Snapshot: leer TODOS los items afectados      │
│     (getUnreadNotifications / getNotifications)   │
│                    │                              │
│  2. Aplicar cambio batch en local ◄── OPTIMISTIC  │
│                    │                              │
│  3. Llamar remoto batch           ◄── SOURCE OF   │
│     (fail-fast on first error)         TRUTH      │
│                    │                              │
│              ┌─────┴─────┐                        │
│         ALL SUCCESS    ANY FAILURE                │
│              │           │                        │
│  4a. return      4b. ROLLBACK TODO                │
│      Right          (re-insert ALL                │
│                      snapshots)                   │
│                      return Left                  │
└──────────────────────────────────────────────────┘


LECTURAS (sin cambios)
══════════════════════

┌─────────────┐
│  UI Request │
└──────┬──────┘
       ▼
┌──────────────────────────────────────────────────┐
│      NotificationRepositoryImpl                   │
│                                                   │
│  watchNotifications()                             │
│    └─ _localDataSource.watchNotificationsForUser()│
│       └─ Isar stream (fireImmediately: true)      │
│                                                   │
│  syncNotificationsFromRemote()                    │
│    └─ if (isConnected)                            │
│       └─ remote.getNotificationsForUser()         │
│       └─ merge into local cache                   │
└──────────────────────────────────────────────────┘
```

## Rollback por metodo

| Metodo | Snapshot | Operacion local | Operacion remota | Rollback si falla |
|--------|----------|-----------------|------------------|-------------------|
| `createNotification` | No necesario (nuevo) | `cacheNotification(dto)` | `createNotification(dto)` | `deleteNotification(id)` |
| `markAsRead` | `getNotificationById(id)` → `prevDto` | `updateNotification(readDto)` | `updateNotification(readDto)` | `updateNotification(prevDto)` |
| `markAsUnread` | `getNotificationById(id)` → `prevDto` | `updateNotification(unreadDto)` | `updateNotification(unreadDto)` | `updateNotification(prevDto)` |
| `markAllAsRead` | `getUnreadNotificationsForUser(userId)` → `List<DTO>` | `markAllNotificationsAsRead(userId)` | `markAllNotificationsAsRead(userId)` | `updateNotification(dto)` x N |
| `deleteNotification` | `getNotificationById(id)` → `prevDto` | `deleteNotification(id)` | `deleteNotification(id)` | `cacheNotification(prevDto)` |
| `deleteAllNotifications` | `getNotificationsForUser(userId)` → `List<DTO>` | `deleteNotification(id)` x N | `deleteNotification(id)` x N | `cacheNotification(dto)` x N |

## Performance Considerations

- **Escrituras**: bloquean hasta que el remoto responde (trade-off vs la version actual que retornaba inmediato). La UI muestra el resultado optimista inmediatamente pero el `Future` del BLoC no completa hasta tener confirmacion o rollback.
- **Lecturas**: sin cambio de performance. Siguen retornando datos locales al instante.
- **Snapshot overhead**: una lectura extra a Isar por operacion de escritura. Isar es local y extremadamente rapido (<1ms), asi que el overhead es despreciable.
- **Batch rollback**: en el peor caso, `markAllAsRead` con muchas notificaciones requiere N writes individuales para rollback. En practica, los usuarios tienen pocas decenas de notificaciones.

## Migration Notes

- El contrato `NotificationRepository` no cambia → los use cases, BLoCs, `NotificationService`, y todos los callers NO necesitan modificacion.
- La DI NO necesita regenerarse (mismas dependencias en el constructor: `_localDataSource`, `_remoteDataSource`, `_networkStateManager`).
- Los callers que hoy asumen que las escrituras siempre retornan `Right` ahora podrian recibir `Left`. Verificar que los BLoCs y use cases manejan el caso de fallo correctamente (spoiler: ya lo hacen, tienen states de error).

## References

- Repositorio actual: `lib/core/notifications/data/repositories/notification_repository_impl.dart`
- Patron de referencia (Projects): `lib/features/projects/data/repositories/projects_repository_impl.dart`
- Patron de referencia (AudioTrack): `lib/features/audio_track/data/repositories/audio_track_repository_impl.dart`
- Plan de migracion Projects: `docs/plans/2026-02-20-projects-online-first-optimistic.md`
- Plan de migracion AudioTrack: `docs/plans/2026-02-20-audio-track-online-first-optimistic.md`
- Diagrama de notificaciones: `.vscode/notification_architecture.md`
