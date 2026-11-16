import 'package:flutter/material.dart';

import 'trivia_api.dart';

class TriviaPreview extends StatefulWidget {
  const TriviaPreview({super.key});

  @override
  State<TriviaPreview> createState() => _TriviaPreviewState();
}

class _TriviaPreviewState extends State<TriviaPreview> {
  final _api = TriviaApi();
  List<TriviaQuestion> _questions = const [];
  bool _loading = false;
  String? _error;

  Future<void> _load() async {
    if (_loading) return;

    setState(() {
      _loading = true;
      _error = null;
      _questions = const [];
    });

    try {
      final questions = await _api.loadRound();
      if (!mounted) return;
      setState(() => _questions = questions);
    } on TriviaException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton(
          onPressed: _loading ? null : _load,
          child: Text(_error == null ? 'Load questions' : 'Retry'),
        ),
        if (_loading) ...[
          const LinearProgressIndicator(),
          const Text('Loading 10 questions…'),
        ],
        if (_error case final message?) Text(message),
        if (_questions.isNotEmpty) ...[
          Text('Loaded ${_questions.length} easy General Knowledge questions.'),
          const SizedBox(height: 8),
          Text(_questions.first.text),
          for (final choice in _questions.first.choices) Text('• $choice'),
        ],
      ],
    );
  }
}
