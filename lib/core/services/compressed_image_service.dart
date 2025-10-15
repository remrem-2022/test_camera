import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const String baseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: kIsWeb ? 'http://localhost:3000' : 'http://10.0.2.2:3000',
);

class CompressedImageService {
  // Singleton pattern
  static final CompressedImageService _instance =
      CompressedImageService._internal();
  factory CompressedImageService() => _instance;
  CompressedImageService._internal();

  // In-memory cache using blob-like storage
  final Map<String, Uint8List> _imageCache = {};

  /// Fetch compressed image from file_url_id using the file_retrieve route
  Future<Uint8List?> fetchCompressedImageById(String fileUrlId) async {
    debugPrint('🔍 Fetching compressed image for file_url_id: $fileUrlId');

    // Check cache first
    if (_imageCache.containsKey(fileUrlId)) {
      debugPrint('✅ Image found in cache');
      return _imageCache[fileUrlId];
    }

    try {
      final uri = Uri.parse(
          '$baseUrl/LTLFiles/file/file_retrieve_compressed/$fileUrlId');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);

        if (jsonResponse['success'] == true && jsonResponse['data'] != null) {
          // Decode base64 data
          final base64Data = jsonResponse['data'] as String;
          final bytes = base64.decode(base64Data);

          final sizeMB = bytes.length / 1024 / 1024;
          debugPrint(
              '✅ Fetched compressed image: ${sizeMB.toStringAsFixed(2)} MB');

          // Cache the bytes
          _imageCache[fileUrlId] = bytes;

          return bytes;
        } else {
          debugPrint('❌ Invalid response format or no data');
          return null;
        }
      } else {
        debugPrint('❌ Failed to fetch image: HTTP ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error fetching compressed image: $e');
      return null;
    }
  }

  /// Fetch compressed image directly from URL (for compressurl from response)
  Future<Uint8List?> fetchCompressedImageFromUrl(String compressurl) async {
    debugPrint('🔍 Fetching compressed image from URL: $compressurl');

    // Check cache first
    if (_imageCache.containsKey(compressurl)) {
      debugPrint('✅ Image found in cache');
      return _imageCache[compressurl];
    }

    try {
      final response = await http.get(Uri.parse(compressurl));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        final sizeMB = bytes.length / 1024 / 1024;
        debugPrint('✅ Fetched image: ${sizeMB.toStringAsFixed(2)} MB');

        // Cache the bytes
        _imageCache[compressurl] = bytes;

        return bytes;
      } else {
        debugPrint('❌ Failed to fetch image: HTTP ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error fetching compressed image: $e');
      return null;
    }
  }

  /// Clear cache for specific key (fileUrlId or URL)
  void clearCache(String key) {
    _imageCache.remove(key);
    debugPrint('🗑️ Cleared cache for: $key');
  }

  /// Clear all cache
  void clearAllCache() {
    _imageCache.clear();
    debugPrint('🗑️ Cleared all image cache');
  }

  /// Get cache size in bytes
  int getCacheSize() {
    int totalBytes = 0;
    for (var bytes in _imageCache.values) {
      totalBytes += bytes.length;
    }
    return totalBytes;
  }

  /// Get cache size in MB
  double getCacheSizeMB() {
    return getCacheSize() / 1024 / 1024;
  }
}
