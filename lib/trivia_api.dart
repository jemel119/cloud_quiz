import 'dart:async';
import 'dart:convert';

import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;

class TriviaQuestion {
  TriviaQuestion({
    required this.text,
    required this.correctAnswer,
    required List<String> choices,
  }) : choices = List.unmodifiable(choices);

  final String text;
  final String correctAnswer;
  final List<String> choices;
}

class TriviaException implements Exception {
  const TriviaException(this.message);

  final String message;
}

enum TriviaFault { none, badJson, nonzeroApiCode, nineResults }

class TriviaApi {
  static final _url = Uri.parse(
    'https://opentdb.com/api.php?amount=10&category=9'
    '&difficulty=easy&type=multiple',
  );

  static const _requestInterval = Duration(seconds: 5);
  static final _requestClock = Stopwatch()..start();
  static final _decoder = HtmlUnescape();

  static Duration? _lastRequestStart;
  static bool _requestInProgress = false;

  Future<List<TriviaQuestion>> loadRound({
    TriviaFault fault = TriviaFault.none,
  }) async {
    if (_requestInProgress) {
      throw const TriviaException('A question request is already in progress.');
    }

    final lastStart = _lastRequestStart;
    if (lastStart != null &&
        _requestClock.elapsed - lastStart < _requestInterval) {
      throw const TriviaException(
        'Wait at least five seconds between question requests.',
      );
    }

    _requestInProgress = true;
    _lastRequestStart = _requestClock.elapsed;
    http.Client? client;

    try {
      final injectedBody = switch (fault) {
        TriviaFault.none => null,
        TriviaFault.badJson => '{invalid json',
        TriviaFault.nonzeroApiCode => '{"response_code":1,"results":[]}',
        TriviaFault.nineResults => jsonEncode({
          'response_code': 0,
          'results': List.filled(9, <String, Object>{}),
        }),
      };

      if (injectedBody != null) return parseRound(injectedBody);

      client = http.Client();
      final response = await client
          .get(_url)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw TriviaException(
          'OpenTDB returned HTTP ${response.statusCode}. Try again.',
        );
      }

      return parseRound(utf8.decode(response.bodyBytes));
    } on TimeoutException {
      throw const TriviaException('The question request timed out. Try again.');
    } on http.ClientException {
      throw const TriviaException(
        'Could not reach OpenTDB. Check your connection and try again.',
      );
    } on FormatException {
      throw const TriviaException(
        'OpenTDB returned unreadable data. Try again.',
      );
    } finally {
      client?.close();
      _requestInProgress = false;
    }
  }

  List<TriviaQuestion> parseRound(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }

    final code = decoded['response_code'];
    if (code is! int) {
      throw const FormatException('Missing API response code.');
    }
    if (code != 0) {
      throw TriviaException('OpenTDB returned API code $code. Try again.');
    }

    final results = decoded['results'];
    if (results is! List || results.length != 10) {
      throw const TriviaException(
        'OpenTDB did not return exactly 10 questions. Try again.',
      );
    }

    return List<TriviaQuestion>.unmodifiable(results.map(_parseQuestion));
  }

  TriviaQuestion _parseQuestion(Object? entry) {
    if (entry is! Map<String, dynamic> ||
        entry['category'] != 'General Knowledge' ||
        entry['difficulty'] != 'easy' ||
        entry['type'] != 'multiple') {
      throw const TriviaException(
        'A question did not match the Class A requirements. Try again.',
      );
    }

    final wrongAnswers = entry['incorrect_answers'];
    if (wrongAnswers is! List || wrongAnswers.length != 3) {
      throw const TriviaException(
        'A question did not have four answer choices. Try again.',
      );
    }

    final text = _readText(entry['question']);
    final correct = _readText(entry['correct_answer']);
    final choices = <String>[correct, ...wrongAnswers.map(_readText)];

    if (choices.toSet().length != 4) {
      throw const TriviaException(
        'A question contained duplicate answer choices. Try again.',
      );
    }

    choices.shuffle();
    return TriviaQuestion(text: text, correctAnswer: correct, choices: choices);
  }

  String _readText(Object? value) {
    if (value is String) {
      final decoded = _decoder.convert(value).trim();
      if (decoded.isNotEmpty) return decoded;
    }

    throw const TriviaException(
      'A question or answer was missing or empty. Try again.',
    );
  }
}
