// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../core/services/file_upload_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final FileUploadService _uploadService = FileUploadService();

  // Storage arrays for captured pages
  List<XFile> _capturedImages = [];
  List<Uint8List> _capturedImageBytes = []; // Store original bytes for preview
  List<String> _uploadedFileIds = []; // Empty string = pending, fileId = uploaded

  // UI State
  bool _showCamera = false;
  bool _showPreview = false;
  bool _isUploadingAll = false; // For batch upload
  String _uploadProgress = ''; // e.g., "Uploading 1 of 3"
  int _currentPreviewIndex = -1; // Index of image being previewed

  // Camera
  late html.VideoElement _videoElement;
  html.MediaStream? _cameraStream;
  bool _isCameraReady = false;
  final String _videoElementId =
      'camera-video-${DateTime.now().millisecondsSinceEpoch}';
  int _cameraRebuildKey = 0; // Key to force HtmlElementView rebuild
  String _facingMode = 'environment'; // 'environment' = back, 'user' = front
  String? _currentDeviceId; // Track current camera device ID

  @override
  void initState() {
    super.initState();
    // Start camera automatically for first page
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  @override
  void dispose() {
    _stopCameraStream();
    super.dispose();
  }

  // ==================== CAMERA SETUP ====================

  void _setupCameraElement() {
    if (!_showCamera) {
      setState(() {
        _showCamera = true;
      });
    }

    // Create video element once
    _videoElement = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    // Register view factory (only once)
    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      _videoElementId,
      (int viewId) => _videoElement,
    );

    debugPrint('✅ Video element registered');

    // Start camera
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      debugPrint('🎥 Starting camera...');

      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        throw Exception('Camera API not available');
      }

      // Stop existing stream if any
      _stopCameraStream();

      // Request camera access with current facing mode
      debugPrint('📸 Requesting camera with facingMode: $_facingMode');

      try {
        _cameraStream = await mediaDevices.getUserMedia({
          'video': {
            'facingMode': {'exact': _facingMode},
            'width': {'ideal': 1920},
            'height': {'ideal': 1080},
          },
        });
        debugPrint('✅ Got exact facingMode: $_facingMode');
      } catch (e) {
        debugPrint('⚠️ Exact facingMode failed, trying ideal: $e');
        // Fallback to ideal instead of exact
        try {
          _cameraStream = await mediaDevices.getUserMedia({
            'video': {
              'facingMode': {'ideal': _facingMode},
              'width': {'ideal': 1920},
              'height': {'ideal': 1080},
            },
          });
          debugPrint('✅ Got ideal facingMode: $_facingMode');
        } catch (e2) {
          debugPrint('⚠️ Ideal facingMode also failed, using any camera: $e2');
          // Last resort: any camera
          _cameraStream = await mediaDevices.getUserMedia({
            'video': {
              'width': {'ideal': 1920},
              'height': {'ideal': 1080},
            },
          });
        }
      }

      // Clear old stream and assign new one
      _videoElement.srcObject = null;
      await Future.delayed(const Duration(milliseconds: 50));
      _videoElement.srcObject = _cameraStream;

      // Play video
      await _videoElement.play();

      // Wait for video to be ready
      await Future.delayed(const Duration(milliseconds: 200));

      // Log camera track info
      if (_cameraStream != null) {
        final tracks = _cameraStream!.getVideoTracks();
        if (tracks.isNotEmpty) {
          final track = tracks.first;
          final settings = track.getSettings();
          debugPrint('📹 Camera track settings: ${settings.toString()}');
          debugPrint('📹 Actual facingMode: ${settings['facingMode']}');

          // Store current device ID
          final deviceId = settings['deviceId'] as String?;
          _currentDeviceId = deviceId;
          debugPrint('📹 Device ID: $deviceId');
        }
      }

      setState(() {
        _isCameraReady = true;
        _cameraRebuildKey++; // Increment to force widget rebuild
      });

      debugPrint(
        '✅ Camera ready (${_videoElement.videoWidth}x${_videoElement.videoHeight})',
      );
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      if (mounted) {
        setState(() {
          _isCameraReady = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _stopCameraStream() {
    if (_cameraStream != null) {
      _cameraStream!.getTracks().forEach((track) => track.stop());
      _cameraStream = null;
      debugPrint('🛑 Camera stream stopped');
    }
  }

  // ==================== CAPTURE & PREVIEW ====================

  Future<void> _captureImage() async {
    if (!_isCameraReady || _cameraStream == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera not ready'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      // Capture from video element
      final canvas = html.CanvasElement(
        width: _videoElement.videoWidth,
        height: _videoElement.videoHeight,
      );

      canvas.context2D.drawImageScaled(
        _videoElement,
        0,
        0,
        canvas.width!,
        canvas.height!,
      );

      // Convert to blob
      final blob = await canvas.toBlob('image/jpeg', 0.95);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'packing_list_$timestamp.jpg';

      // Convert to bytes
      final bytes = await _blobToBytes(blob);

      // Create XFile
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'image/jpeg',
      );

      // Stop camera and show preview
      _stopCameraStream();

      // Add to lists (no upload yet)
      _capturedImages.add(xFile);
      _capturedImageBytes.add(bytes); // Store original bytes for preview
      _uploadedFileIds.add(''); // Empty = pending upload

      setState(() {
        _isCameraReady = false;
        _showCamera = false;
        _showPreview = true;
        _currentPreviewIndex = _capturedImages.length - 1; // Preview the just-captured image
      });

      debugPrint('✅ Image captured (${_capturedImages.length} total)');
    } catch (e) {
      debugPrint('❌ Capture error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<Uint8List> _blobToBytes(html.Blob blob) async {
    final reader = html.FileReader();
    reader.readAsArrayBuffer(blob);
    await reader.onLoad.first;
    return Uint8List.fromList(reader.result as List<int>);
  }

  void _addPage() {
    debugPrint('📄 Adding new page...');
    setState(() {
      _showPreview = false;
      _currentPreviewIndex = -1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  void _deleteCurrentPreview() {
    if (_currentPreviewIndex >= 0 && _currentPreviewIndex < _capturedImages.length) {
      setState(() {
        _capturedImages.removeAt(_currentPreviewIndex);
        _capturedImageBytes.removeAt(_currentPreviewIndex);
        _uploadedFileIds.removeAt(_currentPreviewIndex);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image deleted'),
          duration: Duration(seconds: 1),
        ),
      );
    }

    // After deleting, hide preview and restart camera
    setState(() {
      _showPreview = false;
      _currentPreviewIndex = -1;
    });

    // Restart camera for next capture
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  Future<void> _switchCamera() async {
    final previousDeviceId = _currentDeviceId;
    debugPrint('🔄 Switching camera from $_facingMode (device: $previousDeviceId)');

    // Toggle between front and back camera
    setState(() {
      _facingMode = _facingMode == 'environment' ? 'user' : 'environment';
      _isCameraReady = false; // Show loading while switching
    });

    // Restart camera with new facing mode
    await _startCamera();

    // Check if camera actually changed
    if (_currentDeviceId == previousDeviceId && previousDeviceId != null) {
      debugPrint('⚠️ Camera did not switch - same device ID');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera switching not available on this device'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      debugPrint('✅ Camera switched to $_facingMode (device: $_currentDeviceId)');
    }
  }

  // ==================== BATCH UPLOAD ====================

  Future<void> _uploadAllImages() async {
    if (_capturedImages.isEmpty) return;

    setState(() {
      _isUploadingAll = true;
    });

    try {
      for (int i = 0; i < _capturedImages.length; i++) {
        // Skip if already uploaded
        if (_uploadedFileIds[i].isNotEmpty) {
          debugPrint('⏭️ Skipping image $i (already uploaded)');
          continue;
        }

        setState(() {
          _uploadProgress = 'Uploading ${i + 1} of ${_capturedImages.length}...';
        });

        debugPrint('📤 Uploading image ${i + 1}/${_capturedImages.length}');

        try {
          final fileId = await _uploadService.uploadPackingListImage(_capturedImages[i]);

          if (fileId != null) {
            setState(() {
              _uploadedFileIds[i] = fileId;
            });
            debugPrint('✅ Image ${i + 1} uploaded: $fileId');
          } else {
            throw Exception('Upload returned null for image ${i + 1}');
          }
        } catch (e) {
          debugPrint('❌ Failed to upload image ${i + 1}: $e');

          // Show error dialog and ask user if they want to continue
          if (mounted) {
            final shouldContinue = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Upload Failed'),
                content: Text('Failed to upload image ${i + 1}.\n\nError: $e\n\nContinue uploading remaining images?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            );

            if (shouldContinue != true) {
              throw Exception('Upload cancelled by user');
            }
          }
        }
      }

      debugPrint('✅ All uploads complete');
    } catch (e) {
      debugPrint('❌ Batch upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow;
    } finally {
      setState(() {
        _isUploadingAll = false;
        _uploadProgress = '';
      });
    }
  }

  // ==================== NAVIGATION ====================

  Future<void> _done() async {
    _stopCameraStream();

    if (_capturedImages.isEmpty) {
      Navigator.pop(context);
      return;
    }

    // Check if there are pending uploads
    final hasPendingUploads = _uploadedFileIds.any((id) => id.isEmpty);

    if (hasPendingUploads) {
      try {
        await _uploadAllImages();

        // After successful upload, return data
        if (mounted) {
          Navigator.pop(context, {
            'images': _capturedImages,
            'fileIds': _uploadedFileIds,
            'compressedUrls': List.filled(_uploadedFileIds.length, ''),
          });
        }
      } catch (e) {
        // Upload failed or cancelled, ask user what to do
        if (mounted) {
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Upload Incomplete'),
              content: const Text('Some images were not uploaded. Exit anyway?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Stay'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Exit'),
                ),
              ],
            ),
          );

          if (shouldExit == true && mounted) {
            Navigator.pop(context, {
              'images': _capturedImages,
              'fileIds': _uploadedFileIds,
              'compressedUrls': List.filled(_uploadedFileIds.length, ''),
            });
          }
        }
      }
    } else {
      // All already uploaded
      Navigator.pop(context, {
        'images': _capturedImages,
        'fileIds': _uploadedFileIds,
        'compressedUrls': List.filled(_uploadedFileIds.length, ''),
      });
    }
  }

  Future<void> _back() async {
    _stopCameraStream();

    if (_capturedImages.isEmpty) {
      Navigator.pop(context);
      return;
    }

    // Same logic as _done()
    await _done();
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        title: const Text('Capture Packing List'),
        backgroundColor: Colors.grey[300],
        foregroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _back,
        ),
      ),
      body: Column(
        children: [
          // Title
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _showCamera
                  ? _capturedImages.isEmpty
                        ? 'Capture packing list first page'
                        : 'Capturing page ${_capturedImages.length + 1}'
                  : _showPreview
                  ? 'Page ${_capturedImages.length} preview'
                  : '${_capturedImages.length} page(s) captured',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),

          // Camera / Preview / Loading
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black, width: 2),
                color: Colors.black,
              ),
              child: _buildMainContent(),
            ),
          ),

          // Buttons
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _buildButtons(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (_isUploadingAll) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              _uploadProgress.isNotEmpty ? _uploadProgress : 'Uploading...',
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ],
        ),
      );
    }

    if (_showPreview) {
      return _buildPreview();
    }

    if (_showCamera) {
      if (_isCameraReady) {
        return Stack(
          children: [
            HtmlElementView(
              key: ValueKey(_cameraRebuildKey),
              viewType: _videoElementId,
            ),
            // Camera flip button
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _switchCamera,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.flip_camera_android,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      } else {
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'Initializing camera...',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        );
      }
    }

    // Show placeholder when no camera is active
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.camera_alt, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            _capturedImages.isEmpty
                ? 'Click "add page" to start'
                : 'Click "add page" to capture next page',
            style: TextStyle(color: Colors.grey[600], fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_currentPreviewIndex < 0 || _currentPreviewIndex >= _capturedImageBytes.length) {
      return const Center(
        child: Text(
          'No preview available',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Stack(
      children: [
        SizedBox.expand(
          child: Image.memory(
            _capturedImageBytes[_currentPreviewIndex],
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _deleteCurrentPreview,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.8),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.delete, color: Colors.white, size: 24),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildButtons() {
    final buttons = <Widget>[];

    // Back button - always visible
    buttons.add(
      ElevatedButton(
        onPressed: _isUploadingAll ? null : _back,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          side: const BorderSide(color: Colors.black),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
        child: const Text('back'),
      ),
    );

    if (_showCamera) {
      // Camera is active: [back, capture]
      buttons.add(
        ElevatedButton(
          onPressed: (_isUploadingAll || !_isCameraReady)
              ? null
              : _captureImage,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('capture'),
        ),
      );
    } else if (_showPreview || _capturedImages.isNotEmpty) {
      // Preview is showing or have captures: [back, done, add page]
      buttons.add(
        ElevatedButton(
          onPressed: _isUploadingAll ? null : _done,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('done'),
        ),
      );

      buttons.add(
        ElevatedButton(
          onPressed: _isUploadingAll ? null : _addPage,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('add page'),
        ),
      );
    } else {
      // No captures yet: [back, add page]
      buttons.add(
        ElevatedButton(
          onPressed: _isUploadingAll ? null : _addPage,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            side: const BorderSide(color: Colors.black),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('add page'),
        ),
      );
    }

    return buttons;
  }
}
