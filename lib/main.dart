import 'package:flutter/material.dart';
import 'screens/camera_screen.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<dynamic>? _packingListImages;
  List<String>? _packingListFileIds;

  Future<void> _openCamera() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CameraScreen()),
    );

    if (result != null && result is Map<String, dynamic>) {
      setState(() {
        _packingListImages = result['images'];
        _packingListFileIds = result['fileIds'];
      });

      // Debug print
      debugPrint('📸 Received ${_packingListImages?.length ?? 0} images');
      debugPrint('🆔 File IDs: $_packingListFileIds');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Hello World!'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _openCamera,
              child: const Text('Open Camera'),
            ),
            if (_packingListFileIds != null &&
                _packingListFileIds!.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                'Captured ${_packingListFileIds!.length} images',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _packingListFileIds!.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      leading: const Icon(
                        Icons.check_circle,
                        color: Colors.green,
                      ),
                      title: Text('Page ${index + 1}'),
                      subtitle: Text('ID: ${_packingListFileIds![index]}'),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
