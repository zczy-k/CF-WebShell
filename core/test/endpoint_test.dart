/// [normalizeEndpoint] 的自适应剥离测试。
///
/// 起因是一台真机的截图：设置页服务地址填了 `https://xxx/v1/health`，
/// 客户端把 `/v1/bootstrap` 拼上去后 Worker 认不出
/// `/v1/health/v1/bootstrap`，所有未知路径都落进鉴权兜底，回 `unauthorized`。
/// 与其让用户研究"地址怎么填"，不如把用户粘进来的任何尾巴都自动削掉。
library;

import 'package:test/test.dart';
import 'package:starport_core/starport_core.dart';

void main() {
  group('normalizeEndpoint', () {
    test('纯域名原样返回', () {
      expect(normalizeEndpoint('https://sync.example.com'), 'https://sync.example.com');
    });

    test('去掉末尾斜杠', () {
      expect(normalizeEndpoint('https://sync.example.com/'), 'https://sync.example.com');
      expect(normalizeEndpoint('https://sync.example.com///'), 'https://sync.example.com');
    });

    test('带 /v1/health 剥回域名（本 bug 的现场）', () {
      expect(
        normalizeEndpoint('https://starport.zczy6.dpdns.org/v1/health'),
        'https://starport.zczy6.dpdns.org',
      );
    });

    test('完整接口路径整段砍掉', () {
      expect(
        normalizeEndpoint('https://sync.example.com/v1/bootstrap'),
        'https://sync.example.com',
      );
      expect(
        normalizeEndpoint('https://sync.example.com/v1/state'),
        'https://sync.example.com',
      );
      expect(
        normalizeEndpoint('https://sync.example.com/v1/pair'),
        'https://sync.example.com',
      );
    });

    test('双层接口路径（用户真的可能粘成这样）', () {
      expect(
        normalizeEndpoint('https://sync.example.com/v1/health/v1/bootstrap'),
        'https://sync.example.com',
      );
    });

    test('没有 v1 时剥掉裸接口名', () {
      expect(normalizeEndpoint('https://sync.example.com/health'), 'https://sync.example.com');
      expect(normalizeEndpoint('https://sync.example.com/bootstrap'), 'https://sync.example.com');
    });

    test('自定义子路径保留（Worker 挂在子路径下）', () {
      expect(
        normalizeEndpoint('https://example.com/starport'),
        'https://example.com/starport',
      );
      expect(
        normalizeEndpoint('https://example.com/starport/v1/health'),
        'https://example.com/starport',
      );
    });

    test('缺协议补 https', () {
      expect(
        normalizeEndpoint('sync.example.com/v1/health'),
        'https://sync.example.com',
      );
    });

    test('扔掉 query 和 fragment', () {
      expect(
        normalizeEndpoint('https://sync.example.com/v1/health?debug=1#top'),
        'https://sync.example.com',
      );
    });

    test('保留端口', () {
      expect(
        normalizeEndpoint('https://sync.example.com:8443/v1/bootstrap'),
        'https://sync.example.com:8443',
      );
    });

    test('空串原样返回，纯空白收敛成空', () {
      expect(normalizeEndpoint(''), '');
      expect(normalizeEndpoint('   '), '');
    });
  });
}
