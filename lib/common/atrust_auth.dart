import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AtrustAuthException implements Exception {
  const AtrustAuthException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class AtrustStatus {
  const AtrustStatus({
    required this.name,
    required this.state,
    this.server = '',
    this.port = 0,
    this.account = '',
    this.error = '',
    this.resources = 0,
    this.domains = 0,
    this.cidrs = 0,
    this.hasSession = false,
    this.updatedAt,
  });

  final String name;
  final String state;
  final String server;
  final int port;
  final String account;
  final String error;
  final int resources;
  final int domains;
  final int cidrs;
  final bool hasSession;
  final DateTime? updatedAt;

  bool get isReady => state == 'ready';
  bool get isPending => state == 'pending' || state == 'awaiting_input';

  factory AtrustStatus.fromJson(Map<String, Object?> json) {
    int count(String key) => (json[key] as num?)?.toInt() ?? 0;
    return AtrustStatus(
      name: json['name']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      server: json['server']?.toString() ?? '',
      port: count('port'),
      account: json['account']?.toString() ?? '',
      error: json['error']?.toString() ?? '',
      resources: count('resources'),
      domains: count('domains'),
      cidrs: count('cidrs'),
      hasSession: json['has_session'] == true,
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

/// Picks the provider a page should show first: keep the current one, then the
/// injected `atrust` node, then the first provider in core order.
String? selectAtrustProviderName(
  List<AtrustStatus> providers,
  String? current,
) {
  if (providers.isEmpty) {
    return null;
  }
  if (current != null &&
      providers.any((provider) => provider.name == current)) {
    return current;
  }
  if (providers.any((provider) => provider.name == 'atrust')) {
    return 'atrust';
  }
  return providers.first.name;
}

class AtrustSession {
  const AtrustSession({
    required this.id,
    required this.url,
    required this.state,
    this.error = '',
    this.expiresAt,
    this.attemptsLeft = 0,
  });

  final String id;
  final String url;
  final String state;
  final String error;
  final DateTime? expiresAt;
  final int attemptsLeft;

  factory AtrustSession.fromJson(Map<String, Object?> json) {
    return AtrustSession(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      error: json['error']?.toString() ?? '',
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      attemptsLeft: (json['attempts_left'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The loopback auth API the core starts for aTrust. Every call is direct:
/// the login listener is never reached through the proxy.
class AtrustAuthApi {
  const AtrustAuthApi(this.listen);

  final String listen;

  Future<List<AtrustStatus>> providers() async {
    final data = await _request('GET', '/auth/v1/providers');
    final providers = data['providers'];
    if (providers is! List) {
      return const [];
    }
    return [
      for (final provider in providers)
        if (provider is Map)
          AtrustStatus.fromJson(Map<String, Object?>.from(provider)),
    ];
  }

  Future<AtrustSession> createSession(String name) async {
    final data = await _request(
      'POST',
      '/auth/v1/providers/${Uri.encodeComponent(name)}/sessions',
    );
    return AtrustSession.fromJson(data);
  }

  Future<void> cancelSession(String id) async {
    await _request('DELETE', '/auth/v1/sessions/${Uri.encodeComponent(id)}');
  }

  Future<void> logout(String name) async {
    await _request(
      'POST',
      '/auth/v1/providers/${Uri.encodeComponent(name)}/logout',
    );
  }

  Future<Map<String, Object?>> _request(String method, String path) async {
    if (listen.isEmpty) {
      throw const AtrustAuthException('auth listener is not running');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://$listen$path'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.contentLength = 0;
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 10));
      final data = body.isEmpty
          ? <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(body) as Map);
      if (response.statusCode >= 400) {
        throw AtrustAuthException(
          data['message']?.toString() ??
              'auth request failed (${response.statusCode})',
        );
      }
      return data;
    } on AtrustAuthException {
      rethrow;
    } on SocketException catch (e) {
      throw AtrustAuthException(e.toString(), retryable: true);
    } on TimeoutException catch (e) {
      throw AtrustAuthException(e.toString(), retryable: true);
    } catch (e) {
      throw AtrustAuthException(e.toString());
    } finally {
      client.close(force: true);
    }
  }
}
