import 'dart:convert';

import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  group('AtrustAccount', () {
    test('starts unconfigured', () {
      expect(defaultAtrustAccount.isConfigured, isFalse);
      expect(defaultAtrustAccount.port, 443);
      expect(defaultAtrustAccount.tunnel, 'l3');
    });

    test('round-trips through app settings', () {
      final settings = AppSettingProps.fromJson({
        'atrust': {
          'server': 'rvpn.zju.edu.cn',
          'port': 443,
          'loginDomain': 'Radius',
          'authType': 'auth/psw',
          'username': '3230100888',
          'tunnel': 'l3',
        },
      });

      expect(settings.atrust.server, 'rvpn.zju.edu.cn');
      expect(settings.atrust.username, '3230100888');
      expect(settings.atrust.isConfigured, isTrue);
      final decoded =
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, Object?>;
      expect(AppSettingProps.fromJson(decoded).atrust, settings.atrust);
    });
  });

  group('AtrustProfileSettings', () {
    test('defaults to enabled on every profile', () {
      const overrides = ProfileOverrides();
      expect(overrides.atrust.enabled, isTrue);
      expect(overrides.atrust.managedRules, isTrue);
      expect(overrides.atrust.managedDns, isTrue);
    });

    test('round-trips through profile overrides', () {
      const overrides = ProfileOverrides(
        atrust: AtrustProfileSettings(
          enabled: false,
          managedRules: false,
          managedDns: true,
        ),
      );
      final decoded =
          jsonDecode(jsonEncode(overrides.toJson())) as Map<String, Object?>;
      final parsed = ProfileOverrides.fromJson(decoded);
      expect(parsed.atrust.enabled, isFalse);
      expect(parsed.atrust.managedRules, isFalse);
      expect(parsed.atrust.managedDns, isTrue);
    });
  });
}
