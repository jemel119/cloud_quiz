import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attempt_repository.dart';

class AttemptRulesCheck extends StatefulWidget {
  const AttemptRulesCheck({super.key, required this.uid});

  final String uid;

  @override
  State<AttemptRulesCheck> createState() => _AttemptRulesCheckState();
}

class _AttemptRulesCheckState extends State<AttemptRulesCheck> {
  final _firestore = FirebaseFirestore.instance;
  late final _repository = AttemptRepository(_firestore);
  final _ownerId = TextEditingController();
  final _roundId = TextEditingController();

  bool _busy = false;
  String? _result;

  bool get _isCurrentUser =>
      mounted && FirebaseAuth.instance.currentUser?.uid == widget.uid;

  @override
  void dispose() {
    _ownerId.dispose();
    _roundId.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> _attemptsFor(String uid) =>
      _firestore.collection('users').doc(uid).collection('attempts');

  Future<String> _expectDenied(
    String label,
    Future<void> Function() request,
  ) async {
    if (!_isCurrentUser) return '$label — stopped after account change.';

    try {
      await request();
      return '$label — FAIL: request was accepted.';
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        return '$label — PASS: permission-denied.';
      }
      return '$label — inconclusive: ${error.code}.';
    }
  }

  Future<List<String>> _checkOtherOwner(String ownerUid, String roundId) async {
    final attempts = _attemptsFor(ownerUid);
    final existing = attempts.doc(roundId);
    final fresh = attempts.doc();
    final validAttempt = QuizAttempt(
      uid: ownerUid,
      roundId: fresh.id,
      correctCount: 7,
    );

    return [
      await _expectDenied('T10 read A’s saved attempt', () async {
        await existing.get(const GetOptions(source: Source.server));
      }),
      await _expectDenied('T10 create a fresh attempt under A', () {
        return fresh.set(validAttempt.payload);
      }),
    ];
  }

  Future<List<String>> _checkOwnRules(String roundId) async {
    final uid = widget.uid;
    final before = await _repository.readSavedAttempt(uid, roundId);
    if (!_isCurrentUser) return [];
    if (before == null) {
      return ['Save and verify an attempt under this account first.'];
    }

    final attempts = _attemptsFor(uid);
    final invalidScore = attempts.doc();
    final extraField = attempts.doc();
    final existing = attempts.doc(roundId);

    final validPayload = QuizAttempt(
      uid: uid,
      roundId: extraField.id,
      correctCount: 7,
    ).payload;

    final changedScore = before.correctCount == 10
        ? 9
        : before.correctCount + 1;

    final results = [
      await _expectDenied('T11 create with score 11', () {
        return invalidScore.set({...validPayload, 'correctCount': 11});
      }),
      await _expectDenied('T11 create with an extra field', () {
        return extraField.set({...validPayload, 'extraField': true});
      }),
      await _expectDenied('T11 update the existing score', () {
        return existing.update({'correctCount': changedScore});
      }),
    ];

    if (!_isCurrentUser) return results;

    final after = await _repository.readSavedAttempt(uid, roundId);
    final unchanged =
        after != null &&
        before.correctCount == after.correctCount &&
        before.submittedAt == after.submittedAt;

    return [
      ...results,
      unchanged
          ? 'Original unchanged on server: ${before.correctCount} / 10. '
                'Timestamp preserved.'
          : 'FAIL: the original attempt changed or was missing.',
    ];
  }

  Future<void> _run({required bool crossUser}) async {
    if (!kDebugMode || _busy || !_isCurrentUser) return;

    final roundId = _roundId.text.trim();
    final ownerUid = _ownerId.text.trim();

    if (!RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(roundId)) {
      setState(() => _result = 'Enter the full saved round ID.');
      return;
    }

    if (crossUser &&
        (ownerUid.isEmpty ||
            ownerUid.contains('/') ||
            ownerUid == widget.uid)) {
      setState(() => _result = 'Sign in as B and enter test account A’s UID.');
      return;
    }

    setState(() {
      _busy = true;
      _result = 'Checking deployed Firestore rules…';
    });

    try {
      final results = crossUser
          ? await _checkOtherOwner(ownerUid, roundId)
          : await _checkOwnRules(roundId);

      if (!_isCurrentUser) return;
      final suffix = roundId.substring(roundId.length - 6);
      setState(
        () => _result = ['Round suffix: $suffix', ...results].join('\n'),
      );
    } on FirebaseException catch (error) {
      if (_isCurrentUser) {
        setState(() => _result = 'Check could not finish: ${error.code}.');
      }
    } on AttemptCollision {
      if (_isCurrentUser) {
        setState(() => _result = 'The saved attempt did not match Class A.');
      }
    } on VerificationUnavailable {
      if (_isCurrentUser) {
        setState(() => _result = 'The original could not be verified.');
      }
    } finally {
      if (_isCurrentUser) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Development test: Firestore rules'),
      children: [
        TextField(
          controller: _ownerId,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Account A UID (T10)'),
        ),
        TextField(
          controller: _roundId,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Full saved round ID'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(crossUser: true),
          child: const Text('T10: check cross-user denial'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(crossUser: false),
          child: const Text('T11: check schema and immutability'),
        ),
        if (_result case final result?)
          Semantics(liveRegion: true, child: SelectableText(result)),
      ],
    );
  }
}
