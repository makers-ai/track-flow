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

  @override
  Future<Either<Failure, Notification>> markAsRead(
    NotificationId notificationId,
  ) async {
    // 1. Snapshot for rollback
    final prevDto = await _localDataSource.getNotificationById(notificationId.value);

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

  @override
  Future<Either<Failure, Notification>> markAsUnread(
    NotificationId notificationId,
  ) async {
    // 1. Snapshot for rollback
    final prevDto = await _localDataSource.getNotificationById(notificationId.value);

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

  @override
  Future<Either<Failure, Unit>> markAllAsRead(UserId userId) async {
    // 1. Snapshot: capture all unread notifications for rollback
    final unreadDtos = await _localDataSource.getUnreadNotificationsForUser(userId.value);

    if (unreadDtos.isEmpty) {
      return const Right(unit);
    }

    // 2. Optimistic: mark all as read locally
    await _localDataSource.markAllNotificationsAsRead(userId.value);

    // 3. Persist to remote (source of truth)
    final remoteResult = await _remoteDataSource.markAllNotificationsAsRead(userId.value);

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

  @override
  Future<Either<Failure, Unit>> deleteNotification(
    NotificationId notificationId,
  ) async {
    // 1. Snapshot for rollback (CRITICAL: must read before delete)
    final prevDto = await _localDataSource.getNotificationById(notificationId.value);

    // 2. Optimistic: delete locally
    await _localDataSource.deleteNotification(notificationId.value);

    // 3. Persist to remote (source of truth)
    final remoteResult = await _remoteDataSource.deleteNotification(notificationId.value);

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

  // ============================================================
  // READ METHODS (unchanged - local streams + sync pull)
  // ============================================================

  @override
  Future<Either<Failure, Notification?>> getNotificationById(
    NotificationId notificationId,
  ) async {
    try {
      // Try to get from local cache first
      final localNotification = await _localDataSource.getNotificationById(
        notificationId.value,
      );

      if (localNotification != null) {
        return Right(localNotification.toDomain());
      }

      // If not in local cache, try to sync from remote
      final syncResult = await syncNotificationFromRemote(notificationId);
      return syncResult.fold(
        (failure) => Left(failure),
        (notification) => Right(notification),
      );
    } catch (e) {
      return Left(ServerFailure('Failed to get notification: $e'));
    }
  }

  @override
  Stream<Either<Failure, List<Notification>>> watchNotifications(
    UserId userId,
  ) async* {
    try {
      // Return local data immediately
      await for (final dtos in _localDataSource.watchNotificationsForUser(
        userId.value,
      )) {
        yield Right(dtos.map((dto) => dto.toDomain()).toList());
      }
    } catch (e) {
      yield Left(DatabaseFailure('Failed to watch notifications: $e'));
    }
  }

  @override
  Stream<Either<Failure, List<Notification>>> watchUnreadNotifications(
    UserId userId,
  ) async* {
    try {
      // Return local data immediately
      await for (final dtos in _localDataSource.watchUnreadNotificationsForUser(
        userId.value,
      )) {
        yield Right(dtos.map((dto) => dto.toDomain()).toList());
      }
    } catch (e) {
      yield Left(DatabaseFailure('Failed to watch unread notifications: $e'));
    }
  }

  @override
  Future<Either<Failure, int>> getUnreadNotificationsCount(
    UserId userId,
  ) async {
    try {
      // Get count from local cache
      final count = await _localDataSource.getUnreadNotificationsCount(
        userId.value,
      );
      return Right(count);
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to get unread notifications count: $e'),
      );
    }
  }

  @override
  Future<Either<Failure, int>> getTotalNotificationsCount(UserId userId) async {
    try {
      // Get all notifications for the user
      final notifications = await _localDataSource.getNotificationsForUser(
        userId.value,
      );
      return Right(notifications.length);
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to get total notifications count: $e'),
      );
    }
  }

  // ============================================================
  // SYNC METHODS (unchanged - pull from remote to local cache)
  // ============================================================

  Future<Either<Failure, Notification?>> syncNotificationFromRemote(
    NotificationId notificationId,
  ) async {
    try {
      final isConnected = await _networkStateManager.isConnected;
      if (!isConnected) {
        return Left(DatabaseFailure('No internet connection'));
      }

      // Get notification from remote data source
      final remoteResult = await _remoteDataSource.getNotificationById(
        notificationId.value,
      );

      return remoteResult.fold((failure) => Left(failure), (
        remoteNotification,
      ) async {
        // Cache the notification locally
        await _localDataSource.cacheNotification(remoteNotification);
        return Right(remoteNotification.toDomain());
      });
    } catch (e) {
      return Left(
        DatabaseFailure('Failed to sync notification from remote: $e'),
      );
    }
  }

  @override
  Future<Either<Failure, Unit>> syncNotificationsFromRemote(
    UserId userId,
  ) async {
    try {
      // Check if we have network connectivity
      final isConnected = await _networkStateManager.isConnected;
      if (!isConnected) {
        AppLogger.warning(
          'No network connection - skipping notification sync',
          tag: 'NotificationRepository',
        );
        return Left(NetworkFailure('No network connection available'));
      }

      AppLogger.info(
        'Starting notification sync from remote for user: ${userId.value}',
        tag: 'NotificationRepository',
      );

      // Fetch all notifications for the user from remote
      final remoteResult = await _remoteDataSource.getNotificationsForUser(
        userId.value,
      );

      return remoteResult.fold(
        (failure) {
          AppLogger.warning(
            'Failed to fetch notifications from remote: ${failure.message}',
            tag: 'NotificationRepository',
          );
          return Left(failure);
        },
        (remoteNotifications) async {
          // Get existing local notifications for comparison
          final localNotifications = await _localDataSource.getNotificationsForUser(userId.value);

          // Create a map of local notifications by ID for quick lookup
          final localNotificationMap = <String, NotificationDto>{
            for (final notification in localNotifications) notification.id: notification,
          };

          int newCount = 0;
          int updatedCount = 0;

          // Process each remote notification
          for (final remoteNotification in remoteNotifications) {
            final localNotification = localNotificationMap[remoteNotification.id];

            if (localNotification == null) {
              // New notification - cache it locally
              await _localDataSource.cacheNotification(remoteNotification);
              newCount++;
            } else {
              // Check if remote notification is newer or different
              final remoteTimestamp = remoteNotification.timestamp;
              final localTimestamp = localNotification.timestamp;

              // Update if remote is newer, but preserve local read status
              // unless it was explicitly changed remotely
              if (remoteTimestamp.isAfter(localTimestamp) ||
                  _shouldUpdateNotification(localNotification, remoteNotification)) {
                // Preserve local read status if it was marked as read locally
                // but remote shows unread (user read it locally but sync hadn't happened)
                final updatedNotification = remoteNotification.copyWith(
                  isRead: localNotification.isRead || remoteNotification.isRead,
                );

                await _localDataSource.updateNotification(updatedNotification);
                updatedCount++;
              }
            }
          }

          AppLogger.info(
            'Notification sync completed - New: $newCount, Updated: $updatedCount',
            tag: 'NotificationRepository',
          );

          return Right(unit);
        },
      );
    } catch (e) {
      AppLogger.error(
        'Notification sync failed: $e',
        tag: 'NotificationRepository',
        error: e,
      );
      return Left(ServerFailure('Failed to sync notifications: $e'));
    }
  }

  /// Helper method to determine if a notification should be updated
  /// based on content changes, not just timestamp
  bool _shouldUpdateNotification(
    NotificationDto local,
    NotificationDto remote,
  ) {
    // Update if title, body, or payload changed
    return local.title != remote.title ||
        local.body != remote.body ||
        local.payload.toString() != remote.payload.toString();
  }
}
