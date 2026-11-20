import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 打开平台视图（WebView）之前，把 Flutter 这边的输入状态彻底交出去。
///
/// ## 为什么需要这一步
///
/// 平台视图是**独立的输入宿主**：它有自己的焦点、自己的输入法连接
/// （Windows 上是 WebView2 的子 HWND 焦点，Android 上是 `InputConnection`，
/// iOS / macOS 上是 `WKWebView` 的 firstResponder）。
///
/// 只要 Flutter 这头还攥着一个焦点或者一条 IME 连接，平台视图的第一次交互就要先
/// 做一次"交接"。交接过程里必然有一次 blur → focus 往返，而按 DOM 规范：
///
///   * 元素**失焦**时，选区立刻塌成插入点；
///   * 元素**重新获得焦点**时，光标落在文本末尾。
///
/// 于是用户拖选出来那段高亮还在（那只是绘制残影），但按键送到页面时选区已经空了，
/// `Delete` / `Backspace` 就退化成"删掉末尾一个字符"——不是删得慢，是选区没了。
///
/// 首页有两个 TextField（网址 / 名字），从「添加站点」直接进站时它们往往还持有焦点
/// 和 IME 连接，所以症状在"进站后的第一次拖选"上最明显；先点一下页面把焦点落地，
/// 之后再拖选就正常。这正是实机复现出来的分界。
///
/// ## 做三件事
///
/// 1. `FocusScope.unfocus()`：把焦点从输入框上摘下来；
/// 2. `TextInput.hide`：显式**关掉** Flutter 的文本输入连接。只 unfocus 的话，
///    连接可能还挂着，输入法会继续按旧状态发编辑命令；
/// 3. 让出一个事件循环：等焦点 / 输入连接变更真正传到引擎侧，再 push 路由，
///    避免交接和页面转场动画叠在一起。
///
/// 这三步都只动 **Flutter 自己的**输入状态，不碰网页里的 DOM 焦点和选区。
Future<void> releaseInputForPlatformView(BuildContext context) async {
  FocusScope.of(context).unfocus();

  // 没有活动连接时这个调用是幂等的，不会抛错。
  try {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  } catch (_) {
    // 极少数平台/无头环境下这条通道不可用；unfocus 已经把主要问题解决掉了。
  }

  // 焦点变更在下一帧才传递给平台侧的输入插件。
  await Future<void>.delayed(Duration.zero);
}
