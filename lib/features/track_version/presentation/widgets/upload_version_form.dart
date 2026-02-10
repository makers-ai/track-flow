import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:trackflow/core/entities/unique_id.dart';
import 'package:trackflow/core/theme/app_colors.dart';
import 'package:trackflow/core/theme/app_dimensions.dart';
import 'package:trackflow/features/track_version/presentation/blocs/track_versions/track_versions_bloc.dart';
import 'package:trackflow/features/track_version/presentation/blocs/track_versions/track_versions_event.dart';
import 'package:trackflow/features/track_version/presentation/blocs/track_versions/track_versions_state.dart';
import 'package:trackflow/features/ui/buttons/primary_button.dart';
import 'package:trackflow/features/ui/buttons/secondary_button.dart';
import 'package:trackflow/features/ui/forms/app_form_field.dart';

/// Styled upload version form aligned with TrackFlow UI/Theme
class UploadVersionForm extends StatefulWidget {
  final ProjectId projectId;
  final AudioTrackId trackId;

  const UploadVersionForm({
    super.key,
    required this.projectId,
    required this.trackId,
  });

  @override
  State<UploadVersionForm> createState() => _UploadVersionFormState();
}

class _UploadVersionFormState extends State<UploadVersionForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _labelController = TextEditingController();

  PlatformFile? _pickedFile;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m4a', 'mp3', 'wav', 'aac', 'aiff', 'caf'],
      allowMultiple: false,
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _pickedFile = result.files.first;
      });
    }
  }

  Future<File?> _materializePlatformFile(PlatformFile pf) async {
    if (pf.path != null && pf.path!.isNotEmpty) {
      final f = File(pf.path!);
      if (await f.exists()) return f;
    }

    final tempDir = await getTemporaryDirectory();
    final safeName = pf.name.isNotEmpty ? pf.name : 'audio_${DateTime.now().millisecondsSinceEpoch}';
    final ext = p.extension(safeName);
    final base = ext.isEmpty ? safeName : p.basenameWithoutExtension(safeName);
    final outPath = p.join(
      tempDir.path,
      '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final outFile = File(outPath);

    if (pf.bytes != null) {
      await outFile.writeAsBytes(pf.bytes!);
      return outFile;
    }

    if (pf.readStream != null) {
      final sink = outFile.openWrite();
      await sink.addStream(pf.readStream!);
      await sink.flush();
      await sink.close();
      return outFile;
    }

    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_pickedFile == null) {
      setState(() => _errorMessage = 'Please select an audio file.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final file = await _materializePlatformFile(_pickedFile!);

    if (!mounted) return;
    if (file == null) {
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Could not access selected audio file.';
      });
      return;
    }

    // Dispatch the event - the BlocListener will handle success/error
    context.read<TrackVersionsBloc>().add(
      AddTrackVersionRequested(
        trackId: widget.trackId,
        file: file,
        label: _labelController.text,
      ),
    );
    // Don't close here - wait for BLoC response via BlocListener
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<TrackVersionsBloc, TrackVersionsState>(
      listener: (context, state) {
        if (state is TrackVersionsLoaded) {
          if (state.uploadSuccess && !state.isUploading) {
            // Upload succeeded - close the bottom sheet
            setState(() => _isSubmitting = false);
            Navigator.of(context).pop();
          } else if (state.isUploading) {
            // Upload in progress
            setState(() => _isSubmitting = true);
          } else {
            setState(() => _isSubmitting = false);
          }
        } else if (state is TrackVersionsError) {
          // Upload failed - show error and allow retry
          setState(() {
            _isSubmitting = false;
            _errorMessage = state.message;
          });
        }
      },
      child: PopScope(
        canPop: !_isSubmitting,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _isSubmitting) {
            // User tried to close while uploading - show message
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Please wait while the version is uploading...'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IgnorePointer(
                ignoring: _isSubmitting,
                child: Opacity(
                  opacity: _isSubmitting ? 0.6 : 1.0,
                  child: AppFormField(
                    label: 'Version label (optional)',
                    hint: 'e.g., v2 - Final Mix, Remix',
                    controller: _labelController,
                  ),
                ),
              ),
              const SizedBox(height: Dimensions.space24),
              SecondaryButton(
                text: _pickedFile == null ? 'Select Audio File' : 'Change Audio File',
                icon: Icons.music_note,
                onPressed: _isSubmitting ? null : _pickFile,
                isDisabled: _isSubmitting,
              ),
              if (_pickedFile != null)
                Padding(
                  padding: const EdgeInsets.only(top: Dimensions.space8),
                  child: Text(
                    'Selected: ${_pickedFile!.name}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: Dimensions.space16),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: Dimensions.space32),
              PrimaryButton(
                text: _isSubmitting ? 'Uploading...' : 'Upload Version',
                onPressed: _isSubmitting ? null : _submit,
                isLoading: _isSubmitting,
              ),
              if (_isSubmitting)
                const Padding(
                  padding: EdgeInsets.only(top: Dimensions.space16),
                  child: Text(
                    'Please wait while your version is being uploaded.\nThis may take a moment.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
