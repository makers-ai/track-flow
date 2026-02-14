import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:dartz/dartz.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/user_profile/domain/entities/user_profile.dart';
import 'package:trackflow/features/user_profile/data/datasources/user_profile_local_datasource.dart';
import 'package:trackflow/features/user_profile/data/datasources/user_profile_remote_datasource.dart';
import 'package:trackflow/features/user_profile/data/models/user_profile_dto.dart';
import 'package:trackflow/features/user_profile/data/repositories/user_profile_repository_impl.dart';

import 'user_profile_repository_impl_test.mocks.dart';

@GenerateMocks([UserProfileLocalDataSource, UserProfileRemoteDataSource])
void main() {
  late UserProfileRepositoryImpl repository;
  late MockUserProfileLocalDataSource mockLocalDataSource;
  late MockUserProfileRemoteDataSource mockRemoteDataSource;

  late UserId testUserId;
  late UserProfileDTO testDto;
  late UserProfileDTO remoteDtoWithHttpAvatar;

  setUp(() {
    mockLocalDataSource = MockUserProfileLocalDataSource();
    mockRemoteDataSource = MockUserProfileRemoteDataSource();

    repository = UserProfileRepositoryImpl(
      mockLocalDataSource,
      mockRemoteDataSource,
    );

    testUserId = UserId.fromUniqueString('user-123');

    testDto = UserProfileDTO(
      id: 'user-123',
      name: 'Test User',
      email: 'test@example.com',
      avatarUrl: '',
      createdAt: DateTime(2024, 1, 1),
      creativeRole: CreativeRole.producer,
    );

    remoteDtoWithHttpAvatar = UserProfileDTO(
      id: 'user-123',
      name: 'Test User',
      email: 'test@example.com',
      avatarUrl: 'https://firebase.storage/avatars/user-123/avatar.png',
      createdAt: DateTime(2024, 1, 1),
      creativeRole: CreativeRole.producer,
    );
  });

  group('UserProfileRepositoryImpl', () {
    group('updateUserProfile', () {
      test(
        'should write locally first, then succeed on remote, then merge remote DTO back',
        () async {
          // Arrange
          final profile = testDto.toDomain();

          when(mockLocalDataSource.watchUserProfile(any))
              .thenAnswer((_) => Stream.value(testDto));
          when(mockLocalDataSource.cacheUserProfile(any))
              .thenAnswer((_) async {});
          when(mockRemoteDataSource.updateProfile(any))
              .thenAnswer((_) async => Right(remoteDtoWithHttpAvatar));

          // Act
          final result = await repository.updateUserProfile(profile);

          // Assert
          expect(result.isRight(), true);
          // cacheUserProfile called twice: optimistic write + merge remote
          verify(mockLocalDataSource.cacheUserProfile(any)).called(2);
          verify(mockRemoteDataSource.updateProfile(any)).called(1);
        },
      );

      test('should rollback to snapshot when remote fails', () async {
        // Arrange
        final profile = testDto.toDomain();
        final snapshotDto = testDto.copyWith(name: 'Original Name');

        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(snapshotDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});
        when(mockRemoteDataSource.updateProfile(any))
            .thenAnswer((_) async => Left(ServerFailure('Remote failed')));

        // Act
        final result = await repository.updateUserProfile(profile);

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );

        // cacheUserProfile called twice: optimistic write + rollback
        verify(mockLocalDataSource.cacheUserProfile(any)).called(2);
      });
    });

    group('getUserProfile', () {
      test('should return local cache when found', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(testDto));
        when(mockRemoteDataSource.getProfileById(any))
            .thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});

        // Act
        final result = await repository.getUserProfile(testUserId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (profile) {
            expect(profile, isNotNull);
            expect(profile!.name, 'Test User');
          },
        );
      });

      test('should fetch from remote when not in local cache', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(null));
        when(mockRemoteDataSource.getProfileById(any))
            .thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});

        // Act
        final result = await repository.getUserProfile(testUserId);

        // Assert
        expect(result.isRight(), true);
        verify(mockRemoteDataSource.getProfileById('user-123')).called(1);
        verify(mockLocalDataSource.cacheUserProfile(testDto)).called(1);
      });

      test(
        'should trigger background remote revalidation when cache hit',
        () async {
          // Arrange
          when(mockLocalDataSource.watchUserProfile(any))
              .thenAnswer((_) => Stream.value(testDto));
          when(mockRemoteDataSource.getProfileById(any))
              .thenAnswer((_) async => Right(remoteDtoWithHttpAvatar));
          when(mockLocalDataSource.cacheUserProfile(any))
              .thenAnswer((_) async {});

          // Act
          await repository.getUserProfile(testUserId);

          // Wait for fire-and-forget to complete
          await Future.delayed(const Duration(milliseconds: 100));

          // Assert: remote was called for revalidation
          verify(mockRemoteDataSource.getProfileById('user-123')).called(1);
        },
      );
    });

    group('findUserByEmail', () {
      test('should return local when found', () async {
        // Arrange
        when(mockLocalDataSource.findUserByEmail(any))
            .thenAnswer((_) async => testDto);

        // Act
        final result = await repository.findUserByEmail('test@example.com');

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (profile) {
            expect(profile, isNotNull);
            expect(profile!.email, 'test@example.com');
          },
        );
        verifyNever(mockRemoteDataSource.findUserByEmail(any));
      });

      test('should fallback to remote when not local', () async {
        // Arrange
        when(mockLocalDataSource.findUserByEmail(any))
            .thenAnswer((_) async => null);
        when(mockRemoteDataSource.findUserByEmail(any))
            .thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});

        // Act
        final result = await repository.findUserByEmail('test@example.com');

        // Assert
        expect(result.isRight(), true);
        verify(mockRemoteDataSource.findUserByEmail('test@example.com'))
            .called(1);
        verify(mockLocalDataSource.cacheUserProfile(testDto)).called(1);
      });
    });

    group('profileExists', () {
      test('should return true when found locally', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(testDto));

        // Act
        final result = await repository.profileExists(testUserId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (exists) => expect(exists, true),
        );
        verifyNever(mockRemoteDataSource.getProfileById(any));
      });

      test('should check remote when not local', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(null));
        when(mockRemoteDataSource.getProfileById(any))
            .thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});

        // Act
        final result = await repository.profileExists(testUserId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (exists) => expect(exists, true),
        );
        verify(mockRemoteDataSource.getProfileById('user-123')).called(1);
      });

      test('should return false when not found remotely', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.value(null));
        when(mockRemoteDataSource.getProfileById(any)).thenAnswer(
          (_) async => Left(DatabaseFailure('Not found')),
        );

        // Act
        final result = await repository.profileExists(testUserId);

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (exists) => expect(exists, false),
        );
      });
    });

    group('syncProfileFromRemote', () {
      test('should fetch remote and cache locally', () async {
        // Arrange
        when(mockRemoteDataSource.getProfileById(any))
            .thenAnswer((_) async => Right(testDto));
        when(mockLocalDataSource.cacheUserProfile(any))
            .thenAnswer((_) async {});

        // Act
        final result = await repository.syncProfileFromRemote(testUserId);

        // Assert
        expect(result.isRight(), true);
        verify(mockRemoteDataSource.getProfileById('user-123')).called(1);
        verify(mockLocalDataSource.cacheUserProfile(testDto)).called(1);
      });

      test('should return failure when remote fails', () async {
        // Arrange
        when(mockRemoteDataSource.getProfileById(any))
            .thenAnswer((_) async => Left(ServerFailure('Network error')));

        // Act
        final result = await repository.syncProfileFromRemote(testUserId);

        // Assert
        expect(result.isLeft(), true);
        result.fold(
          (failure) => expect(failure, isA<ServerFailure>()),
          (_) => fail('Should have returned failure'),
        );
      });
    });

    group('clearProfileCache', () {
      test('should delegate to local datasource', () async {
        // Arrange
        when(mockLocalDataSource.clearCache()).thenAnswer((_) async {});

        // Act
        final result = await repository.clearProfileCache();

        // Assert
        expect(result.isRight(), true);
        verify(mockLocalDataSource.clearCache()).called(1);
      });
    });

    group('watchUserProfile', () {
      test('should delegate to local datasource stream', () async {
        // Arrange
        when(mockLocalDataSource.watchUserProfile(any))
            .thenAnswer((_) => Stream.fromIterable([testDto]));

        // Act
        final stream = repository.watchUserProfile(testUserId);
        final result = await stream.first;

        // Assert
        expect(result.isRight(), true);
        result.fold(
          (_) => fail('Should have returned success'),
          (profile) {
            expect(profile, isNotNull);
            expect(profile!.name, 'Test User');
          },
        );
      });
    });
  });
}
