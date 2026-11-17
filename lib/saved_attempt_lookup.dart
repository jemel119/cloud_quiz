import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attempt_repository.dart';

class SavedAttemptLookup extends StatefulWidget {
  const SavedAttemptLookup({super.key, required this.uid});

  final String uid;

  @override
  State<SavedAttemptLookup> createState() => _SavedAttemptLookupState();
}

class _SavedAttemptLookupState extends State<SavedAttemptLookup> {
  final _roundId = TextEditingController();
  final _repository = AttemptRepository(FirebaseFirestore.instance);

  bool _reading = false;
  bool _holdNextResponse = false;
  String? _message;
  SavedAttempt? _saved;

  @override
  void dispose() {
    _roundId.dispose();
    super.dispose();
  }

  Future<void> _lookUp() async {
    final uid = widget.uid;
    if (_reading || !_isCurrentUser(uid)) return;

    final roundId = _roundId.text.trim();
    if (!RegExp(r'^[A-Za-z0-9]{20}$').hasMatch(roundId)) {
      setState(() {
        _saved = null;
        _message = 'Enter the full 20-character round ID.';
      });
      return;
    }

    final holdResponse = kDebugMode && _holdNextResponse;
    final suffix = roundId.substring(roundId.length - 6);

    setState(() {
      _reading = true;
      _holdNextResponse = false;
      _saved = null;
      _message = 'Reading the attempt from Firestore…';
    });

    try {
      final saved = await _repository.readSavedAttempt(uid, roundId);
      if (!_isCurrentUser(uid)) return;

      if (holdResponse && saved != null) {
        setState(() {
          _message = 'Development test: holding server response for '
              '…$suffix for 20 seconds. Switch accounts now.';
        });
        debugPrint('G03: holding verified response for round …$suffix.');

        await Future<void>.delayed(const Duration(seconds: 20));

        if (!_isCurrentUser(uid)) {
          final currentUid = FirebaseAuth.instance.currentUser?.uid;
          final authState = switch (currentUid) {
            null => 'signed out',
            final activeUid when activeUid == uid => 'original account',
            _ => 'different account',
          };
          debugPrint(
            'G03: discarded stale response for round …$suffix '
            '(auth state: $authState).',
          );
          return;
        }

        debugPrint(
          'G03: original session still active for round …$suffix. '
          'Repeat the test and switch accounts during the hold.',
        );
      }

      setState(() {
        _saved = saved;
        _message = saved == null
            ? 'No saved attempt was found for this round ID.'
            : 'Cloud verified';
      });
    } on FirebaseException catch (error) {
      _showError(uid, switch (error.code) {
        'permission-denied' => 'Firestore denied this lookup.',
        'unauthenticated' => 'Sign in again to look up this attempt.',
        'resource-exhausted' => 'Firestore reported a usage limit.',
        _ => 'Server lookup unavailable. Check your connection and try again.',
      });
    } on AttemptCollision {
      _showError(uid, 'The saved document does not match the Class A schema.');
    } on VerificationUnavailable {
      _showError(uid, 'The server result could not be verified. Try again.');
    } finally {
      if (_isCurrentUser(uid)) setState(() => _reading = false);
    }
  }

  bool _isCurrentUser(String uid) =>
      mounted &&
      widget.uid == uid &&
      FirebaseAuth.instance.currentUser?.uid == uid;

  void _showError(String uid, String message) {
    if (!_isCurrentUser(uid)) return;
    setState(() => _message = message);
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Find a saved attempt'),
      children: [
        TextField(
          controller: _roundId,
          enabled: !_reading,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Full round ID'),
          onSubmitted: (_) => _lookUp(),
        ),
        const SizedBox(height: 8),
        if (kDebugMode)
          SwitchListTile(
            title: const Text('Development test: hold next server response'),
            value: _holdNextResponse,
            onChanged: _reading
                ? null
                : (value) => setState(() => _holdNextResponse = value),
          ),
        OutlinedButton(
          onPressed: _reading ? null : _lookUp,
          child: const Text('Read from server'),
        ),
        if (_message case final message?)
          Semantics(liveRegion: true, child: Text(message)),
        if (_saved case final saved?) ...[
          SelectableText('Document: ${saved.path}'),
          Text('Saved score: ${saved.correctCount} / 10'),
          Text(
            'Server timestamp: '
            '${saved.submittedAt.toDate().toUtc().toIso8601String()}',
          ),
        ],
      ],
    );
  }
}