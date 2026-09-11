package com.shotclubhouse.sayso.service

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import com.shotclubhouse.sayso.core.OutputMethod

/**
 * Splices [insert] into [existing] at the selection, mimicking what typing would do.
 *
 * A missing selection (either index below zero) appends instead. Spaces are added on
 * either side when the neighbouring character is not already whitespace, so dictating
 * twice in a row, or into the middle of a sentence, does not run words together.
 */
fun spliceAtSelection(existing: String, insert: String, selectionStart: Int, selectionEnd: Int): String {
    val hasSelection = selectionStart >= 0 && selectionEnd >= 0
    val start = if (hasSelection) minOf(selectionStart, selectionEnd).coerceIn(0, existing.length) else existing.length
    val end = if (hasSelection) maxOf(selectionStart, selectionEnd).coerceIn(0, existing.length) else existing.length
    val prefix = existing.substring(0, start)
    val suffix = existing.substring(end)
    val before = if (prefix.isNotEmpty() && !prefix.last().isWhitespace()) " " else ""
    val after = if (suffix.isNotEmpty() && !suffix.first().isWhitespace()) " " else ""
    return prefix + before + insert + after + suffix
}

/**
 * Puts dictated text where the user is typing.
 *
 * The clipboard is always filled first, so even a total failure leaves the text one
 * long-press away. Then the most promising editable node in the active windows is
 * asked to take the text, preferring a terminal's own paste action, then a direct
 * text edit, then the generic paste action.
 */
class TextInjector(private val service: AccessibilityService) {

    /** Returns how the text reached the user. */
    fun inject(text: String): OutputMethod {
        val copied = copyToClipboard(text)
        val inserted = candidates().sortedByDescending(::score).any { insertInto(it, text) }
        return when {
            inserted -> OutputMethod.INSERTED
            copied -> OutputMethod.CLIPBOARD
            else -> OutputMethod.NONE
        }
    }

    private fun copyToClipboard(text: String): Boolean {
        val clipboard = service.getSystemService(ClipboardManager::class.java) ?: return false
        return runCatching { clipboard.setPrimaryClip(ClipData.newPlainText(CLIP_LABEL, text)) }
            .onFailure { Log.d(TAG, "Clipboard write refused", it) }
            .isSuccess
    }

    /**
     * Focused nodes first, then a bounded walk of the active windows. The budget is
     * shared across roots because every node access is a binder round trip.
     */
    private fun candidates(): List<AccessibilityNodeInfo> {
        val roots = buildList {
            service.rootInActiveWindow?.let(::add)
            service.windows
                .filter { it.isActive || it.isFocused }
                .forEach { window -> window.root?.let(::add) }
        }

        val found = LinkedHashSet<AccessibilityNodeInfo>()
        var budget = MAX_NODES
        for (root in roots) {
            root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let(found::add)
            root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)?.let(found::add)

            val stack = ArrayDeque<AccessibilityNodeInfo>()
            stack.addLast(root)
            while (stack.isNotEmpty() && budget > 0) {
                val node = stack.removeLast()
                budget--
                if (isTextTarget(node)) found.add(node)
                for (i in node.childCount - 1 downTo 0) {
                    node.getChild(i)?.let(stack::addLast)
                }
            }
        }
        return found.filter { score(it) > 0 }
    }

    private fun isTextTarget(node: AccessibilityNodeInfo): Boolean =
        node.isEditable ||
            node.isFocused ||
            node.className?.contains(EDIT_TEXT_CLASS) == true ||
            acceptsPaste(node) ||
            customPasteAction(node) != null

    private fun score(node: AccessibilityNodeInfo): Int {
        val className = node.className?.toString().orEmpty()
        var score = 0
        if (acceptsPaste(node) || customPasteAction(node) != null) score += 100
        if (className.contains(TERMINAL_CLASS)) score += 80
        if (node.isEditable) score += 60
        if (node.isFocused) score += 40
        if (className.contains(EDIT_TEXT_CLASS)) score += 20
        return score
    }

    /** The standard paste, identified by its action id rather than by what it is called. */
    private fun acceptsPaste(node: AccessibilityNodeInfo): Boolean =
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_PASTE }

    /**
     * Terminal emulators expose paste only as a custom action carrying a "paste" label, so the
     * label is matched there. An ordinary text field is edited directly instead: matching by
     * label on one would sooner or later fire whatever unrelated action happens to be named
     * that, in whatever language the app is in.
     */
    private fun customPasteAction(node: AccessibilityNodeInfo): AccessibilityNodeInfo.AccessibilityAction? {
        val terminal = node.className?.contains(TERMINAL_CLASS) == true
        if (node.isEditable && !terminal) return null
        return node.actionList.firstOrNull { it.label?.contains(PASTE_LABEL, ignoreCase = true) == true }
    }

    private fun insertInto(node: AccessibilityNodeInfo, text: String): Boolean {
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)

        customPasteAction(node)?.let { action ->
            return node.performAction(action.id).also { Log.d(TAG, "Custom paste returned $it") }
        }

        if (node.isEditable) {
            val merged = spliceAtSelection(
                existing = node.text?.toString().orEmpty(),
                insert = text,
                selectionStart = node.textSelectionStart,
                selectionEnd = node.textSelectionEnd,
            )
            val arguments = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, merged)
            }
            return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
                .also { Log.d(TAG, "Set text returned $it") }
        }

        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            .also { Log.d(TAG, "Paste returned $it") }
    }

    private companion object {
        const val TAG = "SaysoInjector"
        const val CLIP_LABEL = "Sayso"
        const val PASTE_LABEL = "paste"
        const val TERMINAL_CLASS = "TerminalView"
        const val EDIT_TEXT_CLASS = "EditText"

        /** Bounds a walk to roughly 200 ms of binder traffic on a busy screen. */
        const val MAX_NODES = 400
    }
}
