import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/root_tabs.dart';

void main() {
  test(
    'root navigation contains four destinations and no notification slot',
    () {
      expect(RootTabs.count, 4);
      expect(RootTabs.tasks(2), 2);
      expect(RootTabs.panels(2), 3);
      expect(RootTabs.devices(2), 4);
      expect(RootTabs.settings(2), 5);
      expect(RootTabs.children(2), 6);
      expect(RootTabs.onRoot(4, 2), isTrue);
      expect(RootTabs.onRoot(6, 2), isFalse);
    },
  );
}
