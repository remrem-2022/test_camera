import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:image_picker/image_picker.dart';

const String baseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: kIsWeb ? 'http://localhost:3000' : 'http://10.0.2.2:3000',
);

class FileUploadService {
  // Singleton pattern
  static final FileUploadService _instance = FileUploadService._internal();
  factory FileUploadService() => _instance;
  FileUploadService._internal();

  /// Upload packing list image and return file_url_id
  Future<String?> uploadPackingListImage(XFile image) async {
    try {
      debugPrint('📤 Uploading packing list image: ${image.name}');

      final uri = Uri.parse('$baseUrl/LTLFiles/uploadFile');
      final request = http.MultipartRequest('POST', uri);

      // Read image bytes
      final bytes = await image.readAsBytes();

      // Add image file to request
      request.files.add(
        http.MultipartFile.fromBytes('image', bytes, filename: image.name),
      );

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        final fileUrlId = jsonResponse['file_url_id'] as String?;

        if (fileUrlId != null) {
          debugPrint('✅ Upload successful: $fileUrlId');
          return fileUrlId;
        } else {
          debugPrint('❌ No file_url_id in response');
          return null;
        }
      } else {
        debugPrint('❌ Upload failed: HTTP ${response.statusCode}');
        debugPrint('Response: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error uploading packing list image: $e');
      return null;
    }
  }

  /// Upload multiple images and return list of file_url_ids
  Future<List<String>> uploadMultipleImages(List<XFile> images) async {
    final List<String> fileIds = [];

    for (var image in images) {
      final fileId = await uploadPackingListImage(image);
      if (fileId != null) {
        fileIds.add(fileId);
      }
    }

    return fileIds;
  }
}
