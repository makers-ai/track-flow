import 'package:equatable/equatable.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/features/track_version/presentation/models/track_version_ui_model.dart';

abstract class TrackVersionsState extends Equatable {
  const TrackVersionsState();

  @override
  List<Object?> get props => [];
}

class TrackVersionsInitial extends TrackVersionsState {
  const TrackVersionsInitial();
}

class TrackVersionsLoading extends TrackVersionsState {
  const TrackVersionsLoading();
}

class TrackVersionsLoaded extends TrackVersionsState {
  final List<TrackVersionUiModel> versions;
  final TrackVersionId? activeVersionId;
  final bool isUploading;
  final bool uploadSuccess;

  const TrackVersionsLoaded({
    required this.versions,
    this.activeVersionId,
    this.isUploading = false,
    this.uploadSuccess = false,
  });

  TrackVersionsLoaded copyWith({
    List<TrackVersionUiModel>? versions,
    TrackVersionId? activeVersionId,
    bool? isUploading,
    bool? uploadSuccess,
  }) {
    return TrackVersionsLoaded(
      versions: versions ?? this.versions,
      activeVersionId: activeVersionId ?? this.activeVersionId,
      isUploading: isUploading ?? this.isUploading,
      uploadSuccess: uploadSuccess ?? this.uploadSuccess,
    );
  }

  @override
  List<Object?> get props => [versions, activeVersionId, isUploading, uploadSuccess];
}

class TrackVersionsError extends TrackVersionsState {
  final String message;
  const TrackVersionsError(this.message);

  @override
  List<Object?> get props => [message];
}
