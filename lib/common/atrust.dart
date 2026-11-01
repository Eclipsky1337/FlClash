import 'package:fl_clash/models/models.dart';

const atrustProxyName = 'atrust';
const atrustGroupName = 'aTrust';
const atrustFallbackProxyServerNameserver = 'https://doh.pub/dns-query';

String atrustProviderSuffix(String name) {
  final buffer = StringBuffer();
  for (final rune in name.runes) {
    final valid =
        (rune >= 0x61 && rune <= 0x7a) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x30 && rune <= 0x39) ||
        rune == 0x5f ||
        rune == 0x2d ||
        rune == 0x2e;
    buffer.writeCharCode(valid ? rune : 0x5f);
  }
  return buffer.isEmpty ? 'node' : buffer.toString();
}

String atrustDomainProviderFor(String name) =>
    'atrust-domain-${atrustProviderSuffix(name)}';

String atrustIpProviderFor(String name) =>
    'atrust-ip-${atrustProviderSuffix(name)}';

/// Whether the profile already declares its own aTrust outbound. A profile-owned
/// node wins over the global account, so the overlay must not add a second one.
bool hasAtrustProxy(Map<String, dynamic> rawConfig) {
  final proxies = rawConfig['proxies'];
  return proxies is List &&
      proxies.any(
        (proxy) =>
            proxy is Map &&
            proxy['type']?.toString().toLowerCase() == atrustProxyName,
      );
}

/// Injects the global aTrust account into one generated profile.
///
/// The function is deliberately pure and idempotent: it edits only the config
/// map it is given and leaves a profile-owned aTrust node untouched.
Map<String, dynamic> injectAtrustConfig({
  required Map<String, dynamic> rawConfig,
  required AtrustAccount account,
  required AtrustProfileSettings settings,
  bool profileHasAtrust = false,
}) {
  if (!settings.enabled || !account.isConfigured) {
    return rawConfig;
  }
  if (profileHasAtrust || hasAtrustProxy(rawConfig)) {
    return rawConfig;
  }

  final proxies = rawConfig['proxies'] is List
      ? List<Object?>.from(rawConfig['proxies'] as List)
      : <Object?>[];
  final name = _uniqueProxyName(proxies);
  proxies.add({
    'name': name,
    'type': atrustProxyName,
    'server': account.server,
    'port': account.port,
    'login-domain': account.loginDomain,
    'auth-type': account.authType,
    'username': account.username,
    'tunnel': account.tunnel,
    'udp': account.tunnel == 'l3',
  });
  rawConfig['proxies'] = proxies;

  if (settings.managedRules) {
    final groups = rawConfig['proxy-groups'] is List
        ? List<Object?>.from(rawConfig['proxy-groups'] as List)
        : <Object?>[];
    final groupName = _uniqueGroupName(groups);
    groups.add({
      'name': groupName,
      'type': 'select',
      'proxies': [name, 'DIRECT'],
    });
    rawConfig['proxy-groups'] = groups;

    final rules = rawConfig['rules'] is List
        ? List<String>.from(rawConfig['rules'] as List)
        : <String>[];
    for (final rule in [
      'RULE-SET,${atrustIpProviderFor(name)},$groupName',
      'RULE-SET,${atrustDomainProviderFor(name)},$groupName',
    ]) {
      if (!rules.contains(rule)) {
        rules.insert(0, rule);
      }
    }
    rawConfig['rules'] = rules;
  }

  if (settings.managedDns) {
    final dns = rawConfig['dns'] is Map
        ? Map<String, dynamic>.from(rawConfig['dns'] as Map)
        : <String, dynamic>{};
    final policy = dns['nameserver-policy'] is Map
        ? Map<String, dynamic>.from(dns['nameserver-policy'] as Map)
        : <String, dynamic>{};
    policy.putIfAbsent(
      'rule-set:${atrustDomainProviderFor(name)}',
      () => 'atrust://$name',
    );
    dns['nameserver-policy'] = policy;
    final proxyServerNameserver = dns['proxy-server-nameserver'];
    if (proxyServerNameserver == null ||
        (proxyServerNameserver is List && proxyServerNameserver.isEmpty)) {
      dns['proxy-server-nameserver'] = [atrustFallbackProxyServerNameserver];
    }
    rawConfig['dns'] = dns;
  }

  return rawConfig;
}

String _uniqueProxyName(List<Object?> proxies) {
  final names = {
    for (final proxy in proxies)
      if (proxy is Map && proxy['name'] != null) proxy['name'].toString(),
  };
  if (!names.contains(atrustProxyName)) {
    return atrustProxyName;
  }
  var index = 2;
  while (names.contains('$atrustProxyName-$index')) {
    index++;
  }
  return '$atrustProxyName-$index';
}

String _uniqueGroupName(List<Object?> groups) {
  final names = {
    for (final group in groups)
      if (group is Map && group['name'] != null) group['name'].toString(),
  };
  if (!names.contains(atrustGroupName)) {
    return atrustGroupName;
  }
  var index = 2;
  while (names.contains('$atrustGroupName-$index')) {
    index++;
  }
  return '$atrustGroupName-$index';
}
