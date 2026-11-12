package androidx.preference

import android.content.Context
import android.content.SharedPreferences

/**
 * 最小替代品，只为满足 catvod-api.jar 的 `com.github.catvod.utils.Prefers`。
 *
 * 那个类唯一的 androidx 依赖就是
 * `PreferenceManager.getDefaultSharedPreferences(Context)` 这一个静态方法。
 * 引入官方 `androidx.preference:preference` 会连带 appcompat / recyclerview，
 * 对已经压到 38 MB 的电视包不值得。
 *
 * 语义与官方一致：文件名 `<包名>_preferences`、MODE_PRIVATE。
 * 换成真实依赖的做法：删掉本文件，在 app/build.gradle.kts 里加
 * `implementation("androidx.preference:preference:1.2.1")` 即可，其余代码不用改。
 */
object PreferenceManager {

    @JvmStatic
    fun getDefaultSharedPreferences(context: Context): SharedPreferences =
        context.getSharedPreferences(
            "${context.packageName}_preferences",
            Context.MODE_PRIVATE,
        )
}
