import 'dart:io';

import 'package:flutter/material.dart';
import 'package:starport_core/starport_core.dart';

/// 图标文件的存在性按路径缓存，**只缓存"存在"**。
///
/// 站点卡片会随着下载进度、同步状态这类跟图标毫无关系的通知反复重建，以前
/// 每次重建、每张卡片都要 `existsSync()` 一次：几十个站点就是每秒上百次系统
/// 调用，全压在 UI isolate 上。缓存"存在"就够了 —— 图标是后写进来的（首次
/// 抓取、重新抓取）时仍然立刻生效，坏路径最多维持原来的每次 stat 行为。
final Map<String, bool> _iconFileExists = <String, bool>{};

/// 站点图标：本地缓存的 favicon → 抓不到就退化成带颜色的首字母方块。
class SiteAvatar extends StatelessWidget {
  const SiteAvatar({super.key, required this.site, this.size = 40});

  final SiteProfile site;
  final double size;

  @override
  Widget build(BuildContext context) {
    final String? path = site.iconPath;
    final Widget fallback = _letter(context);
    if (path == null || path.isEmpty) return fallback;

    if (!_iconFileExists.containsKey(path)) {
      final File probe = File(path);
      if (!probe.existsSync()) return fallback;
      _iconFileExists[path] = true;
    }

    // 按显示尺寸解码。favicons 抓取端限到 512KB，里面常见的是 256x256 甚至
    // 更大的图，而这里只显示 size 这么大：不设上限就按原始分辨率付解码时间和
    // 内存（256x256 RGBA = 256KB / 张）。
    final int decodeWidth = (size * MediaQuery.devicePixelRatioOf(context)).ceil();

    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        cacheWidth: decodeWidth,
        fit: BoxFit.cover,
        // 图标格式五花八门（ico/svg/坏文件），解不出来就退回首字母，不要显示红屏
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) => fallback,
      ),
    );
  }

  Widget _letter(BuildContext context) {
    final String name = site.displayName;
    final String letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    final int color = site.themeColor != 0
        ? site.themeColor
        : Theme.of(context).colorScheme.primary.toARGB32();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(color),
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.45,
        ),
      ),
    );
  }
}
