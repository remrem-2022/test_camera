// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../core/services/file_upload_service.dart';
import '../core/services/compressed_image_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final FileUploadService _uploadService = FileUploadService();
  final CompressedImageService _compressedImageService =
      CompressedImageService();

  // Storage arrays for captured pages
  List<XFile> _capturedImages = [];
  List<String> _uploadedFileIds = [];
  List<String> _compressedUrls = [];

  // UI State
  bool _isUploading = false;
  bool _showCamera = false; // Changed: control camera visibility
  bool _showPreview = false;
  String? _currentUploadingFileName;
  Uint8List? _previewImageBytes;
  String? _previewFileId;

  // Camera
  late html.VideoElement _videoElement;
  html.MediaStream? _cameraStream;
  bool _isCameraReady = false;
  final String _videoElementId =
      'camera-video-${DateTime.now().millisecondsSinceEpoch}';
  int _cameraRebuildKey = 0; // Key to force HtmlElementView rebuild

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

      // Request camera access
      try {
        // Try back camera first
        _cameraStream = await mediaDevices.getUserMedia({
          'video': {
            'facingMode': 'environment',
            'width': {'ideal': 1920},
            'height': {'ideal': 1080},
          },
        });
      } catch (e) {
        // Fallback to any camera
        _cameraStream = await mediaDevices.getUserMedia({
          'video': {
            'width': {'ideal': 1920},
            'height': {'ideal': 1080},
          },
        });
      }

      // Clear old stream and assign new one
      _videoElement.srcObject = null;
      await Future.delayed(const Duration(milliseconds: 50));
      _videoElement.srcObject = _cameraStream;

      // Play video
      await _videoElement.play();

      // Wait for video to be ready
      await Future.delayed(const Duration(milliseconds: 200));

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

  Future<void> _captureAndUpload() async {
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
      setState(() {
        _isUploading = true;
      });

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

      // Convert to XFile
      final bytes = await _blobToBytes(blob);
      final xFile = XFile.fromData(
        bytes,
        name: fileName,
        mimeType: 'image/jpeg',
      );

      setState(() {
        _currentUploadingFileName = fileName;
      });

      // Upload first (don't add to list yet)
      final fileId = await _uploadService.uploadPackingListImage(xFile);

      if (fileId != null) {
        debugPrint('✅ Uploaded: $fileId');

        // Fetch compressed preview
        final compressedBytes = await _compressedImageService
            .fetchCompressedImageById(fileId);

        // Stop camera and show preview
        _stopCameraStream();

        // Add to lists only after successful upload
        _capturedImages.add(xFile);
        _uploadedFileIds.add(fileId);
        _compressedUrls.add('');

        setState(() {
          _isCameraReady = false;
          _showCamera = false;
          _showPreview = true;
          _previewImageBytes = compressedBytes ?? bytes;
          _previewFileId = fileId;
          _currentUploadingFileName = null;
        });

        debugPrint('✅ Preview ready');
      } else {
        // Upload failed
        throw Exception('Upload failed');
      }
    } catch (e) {
      debugPrint('❌ Capture error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() {
        _isUploading = false;
      });
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
      _previewImageBytes = null;
      _previewFileId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  void _deleteCurrentPreview() {
    if (_previewFileId != null) {
      final index = _uploadedFileIds.indexOf(_previewFileId!);
      if (index != -1) {
        setState(() {
          _capturedImages.removeAt(index);
          _uploadedFileIds.removeAt(index);
          _compressedUrls.removeAt(index);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Image deleted'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }

    // After deleting, hide preview and restart camera
    setState(() {
      _showPreview = false;
      _previewImageBytes = null;
      _previewFileId = null;
    });

    // Restart camera for next capture
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCameraElement();
    });
  }

  // ==================== NAVIGATION ====================

  void _done() {
    _stopCameraStream();
    Navigator.pop(context, {
      'images': _capturedImages,
      'fileIds': _uploadedFileIds,
      'compressedUrls': _compressedUrls,
    });
  }

  void _back() {
    _stopCameraStream();
    // Return captured images even when going back
    if (_capturedImages.isNotEmpty) {
      Navigator.pop(context, {
        'images': _capturedImages,
        'fileIds': _uploadedFileIds,
        'compressedUrls': _compressedUrls,
      });
    } else {
      Navigator.pop(context);
    }
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
    if (_isUploading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              _currentUploadingFileName != null
                  ? 'Uploading $_currentUploadingFileName...'
                  : 'Processing...',
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
        return HtmlElementView(
          key: ValueKey(_cameraRebuildKey),
          viewType: _videoElementId,
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
    if (_previewImageBytes == null) {
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
            _previewImageBytes!,
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
        onPressed: _isUploading ? null : _back,
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
          onPressed: (_isUploading || !_isCameraReady)
              ? null
              : _captureAndUpload,
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
          onPressed: _isUploading ? null : _done,
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
          onPressed: _isUploading ? null : _addPage,
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
          onPressed: _isUploading ? null : _addPage,
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
