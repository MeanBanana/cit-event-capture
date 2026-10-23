// Temporary passwords for new investigators (lib/temp_password.dart).

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/temp_password.dart';

void main() {
  test('generated passwords are valid, 12 characters and differ', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final password = generateTempPassword(random: Random(i));
      expect(password.length, 12);
      expect(validateTempPassword(password), isNull);
      // no look-alike characters
      expect(password, isNot(matches(RegExp(r'[0O1lI]'))));
      seen.add(password);
    }
    expect(seen.length, 200);
  });

  test('the same rules as the Edge Functions', () {
    expect(validateTempPassword(''), isNotNull);
    expect(validateTempPassword('abc12'), isNotNull); // too short
    expect(validateTempPassword('abcdefgh'), isNotNull); // no digits
    expect(validateTempPassword('12345678'), isNotNull); // no letters
    expect(validateTempPassword('a1' * 37), isNotNull); // 74: too long
    expect(validateTempPassword('abcd1234'), isNull);
  });
}
