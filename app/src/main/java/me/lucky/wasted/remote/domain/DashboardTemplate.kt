package me.lucky.wasted.remote.domain

/** Injects connection values into the bundled single-file dashboard template. */
object DashboardTemplate {
    private val PLACEHOLDER =
        Regex("__WASTED_(SUPABASE_URL|PUBLISHABLE_KEY|VERSION)__")

    fun render(
        template: String,
        projectUrl: String,
        publishableKey: String,
        version: String,
    ): String {
        val values = mapOf(
            "SUPABASE_URL" to projectUrl.trim(),
            "PUBLISHABLE_KEY" to publishableKey.trim(),
            "VERSION" to version.trim(),
        )
        return PLACEHOLDER.replace(template) { match ->
            escapeForScript(values.getValue(match.groupValues[1]))
        }
    }

    internal fun escapeForScript(value: String): String = buildString(value.length) {
        for (char in value) {
            when (char) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\'' -> append("\\'")
                '<' -> append("\\u003c")
                '>' -> append("\\u003e")
                '&' -> append("\\u0026")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\u2028' -> append("\\u2028")
                '\u2029' -> append("\\u2029")
                else -> append(char)
            }
        }
    }
}
