package app.fushi.reader;

import android.content.Context;
import android.os.Build;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.InputMethodSubtype;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;

/**
 * 列出系统里已启用的输入法，以及它们各自启用了哪些语言的子类型。
 *
 * <p><b>这里只有「读」，没有「切」，而且这是平台上限而不是实现偷懒。</b>Android 自 9
 * (P) 起，{@code InputMethodManager.setInputMethod(token, id)} 及
 * {@code switchToNextInputMethod} 的方法体改成走
 * {@code InputMethodPrivilegedOperationsRegistry}，而那是个**进程内的 WeakHashMap**，
 * 只有 {@code InputMethodService.attachToken()} 会往里放。普通应用进程里取不到实例，
 * 直接返回 no-op —— **即便反射拿到真 token 也照样什么都不会发生**。写
 * {@code Settings.Secure.DEFAULT_INPUT_METHOD} 需要 {@code WRITE_SECURE_SETTINGS}，
 * 那是 signature|privileged|development 级，普通应用申请必被拒。
 *
 * <p>所以应用侧能做的只有三件事，本类负责第一件：
 * <ol>
 *   <li>**枚举**（本类）：告诉用户「你装的输入法里哪个支持你选的语言」；</li>
 *   <li>{@code EditorInfo.hintLocales} 提示（{@link LookupImeHint}）——认不认由输入法决定；</li>
 *   <li>拉起系统的输入法选择器（{@link #showPicker}），用户自己动手。</li>
 * </ol>
 *
 * <p>枚举依赖 {@code AndroidManifest.xml} 里的
 * {@code <queries><intent><action android:name="android.view.InputMethod"/>}：Android 11+
 * 没有这条声明时，{@code getEnabledInputMethodList()} 只会返回**当前选中的那一个**
 * （IMMS 的 {@code canCallerAccessInputMethod} 把其余项按包可见性剔掉）。
 *
 * <p><b>但有了它也不等于「看得到全部」</b>（2026-09-16 模拟器实测）：AppsFilter 做
 * {@code <queries><intent>} 匹配时**跳过非导出组件**，所以把 IME service 写成
 * {@code android:exported="false"} 的输入法（targetSdk 31+ 之后合法且在变多）**看不到**，
 * 它只在恰好是当前选中项时才被无条件放行。Gboard 这类大厂输入法带 intent-filter、
 * 默认导出，不受影响。UI 上别把这份清单说成「系统里所有输入法」。
 *
 * <p>另：{@code languages} 为空是**常态不是异常**——语音输入法被 mode 过滤掉，
 * 而有些键盘的基础子类型 locale 与 languageTag 全空（靠 additional subtypes，用户没进
 * 它的设置页配过语言）。消费端必须能优雅渲染「这条没有语言信息」。
 */
public final class LookupImeCatalog {

    private LookupImeCatalog() {}

    /**
     * 已启用的输入法列表，形状与桌面端的 {@code listInputMethods} 一致：
     * {@code {id, name, languages, selectable}}。
     *
     * <p>{@code selectable} 恒 {@code false} —— 见类注释，Android 上我们切不了。设置页
     * 据此把列表渲染成「只读清单」而不是可选项，免得用户点了没反应。
     */
    public static List<Map<String, Object>> list(Context context) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (context == null) {
            return out;
        }
        InputMethodManager imm =
                (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm == null) {
            return out;
        }
        List<InputMethodInfo> infos;
        try {
            infos = imm.getEnabledInputMethodList();
        } catch (RuntimeException error) {
            // 定制 ROM 上见过抛的；枚举不出来只是设置页少一块信息，不该把设置页带崩。
            return out;
        }
        if (infos == null) {
            return out;
        }
        for (InputMethodInfo info : infos) {
            if (info == null) {
                continue;
            }
            Map<String, Object> entry = new HashMap<>();
            entry.put("id", info.getId());
            CharSequence label = info.loadLabel(context.getPackageManager());
            entry.put("name", label == null ? info.getId() : label.toString());
            entry.put("languages", new ArrayList<>(languagesOf(imm, info)));
            entry.put("selectable", Boolean.FALSE);
            out.add(entry);
        }
        return out;
    }

    /**
     * 这个输入法**已启用**的子类型覆盖了哪些语言。
     *
     * <p>取的是 {@code getEnabledInputMethodSubtypeList(info, true)} 而不是
     * {@code info.getSubtypeAt(i)} 全集：用户真正能打出来的只有已启用的那些，把没启用的
     * 日语子类型也报成「支持日语」会让设置页说谎。
     *
     * <p>语言优先 {@code getLanguageTag()}（BCP-47，API 24+），它**未声明时返回空串**，
     * 那时才回退到已废弃的 {@code getLocale()}（`ja_JP` 下划线写法，交给 Dart 侧
     * {@code lookupImeLanguageMatches} 归一化）。只收键盘型子类型——语音输入
     * （{@code mode == "voice"}）不是这个功能关心的东西。
     */
    private static Set<String> languagesOf(InputMethodManager imm, InputMethodInfo info) {
        Set<String> languages = new LinkedHashSet<>();
        List<InputMethodSubtype> subtypes;
        try {
            subtypes = imm.getEnabledInputMethodSubtypeList(info, true);
        } catch (RuntimeException error) {
            return languages;
        }
        if (subtypes == null) {
            return languages;
        }
        for (InputMethodSubtype subtype : subtypes) {
            if (subtype == null || !"keyboard".equals(subtype.getMode())) {
                continue;
            }
            String tag = "";
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                tag = subtype.getLanguageTag();
            }
            if (tag == null || tag.isEmpty()) {
                tag = legacyLocaleOf(subtype);
            }
            if (tag != null && !tag.isEmpty()) {
                languages.add(tag);
            }
        }
        return languages;
    }

    @SuppressWarnings("deprecation")
    private static String legacyLocaleOf(InputMethodSubtype subtype) {
        return subtype.getLocale();
    }

    /**
     * 拉起系统的「选择输入法」弹窗。
     *
     * <p>这是普通应用**唯一**合法的切输入法入口。服务端
     * {@code canShowInputMethodPickerLocked} 放行「当前 focused window 的 client」——
     * 判的是 focused window 而不是有没有 EditText 拿到输入焦点，所以前台 Activity 直接
     * 调即可。不满足时系统只打一条 warning 静默忽略，**不会抛**，所以这里返回的 true
     * 只代表「调用发出去了」，不代表弹窗真的出现了。
     *
     * <p>注意它**全局生效**：用户在这里选完，退出本 app 之后系统输入法仍然是新选的那个。
     * 所以只能做成用户显式点击的动作，绝不能塞进查词框聚焦这类自动路径。
     */
    public static boolean showPicker(Context context) {
        if (context == null) {
            return false;
        }
        InputMethodManager imm =
                (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm == null) {
            return false;
        }
        try {
            imm.showInputMethodPicker();
            return true;
        } catch (RuntimeException error) {
            return false;
        }
    }
}
