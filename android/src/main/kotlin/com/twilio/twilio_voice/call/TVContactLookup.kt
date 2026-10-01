package com.twilio.twilio_voice.call

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Finds the phone contact saved with an incoming E.164 number.
 *
 * Numbers saved with a country code ("+", "00" or "011") must match exactly. Numbers saved without one match if the
 * incoming number has one of the configured calling codes, with or without the national trunk prefix
 * (e.g. "0171 2345678" for "+49 171 2345678").
 * Keep in sync with ContactNameLookup.swift.
 */
object TVContactLookup {
    private const val TAG = "TVContactLookup"

    fun hasAccess(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Name of the phone contact saved with [number], or null if there is none or contacts access is not granted.
     * Candidates come from PhoneLookup, which matches loosely on the last digits, and are confirmed with [matches].
     */
    fun findName(context: Context, number: String, callingCodes: Collection<String>): String? {
        if (!number.startsWith("+") || !hasAccess(context)) {
            return null
        }
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME, ContactsContract.PhoneLookup.NUMBER)
        return try {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val name = cursor.getString(0)?.trim()
                    val stored = cursor.getString(1) ?: continue
                    if (!name.isNullOrEmpty() && matches(stored, number, callingCodes)) {
                        return name
                    }
                }
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "findName: contact lookup failed", e)
            null
        }
    }

    fun matches(stored: String, incoming: String, callingCodes: Collection<String>): Boolean {
        val incomingDigits = digits(incoming)
        // "+49 (0)171 ..." is a common way to write the trunk prefix next to the country code
        val trimmed = stored.replace("(0)", "").trim()
        val storedDigits = digits(trimmed)
        if (incomingDigits.isEmpty() || storedDigits.isEmpty()) {
            return false
        }

        if (trimmed.startsWith("+")) {
            return storedDigits == incomingDigits
        }
        if (storedDigits.startsWith("00") && storedDigits.substring(2) == incomingDigits) {
            return true
        }
        if (storedDigits.startsWith("011") && storedDigits.substring(3) == incomingDigits) {
            return true
        }
        return callingCodes.any { code ->
            if (code.isEmpty() || !incomingDigits.startsWith(code)) {
                return@any false
            }
            val national = incomingDigits.substring(code.length)
            national.isNotEmpty() && (storedDigits == national || storedDigits == trunkPrefix(code) + national)
        }
    }

    private fun trunkPrefix(callingCode: String): String {
        return when (callingCode) {
            "1" -> "1"
            "7", "370", "375" -> "8"
            "36" -> "06"
            else -> "0"
        }
    }

    private fun digits(value: String): String {
        return value.filter { it in '0'..'9' }
    }
}
