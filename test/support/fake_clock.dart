/// 可手动推进的墙钟：注入 `PlayerScreen` / `SleepTimer` 的 `now`。
///
/// widget 测试运行在 FakeAsync 里，`DateTime.now()` 仍是真实时间，定时相关
/// 的用例必须把时间来源换成这里。
class FakeClock {
  DateTime _now = DateTime(2026, 11, 26, 23);

  DateTime now() => _now;

  void advance(Duration by) {
    _now = _now.add(by);
  }
}
