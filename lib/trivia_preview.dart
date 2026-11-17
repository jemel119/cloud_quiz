import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'trivia_api.dart';

class TriviaPreview extends StatefulWidget {
  const TriviaPreview({super.key, required this.uid});

  final String uid;

  @override
  State<TriviaPreview> createState() => _TriviaPreviewState();
}

class _TriviaPreviewState extends State<TriviaPreview> {
  final _api = TriviaApi();
  final _selections = <String>[];

  List<TriviaQuestion> _questions = const [];
  String? _roundId;
  String? _requestError;
  bool _loading = false;
  int _questionIndex = 0;
  int _score = 0;

  bool get _roundComplete => _questionIndex == _questions.length;

  Future<void> _loadRound() async {
    if (_loading) return;

    setState(() {
      _loading = true;
      _requestError = null;
    });

    try {
      final questions = await _api.loadRound();
      if (!mounted) return;

      final roundId = FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .collection('attempts')
          .doc()
          .id;

      setState(() {
        _questions = questions;
        _roundId = roundId;
        _selections.clear();
        _questionIndex = 0;
        _score = 0;
      });
    } on TriviaException catch (error) {
      if (!mounted) return;
      setState(() => _requestError = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectAnswer(int questionIndex, String choice) {
    if (_loading ||
        questionIndex != _questionIndex ||
        _selections.length != questionIndex) {
      return;
    }

    setState(() {
      _selections.add(choice);
      if (choice == _questions[questionIndex].correctAnswer) {
        _score++;
      }
    });
  }

  void _continue(int questionIndex) {
    if (questionIndex != _questionIndex ||
        _selections.length <= questionIndex) {
      return;
    }

    setState(() => _questionIndex++);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(),
          SizedBox(height: 8),
          Text('Loading 10 questions…'),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_requestError case final message?) ...[
          Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _loadRound,
            child: const Text('Retry question request'),
          ),
        ],
        if (_questions.isEmpty && _requestError == null)
          FilledButton(onPressed: _loadRound, child: const Text('Start quiz')),
        if (_questions.isNotEmpty)
          if (_roundComplete)
            _buildReview(context)
          else
            _buildQuestion(context),
      ],
    );
  }

  Widget _buildQuestion(BuildContext context) {
    final index = _questionIndex;
    final question = _questions[index];
    final selected = _selections.length > index ? _selections[index] : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Question ${index + 1} of ${_questions.length}'),
        LinearProgressIndicator(value: _selections.length / _questions.length),
        const SizedBox(height: 12),
        Text(question.text, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final choice in question.choices)
          OutlinedButton(
            onPressed: selected == null
                ? () => _selectAnswer(index, choice)
                : null,
            child: Text(choice == selected ? '$choice (your answer)' : choice),
          ),
        if (selected != null)
          Text(
            selected == question.correctAnswer
                ? 'Correct!'
                : 'Incorrect. Correct answer: ${question.correctAnswer}',
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: selected == null ? null : () => _continue(index),
          child: Text(
            index == _questions.length - 1 ? 'Review answers' : 'Next',
          ),
        ),
      ],
    );
  }

  Widget _buildReview(BuildContext context) {
    final roundId = _roundId!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Final score: $_score / ${_questions.length}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        SelectableText(
          'Round ID suffix: ${roundId.substring(roundId.length - 6)}',
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _questions.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${i + 1}. ${_questions[i].text}'),
            subtitle: Text(
              '${_selections[i] == _questions[i].correctAnswer ? 'Correct' : 'Incorrect'}\n'
              'Your answer: ${_selections[i]}\n'
              'Correct answer: ${_questions[i].correctAnswer}',
            ),
          ),
        const FilledButton(onPressed: null, child: Text('Submit')),
        OutlinedButton(
          onPressed: _requestError == null ? _loadRound : null,
          child: const Text('Replay'),
        ),
      ],
    );
  }
}
