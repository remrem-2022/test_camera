// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
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
  List<Uint8List> _capturedImageBytes = [];
  List<String> _uploadedFileIds = [];

  // UI State
  bool _showCamera = false;
  bool _showPreview = false;
  bool _isUploadingAll = false;
  String _uploadProgress = '';
  int _currentPreviewIndex = -1;

  // Camera
  late html.VideoElement _videoElement;
  html.MediaStream? _cameraStream;
  bool _isCameraReady = false;
  String _videoElementId =
      'camera-video-${DateTime.now().millisecondsSinceEpoch}';
  int _cameraRebuildKey = 0;
  String? _currentDeviceId;
  List<html.MediaDeviceInfo> _availableCameras = [];
  bool _hasMultipleCameras = false;
  int _currentCameraIndex = 0;
  bool _isSwitchingCamera = false;
  bool _isInitializing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCamera();
    });
  }

  @override
  void dispose() {
    _stopCameraStream();
    super.dispose();
  }

  // ==================== CAMERA SETUP ====================

  Future<void> _initializeCamera() async {
    if (_isInitializing) return;

    setState(() {
      _isInitializing = true;
    });

    try {
      await _enumerateCameras();
      if (_availableCameras.isNotEmpty) {
        _setupCameraElement();
      } else {
        debugPrint('❌ No cameras found');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No cameras found on this device'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to initialize camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to initialize camera: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  Future<void> _enumerateCameras() async {
    try {
      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        debugPrint('⚠️ MediaDevices not available');
        return;
      }

      html.MediaStream? permissionStream;
      try {
        debugPrint('🔐 Requesting camera permission for enumeration...');
        permissionStream = await mediaDevices.getUserMedia({
          'video': true,
          'audio': false,
        });
        debugPrint('✅ Camera permission granted');
      } catch (e) {
        debugPrint('⚠️ Failed to get camera permission: $e');
        return;
      }

      final devices = await mediaDevices.enumerateDevices();

      if (permissionStream != null) {
        permissionStream.getTracks().forEach((track) => track.stop());
        debugPrint('🛑 Permission stream stopped');
      }

      _availableCameras = devices
          .whereType<html.MediaDeviceInfo>()
          .where((device) => device.kind == 'videoinput')
          .toList();

      debugPrint('📹 Found ${_availableCameras.length} camera(s):');
      for (var i = 0; i < _availableCameras.length; i++) {
        final camera = _availableCameras[i];
        debugPrint('  [$i] ${camera.label} (ID: ${camera.deviceId})');
      }

      if (_availableCameras.isEmpty) {
        debugPrint('❌ No cameras found!');
        return;
      }

      int? camera2_0_index;
      int? anyBackCameraIndex;

      for (var i = 0; i < _availableCameras.length; i++) {
        final label = _availableCameras[i].label?.toLowerCase() ?? '';

        if (label.contains('camera2 0') && label.contains('back')) {
          camera2_0_index = i;
          break;
        }

        if (anyBackCameraIndex == null) {
          if (label.contains('camera 0') && label.contains('back')) {
            anyBackCameraIndex = i;
          } else if (label.contains('back') || label.contains('environment')) {
            anyBackCameraIndex = i;
          }
        }
      }

      if (camera2_0_index != null) {
        _currentCameraIndex = camera2_0_index;
        debugPrint(
          '🎯 Starting with main back camera (camera2 0) at index $_currentCameraIndex',
        );
      } else if (anyBackCameraIndex != null) {
        _currentCameraIndex = anyBackCameraIndex;
        debugPrint(
          '🎯 Starting with back camera at index $_currentCameraIndex',
        );
      } else {
        _currentCameraIndex = 0;
        debugPrint(
          '🎯 Starting with first available camera at index $_currentCameraIndex',
        );
      }

      _hasMultipleCameras = _availableCameras.length > 1;

      if (_hasMultipleCameras) {
        debugPrint('✅ Multiple cameras available - flip button will be shown');
      } else {
        debugPrint('⚠️ Only one camera available - flip button will be hidden');
      }
    } catch (e) {
      debugPrint('❌ Error enumerating cameras: $e');
      rethrow;
    }
  }

  void _setupCameraElement() {
    setState(() {
      _showCamera = true;
    });

    final newVideoElementId =
        'camera-video-${DateTime.now().millisecondsSinceEpoch}';

    _videoElement = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      newVideoElementId,
      (int viewId) => _videoElement,
    );

    setState(() {
      _videoElementId = newVideoElementId;
      _cameraRebuildKey++;
    });

    debugPrint('✅ Video element registered: $newVideoElementId');

    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      debugPrint('🎥 Starting camera...');

      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        throw Exception('Camera API not available');
      }

      _stopCameraStream();

      if (_availableCameras.isNotEmpty &&
          _currentCameraIndex < _availableCameras.length) {
        final selectedCamera = _availableCameras[_currentCameraIndex];
        debugPrint(
          '📸 Requesting camera by deviceId: ${selectedCamera.deviceId}',
        );
        debugPrint('   Camera: ${selectedCamera.label}');

        try {
          _cameraStream = await mediaDevices.getUserMedia({
            'video': {
              'deviceId': {'exact': selectedCamera.deviceId},
              'width': {'ideal': 1920},
              'height': {'ideal': 1080},
            },
          });
          debugPrint('✅ Got camera: ${selectedCamera.label}');
        } catch (e) {
          debugPrint('⚠️ Failed to get camera by deviceId: $e');
          throw Exception('Failed to access camera: ${selectedCamera.label}');
        }
      } else {
        debugPrint('📸 Requesting default camera');
        _cameraStream = await mediaDevices.getUserMedia({
          'video': {
            'width': {'ideal': 1920},
            'height': {'ideal': 1080},
          },
        });
      }

      _videoElement.srcObject = null;
      await Future.delayed(const Duration(milliseconds: 50));
      _videoElement.srcObject = _cameraStream;

      await _videoElement.play();
      await Future.delayed(const Duration(milliseconds: 200));

      if (_cameraStream != null) {
        final tracks = _cameraStream!.getVideoTracks();
        if (tracks.isNotEmpty) {
          final track = tracks.first;
          final settings = track.getSettings();
          debugPrint('📹 Camera track settings: ${settings.toString()}');
          debugPrint('📹 Actual facingMode: ${settings['facingMode']}');

          final deviceId = settings['deviceId'] as String?;
          _currentDeviceId = deviceId;
          debugPrint('📹 Device ID: $deviceId');
        }
      }

      if (mounted) {
        setState(() {
          _isCameraReady = true;
        });
      }

      debugPrint(
        '✅ Camera ready (${_videoElement.videoWidth}x${_videoElement.videoHeight})',
      );
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      if (mounted) {
        setState(() {
          _isCameraReady = false;
        });
      }
      rethrow;
    }
  }

  void _stopCameraStream() {
    if (_cameraStream != null) {
      _cameraStream!.getTracks().forEach((track) => track.stop());
      _cameraStream = null;
      debugPrint('🛑 Camera stream stopped');
    }
  }

  // ==================== CAMERA SWITCHING ====================

  Future<void> _selectCamera(int cameraIndex) async {
    if (_isSwitchingCamera) {
      debugPrint('⚠️ Already switching camera, ignoring request');
      return;
    }

    if (cameraIndex < 0 || cameraIndex >= _availableCameras.length) {
      debugPrint('⚠️ Invalid camera index: $cameraIndex');
      return;
    }

    if (cameraIndex == _currentCameraIndex) {
      debugPrint('⚠️ Already on camera index $cameraIndex');
      return;
    }

    debugPrint('📹 Selecting camera index $cameraIndex');

    setState(() {
      _isSwitchingCamera = true;
    });

    _stopCameraStream();
    _videoElement.srcObject = null;

    setState(() {
      _currentCameraIndex = cameraIndex;
      _isCameraReady = false;
      _showCamera = false;
    });

    await Future.delayed(const Duration(milliseconds: 300));

    try {
      await _setupCameraElementWithTimeout();
    } catch (e) {
      debugPrint('❌ Failed to switch camera: $e');

      if (mounted) {
        setState(() {
          _isCameraReady = false;
          _showCamera = false;
        });

        final shouldRetry = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Camera Initialization Failed'),
            content: Text(
              'Failed to initialize ${_availableCameras[cameraIndex].label}.\n\n'
              'This camera might not be available or is being used by another app.\n\n'
              'Would you like to try a different camera?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Try Different Camera'),
              ),
            ],
          ),
        );

        if (shouldRetry == true) {
          _tryNextAvailableCamera();
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSwitchingCamera = false;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (!_hasMultipleCameras || _availableCameras.isEmpty) {
      debugPrint('⚠️ Cannot switch - no cameras available');
      return;
    }

    if (_isSwitchingCamera) {
      debugPrint('⚠️ Already switching camera');
      return;
    }

    debugPrint('🔄 Switching camera...');

    final nextIndex = (_currentCameraIndex + 1) % _availableCameras.length;
    await _selectCamera(nextIndex);
  }

  Future<void> _setupCameraElementWithTimeout() async {
    setState(() {
      _showCamera = true;
    });

    final newVideoElementId =
        'camera-video-${DateTime.now().millisecondsSinceEpoch}';

    _videoElement = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    // ignore: undefined_prefixed_name
    ui_web.platformViewRegistry.registerViewFactory(
      newVideoElementId,
      (int viewId) => _videoElement,
    );

    setState(() {
      _videoElementId = newVideoElementId;
      _cameraRebuildKey++;
    });

    debugPrint('✅ Video element registered: $newVideoElementId');

    await _startCamera().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('⏱️ Camera initialization timeout');
        _stopCameraStream();
        throw TimeoutException(
          'Camera initialization took too long (>10 seconds)',
        );
      },
    );
  }

  Future<void> _tryNextAvailableCamera() async {
    final startIndex = _currentCameraIndex;

    for (int attempt = 0; attempt < _availableCameras.length; attempt++) {
      _currentCameraIndex =
          (startIndex + attempt + 1) % _availableCameras.length;

      debugPrint(
        '🔄 Trying camera index $_currentCameraIndex (${_availableCameras[_currentCameraIndex].label})',
      );

      setState(() {
        _isCameraReady = false;
        _showCamera = false;
        _isSwitchingCamera = true;
      });

      await Future.delayed(const Duration(milliseconds: 100));

      try {
        await _setupCameraElementWithTimeout();
        debugPrint('✅ Successfully switched to camera $_currentCameraIndex');
        setState(() {
          _isSwitchingCamera = false;
        });
        return;
      } catch (e) {
        debugPrint('❌ Failed to initialize camera $_currentCameraIndex: $e');
      }
    }

    setState(() {
      _isSwitchingCamera = false;
    });

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No Available Cameras'),
          content: const Text(
            'Unable to initialize any camera. Please check your camera permissions and try again.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  // ==================== SHOW CAMERA MENU ====================

  void _showCameraSelectionMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(Icons.videocam, size: 24),
                    const SizedBox(width: 12),
                    const Text(
                      'Select Camera',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Camera list
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _availableCameras.length,
                itemBuilder: (context, index) {
                  final camera = _availableCameras[index];
                  final isSelected = index == _currentCameraIndex;
                  final label = camera.label ?? 'Camera $index';

                  return InkWell(
                    onTap: () {
                      Navigator.pop(context);
                      if (index != _currentCameraIndex) {
                        _selectCamera(index);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Colors.blue.withOpacity(0.1)
                            : Colors.transparent,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.camera_alt,
                            color: isSelected ? Colors.blue : Colors.grey[600],
                            size: 22,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isSelected ? Colors.blue : Colors.black,
                              ),
                            ),
                          ),
                          if (isSelected)
                            const Icon(
                              Icons.check_circle,
                              color: Colors.blue,
                              size: 22,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
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

      final blob = await canvas.toBlob('image/jpeg', 0.95);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'packing_list_$timestamp.jpg';

      final bytes = await _blobToBytes(blob);

      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'image/jpeg',
      );

      _stopCameraStream();

      _capturedImages.add(xFile);
      _capturedImageBytes.add(bytes);
      _uploadedFileIds.add('');

      setState(() {
        _isCameraReady = false;
        _showCamera = false;
        _showPreview = true;
        _currentPreviewIndex = _capturedImages.length - 1;
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
    if (_currentPreviewIndex >= 0 &&
        _currentPreviewIndex < _capturedImages.length) {
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

    setState(() {
      _showPreview = false;
      _currentPreviewIndex = -1;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  // ==================== BATCH UPLOAD ====================

  Future<void> _uploadAllImages() async {
    if (_capturedImages.isEmpty) return;

    setState(() {
      _isUploadingAll = true;
    });

    try {
      for (int i = 0; i < _capturedImages.length; i++) {
        if (_uploadedFileIds[i].isNotEmpty) {
          debugPrint('⏭️ Skipping image $i (already uploaded)');
          continue;
        }

        setState(() {
          _uploadProgress =
              'Uploading ${i + 1} of ${_capturedImages.length}...';
        });

        debugPrint('📤 Uploading image ${i + 1}/${_capturedImages.length}');

        try {
          final fileId = await _uploadService.uploadPackingListImage(
            _capturedImages[i],
          );

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

          if (mounted) {
            final shouldContinue = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Upload Failed'),
                content: Text(
                  'Failed to upload image ${i + 1}.\n\nError: $e\n\nContinue uploading remaining images?',
                ),
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

  void _resetCameraState() {
    _stopCameraStream();
    if (_videoElement.srcObject != null) {
      _videoElement.srcObject = null;
    }

    setState(() {
      _isCameraReady = false;
      _showCamera = false;
    });
  }

  Future<void> _done() async {
    _resetCameraState();

    if (_capturedImages.isEmpty) {
      Navigator.pop(context);
      return;
    }

    final hasPendingUploads = _uploadedFileIds.any((id) => id.isEmpty);

    if (hasPendingUploads) {
      try {
        await _uploadAllImages();

        if (mounted) {
          Navigator.pop(context, {
            'images': _capturedImages,
            'fileIds': _uploadedFileIds,
            'compressedUrls': List.filled(_uploadedFileIds.length, ''),
          });
        }
      } catch (e) {
        if (mounted) {
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Upload Incomplete'),
              content: const Text(
                'Some images were not uploaded. Exit anyway?',
              ),
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
      Navigator.pop(context, {
        'images': _capturedImages,
        'fileIds': _uploadedFileIds,
        'compressedUrls': List.filled(_uploadedFileIds.length, ''),
      });
    }
  }

  Future<void> _back() async {
    _resetCameraState();

    if (_capturedImages.isEmpty) {
      Navigator.pop(context);
      return;
    }

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
        actions: [
          if (_showCamera && _availableCameras.length > 1)
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: (_isUploadingAll || _isSwitchingCamera)
                  ? null
                  : _showCameraSelectionMenu,
              tooltip: 'Select Camera',
            ),
        ],
      ),
      body: Column(
        children: [
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
              key: ValueKey('$_videoElementId-$_cameraRebuildKey'),
              viewType: _videoElementId,
            ),
            if (_hasMultipleCameras)
              Positioned(
                top: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _isSwitchingCamera ? null : _switchCamera,
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
    if (_currentPreviewIndex < 0 ||
        _currentPreviewIndex >= _capturedImageBytes.length) {
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
      buttons.add(
        ElevatedButton(
          onPressed: (_isUploadingAll || !_isCameraReady || _isSwitchingCamera)
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
