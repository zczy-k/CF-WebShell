// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 zczy-k

/// 星港（Starport）的核心库。
///
/// 这一层**不依赖 Flutter**：站点档案、配置持久化、URL 规则、下载队列都在这里，
/// 因此可以用 `dart test` 秒级验证，不用等 APK 构建。
library;

export 'src/config.dart';
export 'src/download.dart';
export 'src/headers.dart';
export 'src/models.dart';
export 'src/paths.dart';
export 'src/sync/client.dart';
export 'src/sync/doc.dart';
export 'src/sync/pacing.dart';
export 'src/sync/service.dart';
export 'src/sync/state.dart';
export 'src/update.dart';
export 'src/url_utils.dart';
