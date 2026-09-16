import 'package:flutter/material.dart';
import 'baybayin_to_tagalog_view.dart';
import 'tagalog_to_baybayin_view.dart';
import '../widgets/info_modal.dart';

/// Top-level shell: header, mode dropdown, and swaps between the two
/// self-contained mode widgets. Each mode now owns its own state — since
/// BaybayinToTagalogView and TagalogToBaybayinView are different widget
/// types, Flutter disposes the old one and creates a fresh instance of
/// the new one whenever the mode changes, so switching modes resets that
/// mode's state automatically (no manual clearing needed here anymore).
class DayawLandingScreen extends StatefulWidget {
  const DayawLandingScreen({super.key});

  @override
  State<DayawLandingScreen> createState() => _DayawLandingScreenState();
}

class _DayawLandingScreenState extends State<DayawLandingScreen> {
  String selectedMode = 'Baybayin to Latin';

  final List<String> translationModes = [
    'Baybayin to Latin',
    'Tagalog to Baybayin',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            _buildHeader(),
            const SizedBox(height: 20),
            Expanded(
              child: selectedMode == 'Tagalog to Baybayin'
                  ? const TagalogToBaybayinView()
                  : const BaybayinToTagalogView(),
            ),
            const SizedBox(height: 30),
            _buildModeSelector(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(width: 40),
          Image.asset('assets/images/dayawlogo.png', height: 50, errorBuilder: (ctx, err, stack) {
            return const Text("DAYAW", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.brown));
          }),
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.brown),
            onPressed: () => showModalBottomSheet(
              context: context,
              builder: (context) => const InfoModal(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20, left: 30, right: 30),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.brown.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(25),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedMode,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, color: Colors.brown),
          items: translationModes.map((String mode) {
            return DropdownMenuItem<String>(
              value: mode,
              child: Text(mode, style: const TextStyle(color: Colors.brown, fontWeight: FontWeight.w600)),
            );
          }).toList(),
          onChanged: (String? newMode) {
            if (newMode != null) {
              setState(() {
                selectedMode = newMode;
              });
            }
          },
        ),
      ),
    );
  }
}