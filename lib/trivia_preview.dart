import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'attempt_repository.dart';
import 'trivia_api.dart';

import 'package:flutter/foundation.dart';

enum SaveState {
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
  collision,
}

class TriviaPreview extends StatefulWidget {
  const TriviaPreview({super.key, required this.uid});

  final String uid;

  @override
  State<TriviaPreview> createState() => _TriviaPreviewState();
}

class _TriviaPreviewState extends State<TriviaPreview> {
  final _api = TriviaApi();
  final _attempts = AttemptRepository(FirebaseFirestore.instance);
  final _selections = <String>[];

  TriviaFault _triviaFault = TriviaFault.none;

  List<TriviaQuestion> _questions = const [];
  String? _roundId;
  String? _requestError;
  bool _loading = false;
  int _questionIndex = 0;
  int _score = 0;

  SaveState _saveState = SaveState.readyToSubmit;
  QuizAttempt? _attempt;
  Timestamp? _verifiedAt;
  String? _cloudMessage;

  static const _injectLostAcknowledgement =
      kDebugMode && bool.fromEnvironment('INJECT_LOST_ACK');

  bool get _roundComplete => _questionIndex == _questions.length;

  bool get _saveBusy =>
      _saveState == SaveState.submitting || _saveState == SaveState.verifying;

  bool get _saveUnresolved =>
      _saveBusy ||
      _saveState == SaveState.saveUnknown ||
      _saveState == SaveState.verificationUnavailable;

  bool _isCurrentAttempt(QuizAttempt attempt) =>
      mounted &&
      FirebaseAuth.instance.currentUser?.uid == attempt.uid &&
      widget.uid == attempt.uid &&
      _roundId == attempt.roundId;

  Future<void> _loadRound() async {
    if (_loading || _saveUnresolved) return;

    setState(() {
      _loading = true;
      _requestError = null;
    });

    try {
      final fault = kDebugMode ? _triviaFault : TriviaFault.none;
      final questions = await _api.loadRound(fault: fault);
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
        _attempt = null;
        _verifiedAt = null;
        _cloudMessage = null;
        _saveState = SaveState.readyToSubmit;
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

  Future<void> _submit() async {
    if (_saveState != SaveState.readyToSubmit ||
        _roundId == null ||
        !_roundComplete ||
        FirebaseAuth.instance.currentUser?.uid != widget.uid) {
      return;
    }

    final attempt = _attempt ??= QuizAttempt(
      uid: widget.uid,
      roundId: _roundId!,
      correctCount: _score,
    );

    setState(() {
      _saveState = SaveState.submitting;
      _cloudMessage = 'Submitting score…';
    });

    try {
      await _attempts.createOnce(attempt);
    } on AttemptCollision {
      _showCloudResult(
        attempt,
        SaveState.collision,
        'This round ID already has a different score. '
        'The original attempt was preserved.',
      );
      return;
    } on FirebaseException catch (error) {
      final denied =
          error.code == 'permission-denied' || error.code == 'unauthenticated';

      _showCloudResult(
        attempt,
        denied ? SaveState.permissionDenied : SaveState.saveUnknown,
        denied
            ? 'Firestore denied this submission (${error.code}).'
            : 'Save could not be confirmed (${error.code}). '
                  'Check the same attempt on the server.',
      );
      return;
    } catch (_) {
      _showCloudResult(
        attempt,
        SaveState.saveUnknown,
        'Save could not be confirmed. Check the same attempt on the server.',
      );
      return;
    }
    if (_injectLostAcknowledgement) {
      _showCloudResult(
        attempt,
        SaveState.saveUnknown,
        'Development test: save acknowledgement hidden. '
        'Check the same attempt on the server.',
      );
      return;
    }
    await _verify(attempt);
  }

  Future<void> _verify(QuizAttempt attempt) async {
    if (!_isCurrentAttempt(attempt) || _saveState == SaveState.verifying) {
      return;
    }

    final wasUnknown = _saveState == SaveState.saveUnknown;
    setState(() {
      _saveState = SaveState.verifying;
      _cloudMessage = 'Checking the saved attempt on the server…';
    });

    try {
      final timestamp = await _attempts.verify(attempt);
      if (!_isCurrentAttempt(attempt)) return;

      if (timestamp == null) {
        _showCloudResult(
          attempt,
          wasUnknown
              ? SaveState.readyToSubmit
              : SaveState.verificationUnavailable,
          wasUnknown
              ? 'No attempt found on the server. Tap Submit to retry this round.'
              : 'The acknowledged attempt could not be found. Check again.',
        );
        return;
      }

      setState(() {
        _verifiedAt = timestamp;
        _saveState = SaveState.cloudVerified;
        _cloudMessage = 'Cloud verified';
      });
    } on AttemptCollision {
      _showCloudResult(
        attempt,
        SaveState.collision,
        'The server returned different attempt data. '
        'The original attempt was preserved.',
      );
    } on FirebaseException catch (error) {
      final detail = switch (error.code) {
        'permission-denied' => 'Firestore denied the server read.',
        'unauthenticated' =>
          'Firestore could not authenticate the server read.',
        'unavailable' => 'Firestore is unavailable. Check your connection.',
        'resource-exhausted' => 'Firestore reported a usage limit.',
        _ => 'The server read could not be confirmed.',
      };
      _showCloudResult(
        attempt,
        wasUnknown ? SaveState.saveUnknown : SaveState.verificationUnavailable,
        '$detail Try checking the server again.',
      );
    } catch (_) {
      _showCloudResult(
        attempt,
        wasUnknown ? SaveState.saveUnknown : SaveState.verificationUnavailable,
        'Verification unavailable. Check the server again.',
      );
    }
  }

  void _showCloudResult(QuizAttempt attempt, SaveState state, String message) {
    if (!_isCurrentAttempt(attempt)) return;

    setState(() {
      _saveState = state;
      _cloudMessage = message;
    });
  }

  Future<void> _signOut() async {
    if (_saveUnresolved) return;

    try {
      await FirebaseAuth.instance.signOut();
    } on FirebaseAuthException {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not sign out. Try again.')),
      );
    }
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
        if (kDebugMode && _questions.isEmpty)
          DropdownButton<TriviaFault>(
            value: _triviaFault,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: TriviaFault.none,
                child: Text('Live OpenTDB request'),
              ),
              DropdownMenuItem(
                value: TriviaFault.badJson,
                child: Text('Development test: bad JSON'),
              ),
              DropdownMenuItem(
                value: TriviaFault.nonzeroApiCode,
                child: Text('Development test: nonzero API code'),
              ),
              DropdownMenuItem(
                value: TriviaFault.nineResults,
                child: Text('Development test: nine results'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _triviaFault = value);
            },
          ),
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
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _saveUnresolved ? null : _signOut,
          child: const Text('Sign out'),
        ),
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
        FilledButton(
          onPressed: _saveState == SaveState.readyToSubmit ? _submit : null,
          child: const Text('Submit'),
        ),
        if (_cloudMessage case final message?)
          Semantics(liveRegion: true, child: Text(message)),
        if (_saveState == SaveState.saveUnknown ||
            _saveState == SaveState.verificationUnavailable)
          OutlinedButton(
            onPressed: () => _verify(_attempt!),
            child: const Text('Check server again'),
          ),
        if (_verifiedAt case final timestamp?) ...[
          SelectableText('Document: ${_attempts.reference(_attempt!).path}'),
          Text(
            'Server timestamp: ${timestamp.toDate().toUtc().toIso8601String()}',
          ),
        ],
        OutlinedButton(
          onPressed: _requestError == null && !_saveUnresolved
              ? _loadRound
              : null,
          child: const Text('Replay'),
        ),
      ],
    );
  }
}
