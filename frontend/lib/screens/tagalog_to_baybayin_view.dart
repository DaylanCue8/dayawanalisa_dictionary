import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/tagalog_to_baybayin_local_translator.dart';
import '../widgets/glass.dart';

/// Handles the "Filipino to Baybayin" mode (internally still keyed as
/// 'Tagalog to Baybayin' for the translator): debounced auto-translate as the
/// user types, with confidence display. Fully self-contained — owns its
/// own state, independent of the image-translation mode.
///
/// Laid out like the Baybayin to Tagalog results page: an input card on
/// top, then "Results" (the translation, with copy) and a "Character
/// Breakdown" with one glass card per line of text.
class TagalogToBaybayinView extends StatefulWidget {
  const TagalogToBaybayinView({super.key});

  @override
  State<TagalogToBaybayinView> createState() => _TagalogToBaybayinViewState();
}

class _TagalogToBaybayinViewState extends State<TagalogToBaybayinView> {
  final ApiService _apiService = ApiService();
  final TagalogToBaybayinLocalTranslator _translator =
      TagalogToBaybayinLocalTranslator();
  final TextEditingController _textController = TextEditingController();

  // Debounce timer so we don't fire a request on every keystroke — waits
  // for a short pause in typing before translating automatically.
  Timer? _debounce;

  String _translatedResult = "";
  double _confidenceScore = 0.0;
  bool _isLoading = false;
  bool _hasError = false;

  /// One entry per non-empty line of input: its syllable pieces.
  List<List<({String latin, String baybayin})>> _lineBreakdown = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    super.dispose();
  }

  /// Called on every keystroke. Restarts a 350ms timer each time so the
  /// actual translation only fires once typing pauses.
  void _onTextChanged(String text) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _handleTextTranslation(text);
    });
  }

  Future<void> _handleTextTranslation(String text) async {
    if (text.trim().isEmpty) {
      setState(() {
        _translatedResult = "";
        _confidenceScore = 0.0;
        _isLoading = false;
        _hasError = false;
        _lineBreakdown = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final response = await _apiService.uploadAndTranslateDetailed(
      null,
      'Tagalog to Baybayin',
      text: text,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (response != null) {
        _translatedResult = response['translated_text'] ?? "";
        _confidenceScore = (response['confidence'] as num).toDouble();
        _hasError = false;
      } else {
        _translatedResult = "Error: Connection Failed";
        _confidenceScore = 0.0;
        _hasError = true;
      }
      _lineBreakdown = [
        for (final line in text.split('\n'))
          if (line.trim().isNotEmpty)
            _translator
                .breakdown(line)
                .where((piece) => piece.latin.trim().isNotEmpty)
                .toList(),
      ].where((pieces) => pieces.isNotEmpty).toList();
    });
  }

  Color _getConfidenceColor() {
    if (_confidenceScore >= 95) return Colors.green;
    if (_confidenceScore >= 75) return Colors.orange;
    return Colors.red;
  }

  void _clear() {
    _debounce?.cancel();
    _textController.clear();
    _handleTextTranslation("");
  }

  void _copyResult() {
    Clipboard.setData(ClipboardData(text: _translatedResult));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      children: [
        _buildInputCard(),
        const SizedBox(height: 24),
        Row(
          children: [
            const Text(
              'Results',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            if (_isLoading) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.brown,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        _buildResultCard(),
        const SizedBox(height: 24),
        const Text(
          'Character Breakdown',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 12),
        _buildBreakdown(),
        const SizedBox(height: 20),
        const Text(
          '© 2026 DAYAW. All rights reserved.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  /// Top card - the counterpart of the results page's image card.
  Widget _buildInputCard() {
    return GlassContainer(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _textController,
            onChanged: _onTextChanged,
            minLines: 4,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: "Enter Filipino text here...",
              border: InputBorder.none,
            ),
            style: const TextStyle(fontSize: 16),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.clear, color: Colors.grey),
              onPressed: _clear,
              tooltip: "Clear",
            ),
          ),
        ],
      ),
    );
  }

  /// Same card as the results page's predicted-output card: the
  /// translation with a copy button, plus the confidence badge.
  Widget _buildResultCard() {
    final hasResult = _translatedResult.isNotEmpty && !_hasError;
    return GlassContainer(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: hasResult
                    ? Text(
                        _translatedResult,
                        style: const TextStyle(
                          fontFamily: 'BaybayinCustom',
                          fontSize: 28,
                          color: Colors.brown,
                          height: 1.6,
                          letterSpacing: 3.0,
                        ),
                      )
                    : Text(
                        _hasError
                            ? _translatedResult
                            : 'Result will appear here',
                        style: TextStyle(
                          fontSize: 16,
                          color: _hasError ? Colors.red : Colors.grey,
                        ),
                      ),
              ),
              if (hasResult)
                IconButton(
                  onPressed: _copyResult,
                  icon: const Icon(Icons.copy, color: Colors.brown),
                  tooltip: 'Copy result',
                ),
            ],
          ),
          if (hasResult && _confidenceScore > 0.0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _getConfidenceColor().withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Confidence: ${_confidenceScore.toStringAsFixed(1)}%",
                style: TextStyle(
                  color: _getConfidenceColor(),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBreakdown() {
    if (_lineBreakdown.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            'Type Filipino text above to see each syllable.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _lineBreakdown.length; i++)
          _buildLineSection(i + 1, _lineBreakdown[i]),
      ],
    );
  }

  /// One glass card per line of input, like the results page: a big line
  /// number, then a sideways-scrolling row of syllable cards.
  Widget _buildLineSection(
    int lineNumber,
    List<({String latin, String baybayin})> pieces,
  ) {
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$lineNumber',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
              const Text(
                'Line',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [for (final piece in pieces) _buildPiece(piece)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// [Baybayin glyph | Latin syllable], mirroring the results page's
  /// [cropped character | predicted letter] cards.
  Widget _buildPiece(({String latin, String baybayin}) piece) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: Center(
                child: Text(
                  // Letters Baybayin has no glyph for (c, f, j, ...) come
                  // back empty; show "?" so the card isn't blank.
                  piece.baybayin.isEmpty ? '?' : piece.baybayin,
                  style: TextStyle(
                    fontFamily: piece.baybayin.isEmpty
                        ? null
                        : 'BaybayinCustom',
                    fontSize: 28,
                    color: piece.baybayin.isEmpty ? Colors.red : Colors.black87,
                  ),
                ),
              ),
            ),
            VerticalDivider(
              width: 16,
              thickness: 1,
              color: Colors.brown.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: Text(
                  piece.latin,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.brown,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
