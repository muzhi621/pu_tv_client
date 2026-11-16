import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/services/app_update/app_update_models.dart';

/// 回归（2026-11-16 审查 #5）：更新包此前只按大小 + ZIP 魔数校验，同尺寸镜像
/// 可替换 APK。现在 release 清单的 asset.digest（sha256:<hex>）会被解析并用于
/// 下载后端到端校验。这里覆盖解析层的边界，保证坏 digest 不会被当成校验通过。
void main() {
  final valid = List.filled(64, 'a').join();

  group('parseAssetDigest', () {
    test('解析合法的 sha256:<64 hex>', () {
      expect(parseAssetDigest('sha256:$valid'), valid);
      expect(parseAssetDigest('SHA256:${valid.toUpperCase()}'), valid);
    });

    test('空值 / 非 sha256 前缀返回空串', () {
      expect(parseAssetDigest(null), '');
      expect(parseAssetDigest(''), '');
      expect(parseAssetDigest('md5:$valid'), '');
      expect(parseAssetDigest(valid), ''); // 裸 hex 也拒绝，避免误把别的字段当摘要
    });

    test('长度或非 hex 字符的摘要返回空串', () {
      expect(parseAssetDigest('sha256:abc'), '');
      expect(parseAssetDigest('sha256:${List.filled(64, 'g').join()}'), '');
      expect(parseAssetDigest('sha256:${valid}z'), '');
    });
  });

  group('ReleaseAssetInfo.sha256', () {
    test('默认空摘要，构造时带入', () {
      const asset = ReleaseAssetInfo(name: 'x.apk', url: 'https://x/x.apk', sizeBytes: 1);
      expect(asset.sha256, '');
      final withDigest = ReleaseAssetInfo(
        name: 'x.apk', url: 'https://x/x.apk', sizeBytes: 1, sha256: valid,
      );
      expect(withDigest.sha256, valid);
    });
  });
}
