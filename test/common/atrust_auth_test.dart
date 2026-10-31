import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/atrust_auth.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late AtrustAuthApi api;

  Future<void> respond(
    HttpRequest request,
    Object body, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      switch ((request.method, request.uri.path)) {
        case ('GET', '/auth/v1/providers'):
          await respond(request, {
            'providers': [
              {
                'name': 'atrust',
                'state': 'ready',
                'server': 'vpn.zju.edu.cn',
                'port': 443,
                'account': '3230100888',
                'resources': 1472,
                'domains': 689,
                'cidrs': 783,
                'has_session': true,
              },
            ],
          });
        case ('POST', '/auth/v1/providers/atrust/sessions'):
          await respond(request, {
            'id': 'session-1',
            'url': 'http://127.0.0.1/auth/v1/s/session-1?t=nonce',
            'state': 'awaiting_input',
            'expires_at': '2026-10-30T12:10:00+08:00',
            'attempts_left': 5,
          });
        case ('POST', '/auth/v1/providers/atrust/logout'):
          await respond(request, {'state': 'need_login'});
        case ('DELETE', '/auth/v1/sessions/session-1'):
          await respond(request, {'state': 'cancelled'});
        default:
          await respond(request, {
            'code': 'not_found',
            'message': 'not found',
          }, status: 404);
      }
    });
    api = AtrustAuthApi('127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('reads provider status and resource counts', () async {
    final providers = await api.providers();
    expect(providers, hasLength(1));
    expect(providers.single.name, 'atrust');
    expect(providers.single.isReady, isTrue);
    expect(providers.single.domains, 689);
    expect(providers.single.cidrs, 783);
    expect(providers.single.account, '3230100888');
    expect(providers.single.server, 'vpn.zju.edu.cn');
    expect(providers.single.port, 443);
  });

  test('creates and cancels a login session', () async {
    final session = await api.createSession('atrust');
    expect(session.id, 'session-1');
    expect(session.state, 'awaiting_input');
    expect(session.attemptsLeft, 5);
    await api.cancelSession(session.id);
  });

  test('logs out', () async {
    await api.logout('atrust');
  });

  test('selects the injected provider then keeps the current one', () {
    const injected = AtrustStatus(name: 'atrust', state: 'ready');
    const own = AtrustStatus(name: 'own', state: 'need_login');

    expect(selectAtrustProviderName([own], null), 'own');
    expect(selectAtrustProviderName([own, injected], null), 'atrust');
    expect(selectAtrustProviderName([own, injected], 'own'), 'own');
    expect(selectAtrustProviderName([own], 'missing'), 'own');
    expect(selectAtrustProviderName([], 'own'), isNull);
  });

  test('turns an HTTP error into a readable exception', () async {
    await expectLater(
      api.logout('missing'),
      throwsA(isA<AtrustAuthException>()),
    );
  });
}
