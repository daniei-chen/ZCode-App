import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zremote/state/account_label.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccountLabel.profileFromUserInfo', () {
    test('displayName + 可信 avatarUrl 全量解析', () {
      final profile = AccountLabel.profileFromUserInfo(
        '{"id":"u1","username":"chen","displayName":"哆啦A梦",'
        '"avatarUrl":"https://cdn.bigmodel.cn/avatar/u1.png"}',
      );
      expect(profile.name, '哆啦A梦');
      expect(profile.avatarUrl, 'https://cdn.bigmodel.cn/avatar/u1.png');
    });

    test('displayName 缺席回退 username；avatarUrl 缺席回退 null（字母头像）', () {
      final profile = AccountLabel.profileFromUserInfo(
        '{"id":"u1","username":"chen"}',
      );
      expect(profile.name, 'chen');
      expect(profile.avatarUrl, isNull);
    });

    test('非白名单图床的 avatarUrl 不返回（原生不加载第三方网络面）', () {
      final profile = AccountLabel.profileFromUserInfo(
        '{"displayName":"a","avatarUrl":"https://evil.example.com/a.png"}',
      );
      expect(profile.name, 'a');
      expect(profile.avatarUrl, isNull);
    });

    test('http 头像不加载（仅 https）', () {
      expect(
        AccountLabel.isTrustedAvatarUrl('http://cdn.bigmodel.cn/a.png'),
        isFalse,
      );
    });

    test('伪装域不匹配（按 label 对齐，防止 evil-z.ai.attacker.com）', () {
      expect(
        AccountLabel.isTrustedAvatarUrl('https://evil-z.ai.attacker.com/a.png'),
        isFalse,
      );
      expect(
        AccountLabel.isTrustedAvatarUrl('https://bigmodel.cn.attacker.io/a.png'),
        isFalse,
      );
    });

    test('白名单域与子域匹配', () {
      expect(AccountLabel.isTrustedAvatarUrl('https://zcode.z.ai/a.png'), isTrue);
      expect(
        AccountLabel.isTrustedAvatarUrl('https://cdn.bigmodel.cn/a.png'),
        isTrue,
      );
      expect(
        AccountLabel.isTrustedAvatarUrl('https://sfile.chatglm.cn/a.png'),
        isTrue,
      );
    });

    test('探针返回的 JSON 字符串外壳（引号包裹）照常解析', () {
      // evaluateJavascript 对 JS 字符串返回值做 JSON 序列化：外层再包一
      // 对引号。模拟同款形状（外层引号 + 内层合法 JSON）。
      const inner = '{"displayName":"名字"}';
      final profile = AccountLabel.profileFromUserInfo('"$inner"');
      expect(profile.name, '名字');
    });

    test('非 JSON / 空串返回空资料', () {
      expect(AccountLabel.profileFromUserInfo('').isEmpty, isTrue);
      expect(AccountLabel.profileFromUserInfo('not json').isEmpty, isTrue);
    });
  });

  group('AccountProfileNotifier', () {
    test('report 持久化名字与头像；重启后 build 读回（SharedPreferences）',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(accountProfileProvider.notifier)
          .report(
            const AccountProfile(
              name: '哆啦A梦',
              avatarUrl: 'https://cdn.bigmodel.cn/a.png',
            ),
          );
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('zremote.account.name'), '哆啦A梦');
      expect(prefs.getString('zremote.account.avatar'),
          'https://cdn.bigmodel.cn/a.png');

      // 新容器模拟重启：build 从存储读回。
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      // 先读一次触发 build/_load，再等异步装载完成。
      container2.read(accountProfileProvider);
      await pumpEventQueue();
      final restored = container2.read(accountProfileProvider);
      expect(restored.name, '哆啦A梦');
      expect(restored.avatarUrl, 'https://cdn.bigmodel.cn/a.png');
    });

    test('名字与头像分次补充，互不覆盖', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(accountProfileProvider.notifier);

      notifier.report(const AccountProfile(name: '只有名字'));
      await pumpEventQueue();
      notifier.report(
        const AccountProfile(avatarUrl: 'https://zcode.z.ai/a.png'),
      );
      await pumpEventQueue();

      final state = container.read(accountProfileProvider);
      expect(state.name, '只有名字');
      expect(state.avatarUrl, 'https://zcode.z.ai/a.png');
    });

    test('空资料不写入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accountProfileProvider.notifier).report(const AccountProfile());
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('zremote.account.name'), isNull);
    });
  });
}
