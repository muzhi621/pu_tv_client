import 'package:pure_live/exports/exports.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

/// TVBox 爬虫宿主诊断页。
///
/// 这一页不做业务，只做一件事：把「jar 能不能下 → 类能不能找 → 实例能不能建
/// → spider 方法能不能调」四个环节的状态和失败原因全部摊在屏幕上。
///
/// 为什么要专门做这一页：DexClassLoader 加载第三方 jar 属于纯运行时行为，
/// CI 只保证编得过，跑不跑得通必须真机验。而电视上没有 adb、没发复制文本，
/// 一旦失败只说「不行」就等于没法排查——所以每一步都要落成可读文案，
/// 让用户拍照就能定位问题。
///
/// 界面文案暂时硬编码中文：它是接入期工具，等功能收敛后随板块 UI
/// 一起走 i18n。
class VodDiagPage extends ConsumerStatefulWidget {
  const VodDiagPage({super.key});

  @override
  ConsumerState<VodDiagPage> createState() => _VodDiagPageState();
}

class _VodDiagPageState extends ConsumerState<VodDiagPage> {
  static const double _pagePadding = 32;
  static const String _siteKey = 'diag';

  String _jarUrl = '';
  String _ext = '';
  String? _selectedApi;

  /// 云端下发的 TVBox 源与站点。电视上用遥控器打长 URL 不现实，
  /// 所以主路径是「从云端选源」，手输只作为兜底。
  VodConfig _vod = VodConfig.empty;

  /// 云端源的一行摘要，单独显示，避免被诊断/操作输出覆盖。
  String _cloudHint = '正在读取云端配置…';

  VodHostDiagnostics? _diagnostics;
  VodJarInspection? _inspection;
  VodSitePreparation? _preparation;
  VodSpiderCall? _callResult;

  String _output = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCloudConfig();
      _runDiagnostics();
    });
  }

  // --------------------------------------------------------------- 操作

  /// 读云端已展开的源与站点。这条路走通之后，真机验证就只剩点选，
  /// 不用在电视上敲地址。
  void _loadCloudConfig() {
    final vod = RemoteConfigService.vod;
    if (!mounted) return;
    setState(() {
      _vod = vod;
      if (vod.isEmpty) {
        _cloudHint = '云端没有下发 TVBox 源。\n'
            '先在编辑器「TVBox 源」导入一个配置，到「终端管理」给这台设备勾选源，'
            '再回到这里点「重新检测」。';
        return;
      }
      final withJar = vod.sources.where((source) => source.hasJar).length;
      _cloudHint = '${vod.sources.length} 个源（$withJar 个带 spider jar）、'
          '${vod.sites.length} 个站点。';
      // 只有一个带 jar 的源时直接预填，少按两次遥控器。
      if (withJar == 1) {
        _jarUrl = vod.sources.firstWhere((source) => source.hasJar).jar;
      }
    });
  }

  Future<void> _pickCloudSource() async {
    final candidates = _vod.sources.where((source) => source.hasJar).toList();
    if (candidates.isEmpty) {
      setState(() => _output = _vod.sources.isEmpty
          ? '云端没有下发源。'
          : '云端 ${_vod.sources.length} 个源都没有配置 spider jar 地址。\n'
              '到编辑器「TVBox 源」里补上 jar（就是 TVBox 配置里的 spider 字段）。');
      return;
    }
    final picked = await TvDialogUtils.showSelect<VodSource>(
      context: context,
      title: '选择源',
      items: candidates
          .map((source) => TvSelectItem<VodSource>(title: source.name, value: source, subtitle: source.jar))
          .toList(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _jarUrl = picked.jar;
      _inspection = null;
      _preparation = null;
      _callResult = null;
      _selectedApi = null;
      _output = '已选源「${picked.name}」，jar: ${picked.jar}';
    });
  }

  /// 从云端站点列表直接选一个，同时带上它的 api 与 ext。
  Future<void> _pickCloudSite() async {
    final candidates = _vod.spiderSites;
    if (candidates.isEmpty) {
      setState(() => _output = _vod.sites.isEmpty
          ? '云端没有下发站点。'
          : '云端 ${_vod.sites.length} 个站点里没有 csp_ 站点（都是纯 HTTP 采集站），'
              '不需要 spider jar。');
      return;
    }
    final picked = await TvDialogUtils.showSelect<VodSite>(
      context: context,
      title: '选择站点',
      items: candidates
          .map((site) => TvSelectItem<VodSite>(
                title: site.name,
                value: site,
                subtitle: '${site.spiderKey}${site.ext.isEmpty ? '' : ' · ext 已配置'}',
              ))
          .toList(),
    );
    if (picked == null || !mounted) return;
    final jar = _vod.jarFor(picked);
    setState(() {
      _selectedApi = picked.spiderKey;
      _ext = picked.ext;
      if (jar != null) _jarUrl = jar;
      _inspection = null;
      _preparation = null;
      _callResult = null;
      _output = '已选站点「${picked.name}」（${picked.api}）'
          '${jar == null ? '\n注意：该站点所属源没有 jar，加载会失败。' : ''}';
    });
  }

  Future<void> _runDiagnostics() async {
    await _guard(() async {
      final diag = await VodSpiderChannel.diagnostics();
      if (!mounted) return;
      setState(() {
        _diagnostics = diag;
        if (diag.ok) {
          _output = '宿主环境正常：契约类与运行时实现类都已就位。'
              '填入 spider jar 地址后点「检查 jar」。';
        } else {
          final parts = <String>[];
          if (diag.hostClassesMissing.isNotEmpty) {
            parts.add('契约类缺失：${diag.hostClassesMissing.join(', ')}\n'
                'catvod-api.jar 没打进 APK，或被打包器裁掉了。');
          }
          if (diag.runtimeClassesMissing.isNotEmpty) {
            parts.add('运行时实现类缺失：${diag.runtimeClassesMissing.join(', ')}\n'
                '这些类由 src/main/java/com/github/catvod 提供，'
                '缺了说明依赖没声明或 R8 规则漏写。');
          }
          _output = parts.join('\n\n');
        }
        if (diag.optionalClassesMissing.isNotEmpty) {
          _output += '\n\n可选能力未启用（只影响特定站点，不阻断基础链路）：\n'
              '${diag.optionalClassesMissing.join(', ')}';
        }
      });
    });
  }

  Future<void> _editJarUrl() async {
    final value = await TvDialogUtils.showInput(
      context: context,
      title: 'spider jar 地址',
      hintText: 'https://…/spider.jar',
      initialValue: _jarUrl,
    );
    if (value == null || !mounted) return;
    setState(() {
      _jarUrl = value.trim();
      _inspection = null;
      _preparation = null;
      _callResult = null;
      _selectedApi = null;
    });
  }

  Future<void> _editExt() async {
    final value = await TvDialogUtils.showInput(
      context: context,
      title: '站点 ext 参数（可留空）',
      hintText: '多数站点留空，个别需要 token 或地址',
      initialValue: _ext,
    );
    if (value == null || !mounted) return;
    setState(() => _ext = value.trim());
  }

  Future<void> _inspectJar() async {
    if (_jarUrl.isEmpty) {
      setState(() => _output = '先填写 spider jar 地址。');
      return;
    }
    await _guard(() async {
      final result = await VodSpiderChannel.inspectJar(url: _jarUrl, force: true);
      if (!mounted) return;
      setState(() {
        _inspection = result;
        _preparation = null;
        _callResult = null;
        if (!result.ok) {
          _selectedApi = null;
          _output = 'jar 检查失败：\n${result.failure!.summary}';
          return;
        }
        _selectedApi = result.spiders.isNotEmpty ? result.spiders.first : null;
        _output = result.spiders.isEmpty
            ? 'jar 下载成功，但里面没有 com.github.catvod.spider.* 类。\n'
                '可能这个 jar 只是运行时依赖包，不是爬虫 jar。'
            : 'jar 里有 ${result.spiders.length} 个爬虫类，先选中一个再点「加载站点」。';
      });
    });
  }

  Future<void> _prepareAndCall() async {
    final api = _selectedApi;
    if (api == null) {
      setState(() => _output = '还没有选中爬虫类，先检查 jar。');
      return;
    }
    await _guard(() async {
      final prepared = await VodSpiderChannel.prepareSite(
        siteKey: _siteKey,
        jarUrl: _jarUrl,
        api: 'csp_$api',
        ext: _ext,
        force: true,
      );
      if (!mounted) return;
      if (!prepared.ok) {
        setState(() {
          _preparation = prepared;
          _callResult = null;
          _output = '实例化失败：\n${prepared.failure!.summary}';
        });
        return;
      }

      final call = await VodSpiderChannel.homeContent(siteKey: _siteKey);
      if (!mounted) return;
      setState(() {
        _preparation = prepared;
        _callResult = call;
        _output = call.ok
            ? 'homeContent 成功（${call.elapsedMs} ms）\n\n${_preview(call.value)}'
            : 'homeContent 失败：\n${call.failure!.summary}'
                '${call.failure!.stack == null ? '' : '\n\n${call.failure!.stack}'}';
      });
    });
  }

  Future<void> _pickSpider(List<String> spiders) async {
    if (spiders.isEmpty) return;
    final picked = await TvDialogUtils.showSelect<String>(
      context: context,
      title: '选择爬虫类',
      items: spiders.map((name) => TvSelectItem<String>(title: name, value: name)).toList(),
      selectedValue: _selectedApi,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedApi = picked);
  }

  /// 统一处理「忙碌态 + 异常兜底」，避免每个按钮都写一遍 try/finally。
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _output = '执行中…';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _output = '未捕获异常：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// spider 返回的 json 可能极长，整段塞进界面会撑爆布局，截断到前 1200 字。
  String _preview(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return '(spider 返回空字符串)';
    if (text.length <= 1200) return text;
    return '${text.substring(0, 1200)}\n…（共 ${text.length} 字符，已截断）';
  }

  // --------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    return Scaffold(
      backgroundColor: tvTheme.backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(_pagePadding.ts(context)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(tvTheme),
              SizedBox(height: 20.ts(context)),
              Expanded(child: _buildBody(tvTheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(TvThemeData tvTheme) {
    return Row(
      children: [
        Text(
          'TVBox 宿主诊断',
          style: AppTextStyles.t20.copyWith(
            fontWeight: FontWeight.w600,
            color: tvTheme.primaryTextColor,
          ),
        ),
        SizedBox(width: 16.ts(context)),
        TvButton(
          title: '重新检测',
          size: TvButtonSize.small,
          isSecondary: true,
          onTap: _busy ? null : _runDiagnostics,
        ),
        const Spacer(),
        TvButton(
          title: '返回',
          size: TvButtonSize.small,
          isSecondary: true,
          onTap: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _buildBody(TvThemeData tvTheme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _card(tvTheme, '宿主环境', _buildEnvironment()),
          SizedBox(height: 16.ts(context)),
          _card(tvTheme, '云端配置', _buildCloudSection()),
          SizedBox(height: 16.ts(context)),
          _card(tvTheme, 'spider jar', _buildJarSection()),
          if (_inspection != null) ...[
            SizedBox(height: 16.ts(context)),
            _card(tvTheme, 'jar 内容', _buildInspection(tvTheme, _inspection!)),
          ],
          SizedBox(height: 16.ts(context)),
          _card(tvTheme, '输出', _buildOutput(tvTheme)),
        ],
      ),
    );
  }

  Widget _card(TvThemeData tvTheme, String title, Widget child) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16.ts(context)),
      decoration: BoxDecoration(
        color: tvTheme.backgroundColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16.ts(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTextStyles.t16.copyWith(
              fontWeight: FontWeight.w600,
              color: tvTheme.focusColor,
            ),
          ),
          SizedBox(height: 10.ts(context)),
          child,
        ],
      ),
    );
  }

  Widget _line(TvThemeData tvTheme, String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4.ts(context)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150.ts(context),
            child: Text(
              label,
              style: AppTextStyles.t14.copyWith(color: tvTheme.secondaryTextColor),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.t14.copyWith(color: tvTheme.primaryTextColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnvironment() {
    final tvTheme = context.tvTheme;
    final diag = _diagnostics;
    if (diag == null) {
      return Text(
        '检测中…',
        style: AppTextStyles.t14.copyWith(color: tvTheme.secondaryTextColor),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(tvTheme, 'Android', 'API ${diag.androidSdk}（${diag.androidRelease ?? '-'}）'),
        _line(tvTheme, 'ABI', diag.abis.isEmpty ? '-' : diag.abis.join(', ')),
        _line(
          tvTheme,
          '宿主契约类',
          diag.hostClassesMissing.isEmpty
              ? '完整（Spider / Net / Json 等契约类已就位）'
              : '缺失 ${diag.hostClassesMissing.join(', ')}',
        ),
        _line(
          tvTheme,
          '运行时实现类',
          diag.runtimeClassesMissing.isEmpty
              ? '完整（OkHttp / OkDns / Auth / logger 等已编入 APK）'
              : '缺失 ${diag.runtimeClassesMissing.length} 个：'
                  '${diag.runtimeClassesMissing.join(', ')}',
        ),
        if (diag.optionalClassesMissing.isNotEmpty)
          _line(
            tvTheme,
            '可选能力',
            '未启用 ${diag.optionalClassesMissing.length} 个：'
                '${diag.optionalClassesMissing.join(', ')}',
          ),
        _line(
          tvTheme,
          '已缓存 jar',
          diag.cachedJars.isEmpty
              ? '无'
              : diag.cachedJars
                  .map((jar) => '${jar.name} (${(jar.bytes / 1024).toStringAsFixed(0)} KB'
                      '${jar.readOnly ? '，只读' : '，可写!'})')
                  .join('\n'),
        ),
      ],
    );
  }

  Widget _buildCloudSection() {
    final tvTheme = context.tvTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _cloudHint,
          style: AppTextStyles.t14.copyWith(
            color: tvTheme.primaryTextColor,
            height: 1.5,
          ),
        ),
        SizedBox(height: 10.ts(context)),
        Wrap(
          spacing: 12.ts(context),
          runSpacing: 12.ts(context),
          children: [
            TvButton(
              title: '重新读取',
              size: TvButtonSize.small,
              isSecondary: true,
              onTap: _busy ? null : _loadCloudConfig,
            ),
            TvButton(
              title: '从云端选源',
              size: TvButtonSize.small,
              onTap: _busy ? null : _pickCloudSource,
            ),
            TvButton(
              title: '从云端选站点',
              size: TvButtonSize.small,
              isSecondary: true,
              onTap: _busy ? null : _pickCloudSite,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildJarSection() {
    final tvTheme = context.tvTheme;
    final inspection = _inspection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(tvTheme, '地址', _jarUrl.isEmpty ? '未填写' : _jarUrl),
        _line(tvTheme, 'ext', _ext.isEmpty ? '未填写' : _ext),
        _line(tvTheme, '爬虫类', _selectedApi ?? '未选择'),
        SizedBox(height: 10.ts(context)),
        Wrap(
          spacing: 12.ts(context),
          runSpacing: 12.ts(context),
          children: [
            TvButton(
              title: '填写 jar 地址',
              size: TvButtonSize.small,
              onTap: _busy ? null : _editJarUrl,
            ),
            TvButton(
              title: '填写 ext',
              size: TvButtonSize.small,
              isSecondary: true,
              onTap: _busy ? null : _editExt,
            ),
            TvButton(
              title: '检查 jar',
              size: TvButtonSize.small,
              onTap: _busy ? null : _inspectJar,
            ),
            TvButton(
              title: '选择爬虫类',
              size: TvButtonSize.small,
              isSecondary: true,
              onTap: (_busy || inspection == null || inspection.spiders.isEmpty)
                  ? null
                  : () => _pickSpider(inspection.spiders),
            ),
            TvButton(
              title: '加载并调 homeContent',
              size: TvButtonSize.small,
              onTap: _busy ? null : _prepareAndCall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInspection(TvThemeData tvTheme, VodJarInspection inspection) {
    if (!inspection.ok) {
      return Text(
        inspection.failure!.summary,
        style: AppTextStyles.t14.copyWith(color: Colors.redAccent),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(tvTheme, '大小', '${(inspection.bytes / 1024).toStringAsFixed(0)} KB'),
        _line(tvTheme, '只读', inspection.readOnly ? '是（满足 Android 14 要求）' : '否（会加载失败）'),
        _line(tvTheme, 'dex 数量', '${inspection.dexCount}'),
        _line(
          tvTheme,
          '自带 Spider 基类',
          inspection.bundlesBaseClass ? '是（自包含 jar）' : '否（依赖宿主，正常）',
        ),
        _line(
          tvTheme,
          '爬虫类',
          inspection.spiders.isEmpty ? '无' : inspection.spiders.join(', '),
        ),
        if (_preparation != null && _preparation!.ok)
          _line(
            tvTheme,
            '实例化',
            '${_preparation!.className} 成功，init: ${_preparation!.initModes.join(' + ')}',
          ),
        if (_callResult != null && _callResult!.ok)
          _line(tvTheme, '调用耗时', '${_callResult!.elapsedMs} ms'),
      ],
    );
  }

  Widget _buildOutput(TvThemeData tvTheme) {
    return Text(
      _output.isEmpty ? '（暂无）' : _output,
      style: AppTextStyles.t14.copyWith(
        color: tvTheme.primaryTextColor,
        height: 1.5,
      ),
    );
  }
}
