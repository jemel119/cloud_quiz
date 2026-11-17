import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'attempt_repository.dart';

class AttemptExperiment extends StatefulWidget {
  const AttemptExperiment({super.key, required this.uid});

  final String uid;

  @override
  State<AttemptExperiment> createState() => _AttemptExperimentState();
}

class _AttemptExperimentState extends State<AttemptExperiment> {
  final _firestore = FirebaseFirestore.instance;
  late final _repository = AttemptRepository(_firestore);
  final _roundId = TextEditingController();

  bool _busy = false;
  String? _result;

  bool get _isCurrentUser =>
      mounted && FirebaseAuth.instance.currentUser?.uid == widget.uid;

  @override
  void dispose() {
    _roundId.dispose();
    super.dispose();
  }

  void _generateId() {
    if (_busy || !_isCurrentUser) return;

    final id = _firestore
        .collection('users')
        .doc(widget.uid)
        .collection('attempts')
        .doc()
        .id;

    setState(() {
      _roundId.text = id;
      _result = 'ID generated. No cloud document was created.';
    });
  }

  Future<void> _run({required bool collision}) async {
    if (_busy || !_isCurrentUser) return;

    final id = _roundId.text.trim();
    if (!RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(id)) {
      setState(() => _result = 'Enter the full 20-character round ID.');
      return;
    }

    final suffix = id.substring(id.length - 6);
    final startedAt = DateTime.now().toUtc().toIso8601String();
    setState(() {
      _busy = true;
      _result = 'Running live Firestore experiment…';
    });

    try {
      final result = collision
          ? await _checkCollision(id)
          : await _submitSamePayload(id);

      if (!_isCurrentUser) return;
      final finishedAt = DateTime.now().toUtc().toIso8601String();
      setState(() {
        _result =
            '$result\nRound suffix: $suffix\n'
            'Started: $startedAt\nFinished: $finishedAt';
      });
    } on AttemptCollision {
      if (_isCurrentUser) {
        setState(() => _result = 'Unexpected collision for round …$suffix.');
      }
    } on FirebaseException catch (error) {
      if (_isCurrentUser) {
        setState(() => _result = 'Firestore error: ${error.code}.');
      }
    } on VerificationUnavailable {
      if (_isCurrentUser) {
        setState(() => _result = 'Server verification unavailable.');
      }
    } finally {
      if (_isCurrentUser) setState(() => _busy = false);
    }
  }

  Future<String> _submitSamePayload(String id) async {
    final attempt = QuizAttempt(uid: widget.uid, roundId: id, correctCount: 7);

    await _repository.createOnce(attempt);
    if (!_isCurrentUser) return '';

    final timestamp = await _repository.verify(attempt);
    if (timestamp == null) {
      return 'Could not verify the attempt. The server returned no document.';
    }

    return 'Cloud verified: 7 / 10\n'
        'Server timestamp: ${timestamp.toDate().toUtc().toIso8601String()}';
  }

  Future<String> _checkCollision(String id) async {
    final before = await _repository.readSavedAttempt(widget.uid, id);
    if (!_isCurrentUser) return '';
    if (before == null || before.correctCount != 7) {
      return 'Run the 7 / 10 experiment successfully for this ID first.';
    }

    final changedAttempt = QuizAttempt(
      uid: widget.uid,
      roundId: id,
      correctCount: 8,
    );

    try {
      await _repository.createOnce(changedAttempt);
      return 'Unexpected result: the repository accepted a different score.';
    } on AttemptCollision {
      if (!_isCurrentUser) return '';
      final after = await _repository.readSavedAttempt(widget.uid, id);
      if (after == null ||
          after.correctCount != before.correctCount ||
          after.submittedAt != before.submittedAt) {
        return 'Collision reported, but the original could not be verified.';
      }

      return 'Collision reported. Original 7 / 10 and timestamp preserved.\n'
          'Server timestamp: '
          '${after.submittedAt.toDate().toUtc().toIso8601String()}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Development test: same-ID submission'),
      children: [
        TextField(
          controller: _roundId,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Shared round ID'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : _generateId,
          child: const Text('Generate experiment ID'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(collision: false),
          child: const Text('Submit matching score (7 / 10)'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(collision: true),
          child: const Text('Test collision (8 / 10)'),
        ),
        if (_result case final result?)
          Semantics(liveRegion: true, child: SelectableText(result)),
      ],
    );
  }
}
