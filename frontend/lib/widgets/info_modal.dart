import 'package:flutter/material.dart';

class InfoModal extends StatelessWidget {
  const InfoModal({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 50,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 20),

            const Text(
              "About Dayaw",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.brown),
            ),
            const SizedBox(height: 10),
            const Text(
              "Dayaw is a Capstone project from Leyte Normal University (LNU) dedicated to preserving the ancient Filipino script through recognition.",
              style: TextStyle(fontSize: 15, color: Colors.black87),
            ),

            const Divider(height: 40),

            const Text(
              "How to Write for Baybayin",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.brown),
            ),
            const SizedBox(height: 10),
            const Text(
              "For the SVM + HOG model to recognize your handwriting accurately, please follow these visual guidelines:",
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 15),

            // How-to-write reference image. Replace the asset path
            // below with your actual image, and make sure it's listed
            // under `flutter: assets:` in pubspec.yaml or it won't
            // render.
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Image.asset(
                'assets/images/how_to_write_baybayin.png',
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            ),

            const SizedBox(height: 20),

            // Supported Characters - now shown as a reference image
            // instead of individual character chips. Replace the
            // asset path below with your actual image.
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.brown[50],
                borderRadius: BorderRadius.circular(15),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    "Supported Characters",
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.brown),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/images/supported_characters.png',
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
            const Text(
              "Best Practices:",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const BulletPoint(text: "Use black ink on plain white paper."),
            const BulletPoint(text: "Keep characters separated (no touching or overlapping strokes)."),
            const BulletPoint(text: "Ensure dots/kudlits are clear, precise, and not touching the main character."),
            const BulletPoint(text: "Draw bars as short, straight strokes above or below the character."),
            const BulletPoint(text: "Avoid shadows or glare in your photos."),

            const SizedBox(height: 30),

            // Final Action Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.brown,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  "Ipagpatuloy",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),

            const SizedBox(height: 20),
            Center(
              child: Text(
                "DAYAW - Capstone Project © 2026",
                style: TextStyle(fontSize: 11, color: Colors.grey[400], letterSpacing: 1.2),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

class BulletPoint extends StatelessWidget {
  final String text;
  const BulletPoint({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("• ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.brown, fontSize: 18)),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4))),
        ],
      ),
    );
  }
}