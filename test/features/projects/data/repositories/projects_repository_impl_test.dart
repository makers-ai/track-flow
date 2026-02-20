import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/error/failures.dart';
import 'package:trackflow/features/projects/data/datasources/project_local_data_source.dart';
import 'package:trackflow/features/projects/data/datasources/project_remote_data_source.dart';
import 'package:trackflow/features/projects/data/models/project_dto.dart';
import 'package:trackflow/features/projects/data/repositories/projects_repository_impl.dart';
import 'package:trackflow/features/projects/domain/entities/project.dart';

import 'projects_repository_impl_test.mocks.dart';

@GenerateMocks([ProjectsLocalDataSource, ProjectRemoteDataSource])
void main() {
  late ProjectsRepositoryImpl repository;
  late MockProjectsLocalDataSource mockLocalDataSource;
  late MockProjectRemoteDataSource mockRemoteDataSource;

  late Project testProject;
  late ProjectDTO testDto;
  late ProjectDTO remoteDtoResponse;

  setUp(() {
    mockLocalDataSource = MockProjectsLocalDataSource();
    mockRemoteDataSource = MockProjectRemoteDataSource();

    repository = ProjectsRepositoryImpl(
      localDataSource: mockLocalDataSource,
      remoteDataSource: mockRemoteDataSource,
    );

    testProject = Project(
      id: ProjectId.fromUniqueString('test-project-id'),
      ownerId: UserId.fromUniqueString('test-owner-id'),
      name: ProjectName('Test Project'),
      description: ProjectDescription('Test Description'),
      createdAt: DateTime(2025, 1, 1),
    );

    testDto = ProjectDTO(
      id: 'test-project-id',
      ownerId: 'test-owner-id',
      name: 'Test Project',
      description: 'Test Description',
      createdAt: DateTime(2025, 1, 1),
    );

    remoteDtoResponse = ProjectDTO(
      id: 'test-project-id',
      ownerId: 'test-owner-id',
      name: 'Test Project',
      description: 'Test Description',
      createdAt: DateTime(2025, 1, 1),
      updatedAt: DateTime(2025, 1, 1, 0, 0, 1),
    );
  });

  // ---------------------------------------------------------------------------
  // createProject
  // ---------------------------------------------------------------------------
  group('createProject', () {
    test('should cache locally, call remote, then update cache on success',
        () async {
      // Arrange
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.createProject(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));

      // Act
      final result = await repository.createProject(testProject);

      // Assert
      expect(result.isRight(), true);

      // Verify: 1) optimistic cache, 2) remote call, 3) cache updated with remote response
      final verifications = verifyInOrder([
        mockLocalDataSource.cacheProject(any),
        mockRemoteDataSource.createProject(any),
        mockLocalDataSource.cacheProject(any),
      ]);
      for (final v in verifications) {
        v.called(1);
      }
    });

    test('should rollback local cache when remote fails', () async {
      // Arrange
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.createProject(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));
      when(mockLocalDataSource.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.createProject(testProject);

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );

      // Verify rollback was called
      verify(mockLocalDataSource.removeCachedProject('test-project-id'))
          .called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // updateProject
  // ---------------------------------------------------------------------------
  group('updateProject', () {
    test(
        'should snapshot previous, cache new, call remote, return success',
        () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.updateProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.updateProject(testProject);

      // Assert
      expect(result.isRight(), true);
      verify(mockRemoteDataSource.updateProject(any)).called(1);
    });

    test('should rollback to previous snapshot when remote fails', () async {
      // Arrange
      final previousDto = testDto.copyWith(name: 'Old Name');
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(previousDto));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.updateProject(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.updateProject(testProject);

      // Assert
      expect(result.isLeft(), true);

      // Verify: optimistic cache + rollback cache (2 calls to cacheProject)
      verify(mockLocalDataSource.cacheProject(any)).called(2);
    });

    test('should not rollback when no previous snapshot exists', () async {
      // Arrange - getCachedProject returns failure (no snapshot)
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => const Left(CacheFailure('Not found')));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.updateProject(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.updateProject(testProject);

      // Assert
      expect(result.isLeft(), true);

      // Only 1 call to cacheProject (optimistic), no rollback
      verify(mockLocalDataSource.cacheProject(any)).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // deleteProject
  // ---------------------------------------------------------------------------
  group('deleteProject', () {
    test('should remove from cache optimistically then call remote', () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocalDataSource.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.deleteProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.deleteProject(testProject);

      // Assert
      expect(result.isRight(), true);
      verify(mockLocalDataSource.removeCachedProject('test-project-id'))
          .called(1);
      verify(mockRemoteDataSource.deleteProject('test-project-id')).called(1);
    });

    test('should rollback (re-cache) when remote delete fails', () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      when(mockLocalDataSource.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.deleteProject(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.deleteProject(testProject);

      // Assert
      expect(result.isLeft(), true);

      // Verify rollback: re-cache the original DTO
      verify(mockLocalDataSource.cacheProject(testDto)).called(1);
    });

    test('should not rollback when no snapshot exists for delete', () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => const Left(CacheFailure('Not found')));
      when(mockLocalDataSource.removeCachedProject(any))
          .thenAnswer((_) async => const Right(unit));
      when(mockRemoteDataSource.deleteProject(any))
          .thenAnswer((_) async => const Left(ServerFailure('Remote failed')));

      // Act
      final result = await repository.deleteProject(testProject);

      // Assert
      expect(result.isLeft(), true);

      // No rollback (cacheProject not called)
      verifyNever(mockLocalDataSource.cacheProject(any));
    });
  });

  // ---------------------------------------------------------------------------
  // getProjectById
  // ---------------------------------------------------------------------------
  group('getProjectById', () {
    test('should return local project when cache hit (not deleted)', () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(testDto));
      // Mock revalidation calls (fire-and-forget)
      when(mockRemoteDataSource.getProjectById(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-project-id'),
      );

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (project) => expect(project.id.value, 'test-project-id'),
      );
    });

    test('should skip cache and fetch from remote when project is deleted',
        () async {
      // Arrange
      final deletedDto = testDto.copyWith(isDeleted: true);
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => Right(deletedDto));
      when(mockRemoteDataSource.getProjectById(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-project-id'),
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockRemoteDataSource.getProjectById('test-project-id')).called(1);
    });

    test('should fetch from remote when not in local cache', () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => const Right(null));
      when(mockRemoteDataSource.getProjectById(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-project-id'),
      );

      // Assert
      expect(result.isRight(), true);
      verify(mockRemoteDataSource.getProjectById('test-project-id')).called(1);
      // Should cache remote result
      verify(mockLocalDataSource.cacheProject(remoteDtoResponse)).called(1);
    });

    test('should return failure when remote also fails on cache miss',
        () async {
      // Arrange
      when(mockLocalDataSource.getCachedProject(any))
          .thenAnswer((_) async => const Right(null));
      when(mockRemoteDataSource.getProjectById(any)).thenAnswer(
          (_) async => const Left(ServerFailure('Project not found')));

      // Act
      final result = await repository.getProjectById(
        ProjectId.fromUniqueString('test-project-id'),
      );

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Should have returned failure'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // watchLocalProjects
  // ---------------------------------------------------------------------------
  group('watchLocalProjects', () {
    test('should return stream from local data source', () async {
      // Arrange
      when(mockLocalDataSource.watchAllProjects(any)).thenAnswer(
        (_) => Stream.value(Right([testDto])),
      );
      // Mock revalidation (fire-and-forget)
      when(mockRemoteDataSource.getUserProjects(any))
          .thenAnswer((_) async => Right([testDto]));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final stream = repository.watchLocalProjects(
        UserId.fromUniqueString('test-owner-id'),
      );
      final result = await stream.first;

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (projects) {
          expect(projects.length, 1);
          expect(projects.first.id.value, 'test-project-id');
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  // watchProjectById
  // ---------------------------------------------------------------------------
  group('watchProjectById', () {
    test('should return stream from local data source', () async {
      // Arrange
      when(mockLocalDataSource.watchProjectById(any)).thenAnswer(
        (_) => Stream.value(Right(testDto)),
      );
      // Mock revalidation (fire-and-forget)
      when(mockRemoteDataSource.getProjectById(any))
          .thenAnswer((_) async => Right(remoteDtoResponse));
      when(mockLocalDataSource.cacheProject(any))
          .thenAnswer((_) async => const Right(unit));

      // Act
      final stream = repository.watchProjectById(
        ProjectId.fromUniqueString('test-project-id'),
      );
      final result = await stream.first;

      // Assert
      expect(result.isRight(), true);
      result.fold(
        (_) => fail('Should have returned success'),
        (project) {
          expect(project, isNotNull);
          expect(project!.id.value, 'test-project-id');
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  // clearLocalCache
  // ---------------------------------------------------------------------------
  group('clearLocalCache', () {
    test('should delegate to local data source', () async {
      // Arrange
      when(mockLocalDataSource.clearCache())
          .thenAnswer((_) async => const Right(unit));

      // Act
      final result = await repository.clearLocalCache();

      // Assert
      expect(result.isRight(), true);
      verify(mockLocalDataSource.clearCache()).called(1);
    });

    test('should return failure when local data source throws', () async {
      // Arrange
      when(mockLocalDataSource.clearCache())
          .thenThrow(Exception('Database error'));

      // Act
      final result = await repository.clearLocalCache();

      // Assert
      expect(result.isLeft(), true);
      result.fold(
        (failure) => expect(failure, isA<DatabaseFailure>()),
        (_) => fail('Should have returned failure'),
      );
    });
  });
}
