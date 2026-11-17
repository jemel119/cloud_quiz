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

class AttemptRepository {
  AttemptRepository(this._firestore);

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> reference(QuizAttempt attempt) {
    return _firestore
        .collection('users')
        .doc(attempt.uid)
        .collection('attempts')
        .doc(attempt.roundId);
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
    final snapshot = await reference(attempt)
        .get(const GetOptions(source: Source.server));

    if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
      throw const VerificationUnavailable();
    }

    if (!snapshot.exists) return null;

    final data = snapshot.data();
    if (data == null) throw const VerificationUnavailable();

    if (!attempt.matchesFixedFields(data)) {
      throw const AttemptCollision();
    }

    final timestamp = data['submittedAt'];
    if (data.length != 6 || timestamp is! Timestamp) {
      throw const VerificationUnavailable();
    }

    return timestamp;
  }
}
