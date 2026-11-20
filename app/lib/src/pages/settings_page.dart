import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webshell_core/webshell_core.dart';

import '../open.dart';
import '../state.dart';
import '../update_prompt.dart';
import '../widgets/centered.dart';
import 'site_edit_page.dart' show copyText;

/// 全局设置。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final ShellState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ShellState get state => widget.state;

  bool _checkingUpdate = false;

  /// 同步相关操作正在等网络（按钮期间禁掉重复点）。
  bool _busySync = false;

  final TextEditingController _endpointCtrl = TextEditingController();
  final TextEditingController _secretCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();

  /// 上一次「同步那块界面」的样子。用来把 `ShellState` 的高频通知
  /// （下载进度每秒好几次）滤掉，只在与同步有关的东西变了时才重建。
  String _syncSnapshot = '';

  @override
  void initState() {
    super.initState();
    _endpointCtrl.text = state.config.syncEndpoint;
    _syncSnapshot = _syncSignature();
    state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    state.removeListener(_onStateChanged);
    _endpointCtrl.dispose();
    _secretCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  String _syncSignature() => <String>[
        state.config.syncConfigured ? '1' : '0',
        state.config.syncEndpoint,
        state.syncStatus.name,
        state.syncStatusText,
        state.syncPending ? 'p' : '-',
        '${state.syncPendingRemovals}',
        '${state.syncLastRunMs}',
        '${state.syncDevices.length}',
      ].join('|');

  void _onStateChanged() {
    if (!mounted) return;
    final String now = _syncSignature();
    if (now == _syncSnapshot) return;
    _syncSnapshot = now;
    setState(() {});
  }

  /// 手动检查：不走 24h 节流（用户点都点了，就查一次）。
  /// 网络失败与"没有新版"在这里是同一个提示——更新检查不该弹错误对话框。
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final UpdateInfo? info = await UpdateChecker.fetch(state.branding);
      if (!mounted) return;
      if (info == null) {
        _snack('已是最新版本');
      } else {
        await showUpdateDialog(context, info, state.branding.appVersion);
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ShellConfig config = state.config;
    final Branding branding = state.branding;
    // 与 TrayController.supported 对齐：三桌面平台都显示，移动端不显示
    final bool desktop = !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Centered(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
          children: <Widget>[
            _section(context, '下载'),
            _card(context, <Widget>[
              ListTile(
                title: const Text('同时下载数'),
                subtitle: Text('${config.maxConcurrentDownloads} 个（带宽有限时调小一点更稳）'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Slider(
                  value: config.maxConcurrentDownloads.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  label: '${config.maxConcurrentDownloads}',
                  onChanged: (double value) {
                    setState(() {
                      config.maxConcurrentDownloads = value.round();
                      state.downloads.maxConcurrent = config.maxConcurrentDownloads;
                    });
                    state.saveSoon();
                  },
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                title: const Text('下载位置'),
                subtitle: Text(state.downloadDirectoryLabel),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (!Platform.isAndroid)
                      IconButton(
                        tooltip: '打开文件夹',
                        icon: const Icon(Icons.folder_open),
                        onPressed: () async {
                          final String? error =
                              await openDirectory(state.downloadDirectoryLabel);
                          if (error != null) _snack(error);
                        },
                      ),
                    IconButton(
                      tooltip: '复制路径',
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          copyText(context, state.downloadDirectoryLabel),
                    ),
                  ],
                ),
              ),
              if (!Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: const Text('更改下载位置'),
                  onTap: _pickDirectory,
                ),
              if (Platform.isAndroid)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Android 上文件默认保存在应用自己的目录（不需要存储权限，也不用担心被系统限制）。\n'
                    '想放进系统的「下载」或别的文件夹：在下载列表里选「另存为」即可。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ]),

            _section(context, '浏览'),
            _card(context, <Widget>[
              SwitchListTile(
                title: const Text('省流模式'),
                subtitle: const Text('不自动加载图片；重新打开站点后生效'),
                value: !config.loadImages,
                onChanged: (bool value) {
                  setState(() => config.loadImages = !value);
                  state.saveSoon();
                },
              ),
              SwitchListTile(
                title: const Text('保持登录状态'),
                subtitle: Text(config.saveLogin
                    ? '关闭后立即退出登录，且重启 App 不再保留登录态'
                    : '已关闭：登录态不落盘，重启后需重新登录'),
                value: config.saveLogin,
                onChanged: (bool value) async {
                  await state.setSaveLogin(value);
                  if (mounted) setState(() {});
                },
              ),
            ]),

            if (desktop) ...<Widget>[
              _section(context, '桌面'),
              _card(context, <Widget>[
                SwitchListTile(
                  title: const Text('关闭时收进系统托盘'),
                  subtitle: const Text('点关闭时藏到托盘、不退出；最小化照常进任务栏；托盘右键可以真正退出'),
                  value: config.closeToTray,
                  onChanged: (bool value) {
                    setState(() => config.closeToTray = value);
                    state.saveSoon();
                  },
                ),
              ]),
            ],

            _section(context, '同步'),
            _card(
              context,
              config.syncConfigured ? _syncActiveTiles(context) : _syncSetupTiles(context),
            ),

            _section(context, '隐私'),
            _card(context, <Widget>[
              ListTile(
                leading: const Icon(Icons.cookie_outlined),
                title: const Text('清空所有 Cookie'),
                subtitle: const Text('所有站点都会退出登录'),
                onTap: _confirmClearCookies,
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('清空下载记录'),
                subtitle: const Text('只清列表，不删已经下载好的文件'),
                onTap: () {
                  state.clearFinishedDownloads();
                  _snack('下载记录已清空');
                },
              ),
            ]),

            _section(context, '关于'),
            _card(context, <Widget>[
              ListTile(
                title: Text(branding.appName),
                subtitle: Text(
                  '万能壳 ${branding.appVersion}\n'
                  '${branding.isWhiteLabel ? '专属（白标）版本' : '通用版本'}\n'
                  '引擎：Android 系统 WebView / Windows WebView2',
                ),
              ),
              // updateUrl 是构建期输入（preset.json），运行期只读。
              // 通用壳默认没配 → 不显示这一项，用户不会点到"永远查不到"的死按钮。
              if ((branding.updateUrl ?? '').trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.system_update),
                  title: Text(_checkingUpdate ? '正在检查更新…' : '检查更新'),
                  subtitle: Text('当前版本 v${branding.appVersion}'),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
              if (state.engineUserAgent != null)
                ListTile(
                  title: const Text('当前引擎 UA'),
                  subtitle: Text(state.engineUserAgent!, style: const TextStyle(fontSize: 11)),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 分组小标题：中性灰、小一号、字距放开一点。
  /// 原来是"主色 + 加粗"，一屏四组就是四块彩色标签，像 2016 年的后台系统；
  /// 现在所有分组都是安静的一行说明，重量交给下面的卡片。
  Widget _section(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
      ),
    );
  }

  /// 一组设置 = 一张圆角卡片，卡片内条目之间用浅分隔线。
  Widget _card(BuildContext context, List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Future<void> _pickDirectory() async {
    try {
      final String? dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择下载位置',
      );
      if (dir == null || dir.isEmpty) return;
      setState(() => state.config.downloadDir = dir);
      state.saveNow();
    } catch (e) {
      _snack('选目录失败：$e');
    }
  }

  // ------------------------------------------------------------------ 同步

  /// 还没开同步时的几张条目。
  List<Widget> _syncSetupTiles(BuildContext context) {
    final ShellConfig config = state.config;
    return <Widget>[
      const ListTile(
        leading: Icon(Icons.cloud_sync_outlined),
        title: Text('多设备同步'),
        subtitle: Text(
          '把站点清单和偏好设置同步到你的其它设备，删站也会一起删。\n'
          '需要一个自己部署的 Cloudflare Worker（项目里的 worker-sync 目录，'
          '免费额度足够日常用）。不开也能正常使用，数据只留在这台设备上。',
        ),
        isThreeLine: true,
      ),
      ListTile(
        leading: const Icon(Icons.link),
        title: const Text('服务地址'),
        subtitle: Text(
          config.syncEndpoint.trim().isEmpty
              ? '未填写，例如 https://sync.example.com'
              : config.syncEndpoint,
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: _editEndpoint,
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      ListTile(
        leading: const Icon(Icons.key_outlined),
        title: const Text('开启同步（本机作为第一台设备）'),
        subtitle: const Text('要填部署 Worker 时设的密钥，只在这台设备上填一次'),
        onTap: _busySync ? null : _enableFirstDevice,
      ),
      ListTile(
        leading: const Icon(Icons.pin_outlined),
        title: const Text('用配对码加入'),
        subtitle: const Text('已经有一台设备在同步了？在那台设备上生成配对码，填到这里'),
        onTap: _busySync ? null : _joinWithCode,
      ),
    ];
  }

  /// 已经在同步时的条目。
  List<Widget> _syncActiveTiles(BuildContext context) {
    final SyncStatus st = state.syncStatus;
    final IconData icon = switch (st) {
      SyncStatus.ok => Icons.cloud_done_outlined,
      SyncStatus.running => Icons.cloud_sync_outlined,
      SyncStatus.offline => Icons.cloud_off_outlined,
      SyncStatus.authFailed => Icons.person_off_outlined,
      SyncStatus.error => Icons.error_outline,
      SyncStatus.needsConfirm => Icons.warning_amber_rounded,
      SyncStatus.disabled => Icons.cloud_off_outlined,
    };
    final Color? color = st == SyncStatus.authFailed ||
            st == SyncStatus.error ||
            st == SyncStatus.needsConfirm
        ? Theme.of(context).colorScheme.error
        : null;

    final StringBuffer sub = StringBuffer(state.syncStatusText);
    if (state.syncPending) sub.write(' · 有改动待上传');
    if (state.syncLastRunMs > 0) {
      sub.write('\n上次同步：${_hms(state.syncLastRunMs)}');
    }
    // 服务地址也露出来，便于用户确认自己连的是哪个 Worker。
    if (state.config.syncEndpoint.isNotEmpty) {
      sub.write('\n${state.config.syncEndpoint}');
    }

    return <Widget>[
      if (state.syncPendingRemovals > 0) _bigDeleteBanner(context),
      ListTile(
        leading: Icon(icon, color: color),
        title: const Text('同步已开启'),
        subtitle: Text(sub.toString()),
        isThreeLine: true,
        trailing: _busySync || st == SyncStatus.running
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                tooltip: '立即同步',
                icon: const Icon(Icons.sync),
                onPressed: _manualSync,
              ),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      ListTile(
        leading: const Icon(Icons.qr_code_2),
        title: const Text('显示配对码'),
        subtitle: const Text('在另一台设备上用它加入，10 分钟内有效、只能用一次'),
        onTap: _busySync ? null : _showPairCode,
      ),
      ListTile(
        leading: const Icon(Icons.devices_outlined),
        title: const Text('已配对设备'),
        subtitle: const Text('查看有哪些设备在同步，可以把某一台移出'),
        onTap: _busySync ? null : _showDevices,
      ),
      ListTile(
        leading: const Icon(Icons.history),
        title: const Text('云端历史版本'),
        subtitle: const Text('误删、合并出错时，退回之前某一版站点清单'),
        onTap: _busySync ? null : _showHistory,
      ),
      ListTile(
        leading: Icon(Icons.link_off, color: Theme.of(context).colorScheme.error),
        title: Text('断开同步', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        subtitle: const Text('这台设备停止同步，站点列表保持现状；别的设备不受影响'),
        onTap: _disconnectSync,
      ),
    ];
  }

  /// 骤降护栏拦下来时的那条黄色警告。
  ///
  /// 它出现在"检测到一次大量删除"之后：合并结果会让本机站点少一大半，
  /// 引擎停下不写，等人点一下。**两个按钮都必须有** —— 只会说"确认删除"的话，
  /// 用户一旦是被 bug 误导的就没退路；只会说"恢复上一版"的话，真有心想清空的
  /// 用户又被挡死。
  Widget _bigDeleteBanner(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int n = state.syncPendingRemovals;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '检测到一次大量删除（$n 个站点）',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '同步操作会让这台设备少掉 $n 个站点，已经先停下没执行。\n'
            '是你自己在另一台设备上删的，就确认；不是你干的，选恢复上一版。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: _busySync ? null : _showHistory,
                child: const Text('恢复上一版'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: _busySync ? null : _confirmBigDelete,
                child: Text('确认删除 $n 个'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmBigDelete() async {
    setState(() => _busySync = true);
    await state.syncConfirmBigDelete();
    if (!mounted) return;
    setState(() => _busySync = false);
    final int left = state.syncPendingRemovals;
    _snack(left > 0 ? '还有 $left 个待确认，再点一次' : '已按合并结果执行');
  }

  Future<void> _showHistory() async {
    setState(() => _busySync = true);
    List<SyncHistoryEntry> list = const <SyncHistoryEntry>[];
    String? err;
    try {
      list = await state.syncHistory();
    } on SyncException catch (e) {
      err = e.message;
    } catch (e) {
      err = '读取历史版本失败：$e';
    }
    if (!mounted) return;
    setState(() => _busySync = false);
    if (err != null) {
      _snack(err);
      return;
    }
    if (list.isEmpty) {
      _snack('云端还没有历史版本（每次成功推送后才会留一版）');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('云端历史版本'),
        content: SizedBox(
          width: 400,
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final SyncHistoryEntry h in list)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history_toggle_off, size: 20),
                  title: Text('第 ${h.version} 版 · ${h.siteCount} 个站点'),
                  subtitle: Text(_hms(h.createdAtMs), style: const TextStyle(fontSize: 12)),
                  trailing: TextButton(
                    onPressed: () async {
                      Navigator.of(dialogContext).pop();
                      await _restoreHistory(h.version, h.siteCount);
                    },
                    child: const Text('恢复'),
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreHistory(int version, int siteCount) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('恢复历史版本'),
        content: Text(
          '把云端内容退回第 $version 版（$siteCount 个站点）。\n'
          '这一版会成为新的当前版本，其它设备下次同步时也会跟着退回来。\n'
          '当前版本仍留在历史里，反悔了还能再选回来。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busySync = true);
    String? err;
    try {
      await state.syncRestoreHistory(version);
    } on SyncException catch (e) {
      err = e.message;
    } catch (e) {
      err = '恢复失败：$e';
    }
    if (!mounted) return;
    setState(() => _busySync = false);
    _snack(err ?? '已恢复到第 $version 版');
  }

  Future<void> _editEndpoint() async {
    _endpointCtrl.text = state.config.syncEndpoint;
    final String? value = await _askText(
      title: '服务地址',
      controller: _endpointCtrl,
      hint: 'https://sync.example.com',
      help: '你部署 Worker 时拿到的域名，末尾不要带路径。',
    );
    if (value == null) return;
    final String trimmed = value.trim();
    if (trimmed.isNotEmpty &&
        !trimmed.startsWith('https://') &&
        !trimmed.startsWith('http://')) {
      _snack('地址要以 https:// 或 http:// 开头');
      return;
    }
    // 必须走 state 里那个方法：它会把安全存储里凭证自带的 endpoint 一起改写。
    // 只 setState 改 config 的话，界面变了、请求还发往老地址 —— 老地址被墙时
    // 用户会以为"改完了还是坏的"。
    setState(() => _busySync = true);
    final String? err = await state.syncChangeEndpoint(trimmed);
    if (!mounted) return;
    setState(() => _busySync = false);
    _snack(err ?? '服务地址已更新');
  }

  Future<void> _enableFirstDevice() async {
    final String endpoint = state.config.syncEndpoint.trim();
    if (endpoint.isEmpty) {
      _snack('先填服务地址');
      return;
    }
    _secretCtrl.clear();
    final String? secret = await _askText(
      title: '部署密钥',
      controller: _secretCtrl,
      hint: '部署时设的 BOOTSTRAP_SECRET',
      help: '它只用来证明"这个 Cloudflare 项目是你的"。不知道的话去看 worker-sync/README.md。',
      obscure: true,
    );
    if (secret == null || secret.trim().isEmpty) return;

    setState(() => _busySync = true);
    final String? err = await state.syncEnableFirstDevice(
      endpoint: endpoint,
      bootstrapSecret: secret.trim(),
    );
    if (!mounted) return;
    setState(() => _busySync = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _snack('已开启同步，正在把本机站点传上去');
  }

  Future<void> _joinWithCode() async {
    final String endpoint = state.config.syncEndpoint.trim();
    if (endpoint.isEmpty) {
      _snack('先填服务地址');
      return;
    }
    _codeCtrl.clear();
    final String? code = await _askText(
      title: '配对码',
      controller: _codeCtrl,
      hint: '在另一台设备上生成的配对码',
      help: '在已经同步的那台设备上：设置 → 同步 → 显示配对码。10 分钟内有效。',
    );
    if (code == null || code.trim().isEmpty) return;

    setState(() => _busySync = true);
    final String? err = await state.syncJoinWithCode(
      endpoint: endpoint,
      code: code.trim(),
    );
    if (!mounted) return;
    setState(() => _busySync = false);
    if (err != null) {
      _snack(err);
      return;
    }
    _snack('配对成功，正在同步');
  }

  Future<void> _showPairCode() async {
    setState(() => _busySync = true);
    final String? err = await state.syncNewPairCode();
    if (!mounted) return;
    setState(() => _busySync = false);
    if (err != null) {
      _snack(err);
      return;
    }
    final SyncPairCode? pc = state.syncPairCode;
    if (pc == null) {
      _snack('没拿到配对码，稍后再试');
      return;
    }
    final int minutes = (pc.remainingMs / 60000).ceil().clamp(1, 999);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('配对码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SelectableText(
              pc.code,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '$minutes 分钟内有效，只能用一次。\n在另一台设备上：设置 → 同步 → 用配对码加入。',
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => copyText(dialogContext, pc.code),
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDevices() async {
    setState(() => _busySync = true);
    final String? err = await state.syncLoadDevices();
    if (!mounted) return;
    setState(() => _busySync = false);
    if (err != null) {
      _snack(err);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('已配对设备'),
        content: SizedBox(
          width: 380,
          child: state.syncDevices.isEmpty
              ? const Text('服务端没有返回任何设备。')
              : ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final SyncDeviceInfo d in state.syncDevices)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          d.revoked ? Icons.block : Icons.phone_iphone,
                          size: 20,
                        ),
                        title: Text(d.displayName),
                        subtitle: Text(
                          d.self
                              ? '这台设备'
                              : d.revoked
                                  ? '已移除'
                                  : '最近活跃：${_hms(d.lastSeenMs)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: d.revoked || d.self
                            ? null
                            : TextButton(
                                onPressed: () async {
                                  Navigator.of(dialogContext).pop();
                                  final String? revokeErr =
                                      await state.syncRevokeDevice(d.id);
                                  if (!mounted) return;
                                  _snack(revokeErr ?? '已移除 ${d.displayName}');
                                },
                                child: const Text('移除'),
                              ),
                      ),
                  ],
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _disconnectSync() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('断开同步'),
        content: const Text(
          '这台设备会停止同步，站点列表保持现在的样子（不会清空）。\n'
          '要重新连上：填一次配对码就行。别的设备不受影响。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.syncDisconnect();
    if (!mounted) return;
    setState(() {});
    _snack('已断开同步');
  }

  Future<void> _manualSync() async {
    setState(() => _busySync = true);
    final SyncRunResult r = await state.syncNow();
    if (!mounted) return;
    setState(() => _busySync = false);
    if (!r.ok) {
      _snack(r.message.trim().isEmpty ? '同步失败' : r.message);
      return;
    }
    if (r.pushed && r.pulled) {
      _snack('已同步：本机和其它设备都有改动，都合上了');
    } else if (r.pushed) {
      _snack('已上传本机改动');
    } else if (r.pulled) {
      _snack('已接收其它设备的改动');
    } else {
      _snack('已是最新');
    }
  }

  /// 一个只收一行文字的对话框。取消返回 null。
  Future<String?> _askText({
    required String title,
    required TextEditingController controller,
    String hint = '',
    String help = '',
    bool obscure = false,
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (help.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(help, style: const TextStyle(fontSize: 12)),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 时间戳 → 本地 `HH:mm`（今天的）或 `MM-dd HH:mm`。
  String _hms(int ms) {
    if (ms <= 0) return '—';
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
    return '${two(t.month)}-${two(t.day)} $hm';
  }

  Future<void> _confirmClearCookies() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清空所有 Cookie'),
        content: const Text('所有站点都会退出登录，下次要重新登录。继续？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.clearAllCookies();
    _snack('已清空所有 Cookie');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
