package dev.syndro.app

import java.security.SecureRandom

/**
 * The same pairing-code alphabet as LinkPhone: A-Z without I and O, plus 2-9.
 * Eight symbols is 40 bits; the URL is still the capability, so the code is
 * only as strong as the transport that carries it.
 */
object Code {
    const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    const val LENGTH = 8

    private val VALID = Regex("^[A-HJ-NP-Z2-9]{$LENGTH}$")
    private val random = SecureRandom()

    fun generate(): String = buildString(LENGTH) {
        repeat(LENGTH) { append(ALPHABET[random.nextInt(ALPHABET.length)]) }
    }

    fun group(code: String): String =
        if (code.length == LENGTH) "${code.substring(0, 4)} ${code.substring(4)}" else code

    fun isValid(code: String): Boolean = VALID.matches(code)

    /** Accepts a code typed in lowercase or grouped (`abcd 2345`). */
    fun normalize(input: String): String? {
        val cleaned = input.filter { it.isLetterOrDigit() }.uppercase()
        return cleaned.takeIf { VALID.matches(it) }
    }
}
