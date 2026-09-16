/// 「指定查词用的具体输入法」选择器。
///
/// 三种形态，由原生侧返回的列表决定，**调用方不需要分平台写 if**：
///
/// - **可选**（Windows / macOS）：列出系统里已启用的输入法，用户点一个就切那个。
/// - **只读**（Android）：同样列出来，但每条都 `selectable == false`——Android 自 9 起
///   应用切不了输入法（见 `LookupImeCatalog` 的类注释）。这时列表只是告诉用户
///   「你装的输入法里哪个支持你选的语言」，另给一个「打开系统输入法选择器」的动作。
/// - **不支持**（iOS）：列表为空，直接说明这一端只能按语言表达。
library;

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';
import 'package:fushi/src/lookup/lookup_ime_language.dart';
import 'package:fushi/src/lookup/lookup_ime_source.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 用户在选择器里做出的选择。[source] 为 null = 回到「跟随语言」。
typedef LookupImeSourceSelected = void Function(LookupImeSource? source);

/// 弹出选择器。[sources] 由调用方先 `await LookupImeChannel.listSources()` 取好——
/// 对话框的 build 里不做 method channel 往返。
///
/// [currentId] 是当前已指定的 id（没指定传 null）；[language] 用来把「支持这个语言」
/// 的输入法排在前面并打标，它是用户真正在找的东西。
Future<void> showLookupImeSourcePicker({
  required BuildContext context,
  required List<LookupImeSource> sources,
  required String? currentId,
  required String? language,
  required LookupImeSourceSelected onSelected,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final List<LookupImeSource> ordered = sortLookupImeSources(sources, language);
  final bool anySelectable = ordered.any(
    (LookupImeSource source) => source.selectable,
  );

  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.78,
      child: FushiModalSheetFrame(
        leadingIcon: Icons.keyboard_outlined,
        bodyPadding: EdgeInsets.all(tokens.spacing.card),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.settings_lookup_ime_source_title,
              style: tokens.type.listTitle.copyWith(fontWeight: FontWeight.w600),
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              ordered.isEmpty
                  ? t.settings_lookup_ime_source_unsupported
                  : anySelectable
                  ? t.settings_lookup_ime_source_description
                  : t.settings_lookup_ime_source_readonly,
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.gap),
            if (anySelectable)
              FushiListItem(
                title: Text(t.settings_lookup_ime_source_auto),
                selected: currentId == null,
                trailing: currentId == null ? const Icon(Icons.check) : null,
                onTap: () {
                  onSelected(null);
                  Navigator.pop(dialogContext);
                },
              ),
            for (final LookupImeSource source in ordered)
              FushiListItem(
                title: Text(source.name),
                // 副标题直接回答用户唯一关心的问题：这个输入法能不能打我选的语言。
                subtitle: language == null
                    ? null
                    : Text(
                        lookupImeSourceSupportsLanguage(source, language)
                            ? t.settings_lookup_ime_source_supports
                            : t.settings_lookup_ime_source_unsupported_language,
                      ),
                selected: source.id == currentId,
                trailing: source.id == currentId
                    ? const Icon(Icons.check)
                    : null,
                // 不可选的条目不给 onTap：Android 上点了本来也切不动，给个能点的
                // 假象比不给更糟。
                onTap: source.selectable
                    ? () {
                        onSelected(source);
                        Navigator.pop(dialogContext);
                      }
                    : null,
              ),
          ],
        ),
        footer: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            // 只在「列得出来但选不了」时给这个出口（Android）：它会拉起系统弹窗，
            // 用户选完是**全局生效**的，所以必须由用户显式点，不能自动触发。
            if (ordered.isNotEmpty && !anySelectable)
              adaptiveDialogAction(
                context: dialogContext,
                child: Text(t.settings_lookup_ime_source_open_system_picker),
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await LookupImeChannel.showSystemPicker();
                },
              ),
            adaptiveDialogAction(
              context: dialogContext,
              child: Text(t.dialog_cancel),
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 这个输入源声明的语言里有没有能打 [language] 的。
bool lookupImeSourceSupportsLanguage(LookupImeSource source, String language) {
  return source.languages.any(
    (String candidate) => lookupImeLanguageMatches(language, candidate),
  );
}

/// 支持目标语言的排前面，其余保持原顺序。
///
/// 只做稳定分组、**不做字母排序**：原顺序是系统给的（用户在系统设置里的排列），
/// 重排会让用户在这个列表里找不到他熟悉的次序。
List<LookupImeSource> sortLookupImeSources(
  List<LookupImeSource> sources,
  String? language,
) {
  if (language == null || language.isEmpty) {
    return List<LookupImeSource>.unmodifiable(sources);
  }
  final List<LookupImeSource> matching = <LookupImeSource>[];
  final List<LookupImeSource> rest = <LookupImeSource>[];
  for (final LookupImeSource source in sources) {
    if (lookupImeSourceSupportsLanguage(source, language)) {
      matching.add(source);
    } else {
      rest.add(source);
    }
  }
  return List<LookupImeSource>.unmodifiable(<LookupImeSource>[
    ...matching,
    ...rest,
  ]);
}
