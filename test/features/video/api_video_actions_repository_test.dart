import 'dart:convert';
import 'dart:typed_data';

import 'package:bili_api/bili_api.dart';
import 'package:bilisail/core/network/api_requests.dart';
import 'package:bilisail/domain/app_failure.dart';
import 'package:bilisail/domain/request_cancellation.dart';
import 'package:bilisail/domain/video.dart';
import 'package:bilisail/features/video/data/api_video_actions_repository.dart';
import 'package:bilisail/features/video/domain/video_actions_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const target = (id: VideoId('BV1234567890'), aid: '42');

  test('a rejected 4xx write surfaces as a definite failure', () async {
    final transport = _Transport()..status = 404;
    final repository = _repository(transport);
    await expectLater(
      repository.sendDanmaku(
        target,
        '8',
        'hello',
        Duration.zero,
        1,
        0xffffff,
        RequestCancellation(),
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(transport.posts, 1);
    expect(transport.uri?.path, '/x/v2/dm/post');
  });

  test('a server error leaves the write outcome unknown', () async {
    final transport = _Transport()..status = 500;
    final repository = _repository(transport);
    await expectLater(
      repository.like(target, true, RequestCancellation()),
      throwsA(isA<UnknownWriteOutcome>()),
    );
    expect(transport.posts, 1);
  });
}

ApiVideoActionsRepository _repository(_Transport transport) {
  final requests = ApiRequests();
  final api = BiliApiClient(
    transport: transport,
    cookieJar: ApiCookieJar()
      ..receive(Uri.https('api.bilibili.com', '/'), [
        'SESSDATA=fixture; Path=/; Secure',
        'bili_jct=fixture-csrf; Path=/; Secure',
      ]),
    sessionProvider: requests,
  );
  addTearDown(api.close);
  return ApiVideoActionsRepository(
    VideoActionsClient(api),
    requests,
    accountScope: () => 'user:1',
  );
}

final class _Transport implements ApiTransport, ApiFormTransport {
  int posts = 0;
  int status = 200;
  Uri? uri;
  @override
  Future<ApiHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
    ApiCancellation? cancellation,
  }) async => _response({'dmid': 1});

  @override
  Future<ApiHttpResponse> postForm(
    Uri uri, {
    required Map<String, String> fields,
    required Map<String, String> headers,
    required Duration timeout,
    ApiCancellation? cancellation,
  }) async {
    posts++;
    this.uri = uri;
    return _response({'dmid': 1}, status: status);
  }

  ApiHttpResponse _response(Object? data, {int status = 200}) =>
      ApiHttpResponse(
        status,
        Uint8List.fromList(utf8.encode(jsonEncode({'code': 0, 'data': data}))),
        const {},
      );
}
