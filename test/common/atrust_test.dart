import 'package:fl_clash/common/atrust.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

const _account = AtrustAccount(
  server: 'rvpn.zju.edu.cn',
  username: '3230100888',
);

Map<String, dynamic> _config() => {
  'proxies': [
    {'name': 'airport', 'type': 'ss'},
  ],
  'rules': ['MATCH,DIRECT'],
};

void main() {
  test('does nothing without a configured account', () {
    final config = _config();
    injectAtrustConfig(
      rawConfig: config,
      account: defaultAtrustAccount,
      settings: defaultAtrustProfileSettings,
    );
    expect(config['proxies'], hasLength(1));
    expect(config['rules'], ['MATCH,DIRECT']);
  });

  test('does nothing when the profile disables aTrust', () {
    final config = _config();
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: const AtrustProfileSettings(enabled: false),
    );
    expect(config['proxies'], hasLength(1));
    expect(config['rules'], ['MATCH,DIRECT']);
    expect(config['proxy-groups'], isNull);
  });

  test('does nothing for a profile-owned aTrust node', () {
    final config = _config();
    (config['proxies'] as List).add({
      'name': 'own',
      'type': 'atrust',
      'server': 'vpn.example.edu',
    });
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    expect(config['proxies'], hasLength(2));
    expect(config['rules'], ['MATCH,DIRECT']);
  });

  test('adds the node, group, rules and DNS policy', () {
    final config = _config();
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );

    expect(config['proxies'], hasLength(2));
    expect((config['proxies'] as List).last, {
      'name': 'atrust',
      'type': 'atrust',
      'server': 'rvpn.zju.edu.cn',
      'port': 443,
      'login-domain': 'Radius',
      'auth-type': 'auth/psw',
      'username': '3230100888',
      'tunnel': 'l3',
      'udp': true,
    });
    expect(config['proxy-groups'], [
      {
        'name': 'aTrust',
        'type': 'select',
        'proxies': ['atrust', 'DIRECT'],
      },
    ]);
    expect(config['rules'], [
      'RULE-SET,atrust-domain-atrust,aTrust',
      'RULE-SET,atrust-ip-atrust,aTrust',
      'MATCH,DIRECT',
    ]);
    expect(config['dns'], {
      'nameserver-policy': {'rule-set:atrust-domain-atrust': 'atrust://atrust'},
      'proxy-server-nameserver': [atrustFallbackProxyServerNameserver],
    });
  });

  test('keeps a user proxy-server-nameserver', () {
    final config = _config()
      ..['dns'] = {
        'proxy-server-nameserver': ['https://dns.example/dns-query'],
      };
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    expect((config['dns'] as Map)['proxy-server-nameserver'], [
      'https://dns.example/dns-query',
    ]);
  });

  test('honours the managed rules and DNS switches', () {
    final config = _config();
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: const AtrustProfileSettings(
        managedRules: false,
        managedDns: false,
      ),
    );
    expect(config['proxies'], hasLength(2));
    expect(config['proxy-groups'], isNull);
    expect(config['rules'], ['MATCH,DIRECT']);
    expect(config['dns'], isNull);
  });

  test('does not duplicate its own rows', () {
    final config = _config();
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    expect(config['proxies'], hasLength(2));
    expect(config['proxy-groups'], hasLength(1));
    expect(config['rules'], [
      'RULE-SET,atrust-domain-atrust,aTrust',
      'RULE-SET,atrust-ip-atrust,aTrust',
      'MATCH,DIRECT',
    ]);
  });

  test('picks a free proxy name when atrust is taken', () {
    final config = _config();
    (config['proxies'] as List).add({'name': 'atrust', 'type': 'ss'});
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    expect((config['proxies'] as List).last['name'], 'atrust-2');
    expect((config['proxy-groups'] as List).last['proxies'], [
      'atrust-2',
      'DIRECT',
    ]);
    expect(config['rules'], [
      'RULE-SET,atrust-domain-atrust-2,aTrust',
      'RULE-SET,atrust-ip-atrust-2,aTrust',
      'MATCH,DIRECT',
    ]);
    expect((config['dns'] as Map)['nameserver-policy'], {
      'rule-set:atrust-domain-atrust-2': 'atrust://atrust-2',
    });
  });

  test('picks a free group name when aTrust is taken', () {
    final config = _config()
      ..['proxy-groups'] = [
        {
          'name': 'aTrust',
          'type': 'select',
          'proxies': ['airport'],
        },
      ];
    injectAtrustConfig(
      rawConfig: config,
      account: _account,
      settings: defaultAtrustProfileSettings,
    );
    expect((config['proxy-groups'] as List).last['name'], 'aTrust-2');
    expect(config['rules'], [
      'RULE-SET,atrust-domain-atrust,aTrust-2',
      'RULE-SET,atrust-ip-atrust,aTrust-2',
      'MATCH,DIRECT',
    ]);
  });
}
