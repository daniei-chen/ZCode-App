import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/models/device.dart';
import 'package:zremote/services/credential_fingerprint.dart';
import 'package:zremote/services/device_import.dart';

RemoteDevice _device(String sid) => RemoteDevice(
  id: 'id-$sid',
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: {'sid': sid, 'hash': 'h'},
  label: '',
  createdAt: DateTime(2026, 1, 1),
);

RemoteDevice _tokenDevice(
  String token, {
  String id = 'id-token',
  Map<String, String> extra = const {},
  String baseUrl = 'https://zcode.z.ai/remote/v4',
}) => RemoteDevice(
  id: id,
  baseUrl: baseUrl,
  params: {'t': token, ...extra},
  label: '',
  createdAt: DateTime(2026, 1, 1),
);

/// 完全没有任何凭证字段的条目（不可判定是否重复）。
RemoteDevice credentialless(String id) => RemoteDevice(
  id: id,
  baseUrl: 'https://zcode.z.ai/remote/v4',
  params: const {'name': 'x'},
  label: '',
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  group('findDuplicateBySid（兼容入口，按凭证指纹判定）', () {
    test('同 sid 命中：返回既有条目（不是新候选）', () {
      final existing = [_device('AAA')];
      final hit = findDuplicateBySid(existing, _device('AAA'));
      expect(hit, same(existing.first));
    });

    test('不同 sid 不命中', () {
      final existing = [_device('AAA')];
      expect(findDuplicateBySid(existing, _device('BBB')), isNull);
    });

    test('凭证全空（异常链接）不查重直接放行', () {
      final existing = [credentialless('id-1')];
      expect(findDuplicateBySid(existing, credentialless('id-2')), isNull);
    });

    test('双方都无 sid 但 hash 相同 → 仍判为同一条链接（旧实现漏判）', () {
      final existing = [_device('')];
      expect(findDuplicateBySid(existing, _device('')), same(existing.first));
    });

    test('一方有 sid 一方没有 → 只能靠指纹判定（不同凭证不合并）', () {
      final existing = [_device('AAA')];
      expect(findDuplicateDevice(existing, _tokenDevice('TOKEN-1')), isNull);
      expect(
        findDuplicateDevice([_tokenDevice('TOKEN-1')], _device('AAA')),
        isNull,
      );
    });

    test('空列表不命中', () {
      expect(findDuplicateBySid([], _device('AAA')), isNull);
    });
  });

  group('findDuplicateBySidExcept（更换链接流程）', () {
    test('撞自己的 sid → 放行（hash 轮换属合法更换）', () {
      final existing = [_device('AAA'), _device('BBB')];
      final hit = findDuplicateBySidExcept(existing, _device('AAA'), 'id-AAA');
      expect(hit, isNull);
    });

    test('撞别的设备的 sid → 命中该设备（重复接入拦截）', () {
      final existing = [_device('AAA'), _device('BBB')];
      final hit = findDuplicateBySidExcept(existing, _device('BBB'), 'id-AAA');
      expect(hit, same(existing.last));
    });
  });

  group('凭证指纹去重（F24：只带 token 的链接也能去重）', () {
    test('同一 token 再次导入 → 命中既有设备', () {
      final existing = [_tokenDevice('TOKEN-1', id: 'id-1')];
      final hit = findDuplicateDevice(existing, _tokenDevice('TOKEN-1'));
      expect(hit, same(existing.first));
      // 兼容入口同样按指纹判定。
      expect(findDuplicateBySid(existing, _tokenDevice('TOKEN-1')), isNotNull);
    });

    test('不同 token 不命中', () {
      final existing = [_tokenDevice('TOKEN-1')];
      expect(findDuplicateDevice(existing, _tokenDevice('TOKEN-2')), isNull);
    });

    test('参数顺序/大小写键名不影响指纹（归一化后比较）', () {
      final existing = [
        RemoteDevice(
          id: 'id-a',
          baseUrl: 'https://zcode.z.ai/remote/v4',
          params: const {'sid': 'S1', 'Token': 'T1'},
          label: '',
          createdAt: DateTime(2026, 1, 1),
        ),
      ];
      final candidate = RemoteDevice(
        id: 'id-b',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'token': 'T1', 'sid': 'S1'},
        label: '别的名字也可以',
        createdAt: DateTime(2026, 2, 2),
      );
      expect(findDuplicateDevice(existing, candidate), same(existing.first));
    });

    test('换个 baseUrl（不同站点/版本）不算同一条链接', () {
      final existing = [_tokenDevice('TOKEN-1')];
      final other = _tokenDevice(
        'TOKEN-1',
        baseUrl: 'https://zcode.z.ai/remote/v5',
      );
      expect(findDuplicateDevice(existing, other), isNull);
    });

    test('只有无关参数（无凭证）时不可判定 → 不去重', () {
      final bare = RemoteDevice(
        id: 'id-bare',
        baseUrl: 'https://zcode.z.ai/remote/v4',
        params: const {'name': 'x'},
        label: '',
        createdAt: DateTime(2026, 1, 1),
      );
      expect(CredentialFingerprint.of(bare), isNull);
      expect(findDuplicateDevice([bare], bare), isNull);
    });

    test('exceptId 排除自己（更换链接：同凭证轮换不算重复）', () {
      final existing = [_tokenDevice('TOKEN-1', id: 'id-1')];
      expect(
        findDuplicateDevice(existing, _tokenDevice('TOKEN-1'), exceptId: 'id-1'),
        isNull,
      );
      expect(
        findDuplicateDevice(existing, _tokenDevice('TOKEN-1'), exceptId: 'id-2'),
        isNotNull,
      );
    });
  });

  group('CredentialFingerprint', () {
    test('指纹稳定且不可逆（同一输入同一摘要，不含明文）', () {
      final device = _tokenDevice('SUPER-SECRET-TOKEN');
      final first = CredentialFingerprint.of(device);
      final second = CredentialFingerprint.of(device);
      expect(first, isNotNull);
      expect(first, second);
      expect(first!.length, 64, reason: 'SHA-256 十六进制');
      expect(first.contains('SUPER-SECRET-TOKEN'), isFalse);
      expect(CredentialFingerprint.display(device)!.length, 8);
    });

    test('任一凭证字段变化都会改变指纹', () {
      final a = _tokenDevice('T1', extra: const {'sid': 'S1'});
      final b = _tokenDevice('T1', extra: const {'sid': 'S2'});
      expect(CredentialFingerprint.of(a), isNot(CredentialFingerprint.of(b)));
    });
  });
}
