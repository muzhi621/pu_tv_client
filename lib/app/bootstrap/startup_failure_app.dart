import 'dart:io';

import 'package:flutter/material.dart';

/// 构建期异常（某个 widget 的 build 抛错）的替代显示。
///
/// release 包默认把这种情况画成一块灰屏，用户只能看到"界面没了"。这里换成
/// 可读文本 + 具体异常，配合启动追踪文件就能定位。
class BuildErrorView extends StatelessWidget {
  const BuildErrorView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF101014),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '界面渲染失败',
                  style: TextStyle(color: Color(0xFFFF6B6B), fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  message,
                  style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 16, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 启动失败时替代主界面渲染的最小页面。
///
/// 刻意不依赖 riverpod / easy_localization / 主题：这些正是启动失败时可能
/// 不可用的东西，一旦这里再抛异常就又是纯黑屏，等于什么都没解决。全部用
/// 框架内置的组件与硬编码颜色，保证「只要 Flutter 引擎能起，这页就能画出来」。
///
/// 页面直接展示失败原因与启动追踪文件路径——用户截图一张就能定位问题，
/// 不需要连 adb、也不需要去翻文件管理器。
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    this.error,
    this.tracePath,
    this.deviceInfo,
    this.okSteps = 0,
    this.failedSteps = 0,
  });

  final Object? error;
  final String? tracePath;
  final String? deviceInfo;
  final int okSteps;
  final int failedSteps;

  @override
  Widget build(BuildContext context) {
    final String message = (error ?? '启动未完成，且没有捕获到具体异常').toString();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '启动失败',
                    style: TextStyle(color: Color(0xFFFF6B6B), fontSize: 34, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '已完成 $okSteps 步，失败 $failedSteps 步。请把这个页面截图发给开发者。',
                    style: const TextStyle(color: Color(0xFFB8B8C0), fontSize: 18),
                  ),
                  if (deviceInfo != null) ...<Widget>[
                    const SizedBox(height: 8),
                    SelectableText(
                      deviceInfo!,
                      style: const TextStyle(color: Color(0xFFB8B8C0), fontSize: 16, height: 1.4),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                    '错误信息',
                    style: TextStyle(color: Color(0xFF8A8A96), fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    message,
                    style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 18, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '启动追踪文件',
                    style: TextStyle(color: Color(0xFF8A8A96), fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    tracePath ?? '（未能创建：${Platform.operatingSystem} 上写入失败）',
                    style: const TextStyle(color: Color(0xFF9AD1FF), fontSize: 16, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '处理建议\n'
                    '1. 退出重进一次（偶发失败可直接恢复）\n'
                    '2. 若反复出现，删除应用数据后重试\n'
                    '3. 仍不行请截图本页，并附带上面的追踪文件',
                    style: TextStyle(color: Color(0xFFB8B8C0), fontSize: 16, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
