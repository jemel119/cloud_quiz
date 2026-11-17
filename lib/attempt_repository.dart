import 'package:cloud_firestore/cloud_firestore.dart';

class AttemptCollision implements Exception {
  const AttemptCollision();
}

class VerificationUnavailable implements Exception {
  const VerificationUnavailable();
}

class QuizAttempt {
  QuizAttempt({
    required this.uid,
    required this.roundId,
    required int correctCount,
  }) : fixedFields = Map.unmodifiable({
         'schemaVersion': 1,
         'variant': 'A',
         'categoryId': 9,
         'questionCount': 10,
         'correctCount': correctCount,
       });

  final String uid;
  final String roundId;
  final Map<String, Object> fixedFields;

  late final Map<String, Object> payload = Map.unmodifiable({
    ...fixedFields,
    'submittedAt': FieldValue.serverTimestamp(),
  });

  bool matchesFixedFields(Map<String, dynamic> data) {
    return fixedFields.entries.every((field) {
      final actual = data[field.key];
      return actual == field.value && (field.value is! int || actual is int);
    });
  }
}

class SavedAttempt {
  const SavedAttempt({
    required this.path,
    required this.correctCount,
    required this.submittedAt,
  });

  final String path;
  final int correctCount;
  final Timestamp submittedAt;
}

class AttemptRepository {
  AttemptRepository(this._firestore);

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> reference(QuizAttempt attempt) =>
      _referenceFor(attempt.uid, attempt.roundId);

  DocumentReference<Map<String, dynamic>> _referenceFor(
    String uid,
    String roundId,
  ) {
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('attempts')
        .doc(roundId);
  }

  Future<void> createOnce(QuizAttempt attempt) async {
    final ref = reference(attempt);
    final payload = attempt.payload;

    await _firestore.runTransaction<void>((transaction) async {
      final existing = await transaction.get(ref);

      if (!existing.exists) {
        transaction.set(ref, payload);
        return;
      }

      final data = existing.data();
      if (data == null || !attempt.matchesFixedFields(data)) {
        throw const AttemptCollision();
      }
    });
  }

  /// Returns null only when the server confirms the document is absent.
  Future<Timestamp?> verify(QuizAttempt attempt) async {
    final saved = await readSavedAttempt(attempt.uid, attempt.roundId);
    if (saved == null) return null;

    if (saved.correctCount != attempt.fixedFields['correctCount']) {
      throw const AttemptCollision();
    }

    return saved.submittedAt;
  }

  /// Returns null only when the server confirms the document is absent.
  Future<SavedAttempt?> readSavedAttempt(String uid, String roundId) async {
    final ref = _referenceFor(uid, roundId);
    final snapshot = await ref.get(const GetOptions(source: Source.server));

    if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
      throw const VerificationUnavailable();
    }

    if (!snapshot.exists) return null;

    final data = snapshot.data();
    if (data == null || data.length != 6) {
      throw const VerificationUnavailable();
    }

    final score = data['correctCount'];
    final timestamp = data['submittedAt'];
    if (score is! int || score < 0 || score > 10 || timestamp is! Timestamp) {
      throw const VerificationUnavailable();
    }

    final expected = QuizAttempt(
      uid: uid,
      roundId: roundId,
      correctCount: score,
    );
    if (!expected.matchesFixedFields(data)) {
      throw const AttemptCollision();
    }

    return SavedAttempt(
      path: ref.path,
      correctCount: score,
      submittedAt: timestamp,
    );
  }
}
