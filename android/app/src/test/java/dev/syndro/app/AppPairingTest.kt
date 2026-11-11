package dev.syndro.app

import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class AppPairingTest {
    private val target = Target("http://192.168.1.20:47821", "ABCD2345")

    private fun info(): JSONObject = JSONObject()
        .put("deviceName", "Family phone")
        .put("serverId", "other-app")
        .put("token", target.token)
        .put("files", JSONArray())

    @Test
    fun fullShareLinksNormalizeCodesWithoutChangingTheDestination() {
        assertEquals(target, parseTarget(" ${target.base}/s/abcd2345 "))
        assertEquals(target, parseTarget("${target.base}/s/ABCD%202345/"))
        assertEquals(Target("https://family-pc:443", "ABCD2345"),
            parseTarget("https://family-pc:443/s/ABCD2345"))
    }

    @Test
    fun nativeScopedIpv6LinksRemainUsable() {
        val base = "http://[fe80::20%25wlan0]:47821"
        assertEquals(Target(base, "ABCD2345"), parseTarget("$base/s/abcd2345"))
    }

    @Test
    fun unrelatedAndAmbiguousLinksCannotSelectAReceiver() {
        for (link in listOf(
            "${target.base}/ABCD2345",
            "${target.base}/other/s/ABCD2345",
            "${target.base}/s/ABCD2345/extra",
            "${target.base}/s/ABCD2345?t=OTHER234",
            "${target.base}/s/ABCD2345#other",
            "http://user@192.168.1.20:47821/s/ABCD2345",
            "http://192.168.1.20:0/s/ABCD2345",
            "http://192.168.1.20:65536/s/ABCD2345",
            "${target.base}/s/ABCDI234",
            "192.168.1.20:47821/s/ABCD2345",
        )) {
            assertNull(link, parseTarget(link))
        }
    }

    @Test
    fun pairingReturnsTheVerifiedNameAndExactTarget() {
        val receiver = receiverFromInfo(target, info().put("deviceName", " Family phone "), "this-app")
        assertEquals("Family phone", receiver.name)
        assertEquals(target, receiver.target)
    }

    @Test
    fun mismatchedPairCodesAreRejected() {
        assertThrows(IOException::class.java) {
            receiverFromInfo(target, info().put("token", "WXYZ6789"), "this-app")
        }
    }

    @Test
    fun invalidReceiverMetadataIsRejected() {
        for (invalid in listOf(
            info().put("deviceName", " "),
            info().put("deviceName", 42),
            info().put("files", "not a file list"),
            info().apply { remove("files") },
        )) {
            assertThrows(IOException::class.java) { receiverFromInfo(target, invalid, "this-app") }
        }
    }

    @Test
    fun ownServerIdentityIsRejectedEvenUnderADifferentAddress() {
        assertThrows(IOException::class.java) {
            receiverFromInfo(target, info().put("serverId", "this-app"), "this-app")
        }
    }

    @Test
    fun olderReceiverInfoWithoutAnIdentityRemainsCompatible() {
        val older = info().apply { remove("serverId") }
        assertEquals("Family phone", receiverFromInfo(target, older, "this-app").name)
    }

    @Test
    fun completedTransfersRequireTheExactFileIdAndSize() {
        requireConfirmedFile(JSONObject().put("file", JSONObject().put("id", "a".repeat(24)).put("size", 5)),
            "a".repeat(24), 5)
    }

    @Test
    fun httpSuccessWithoutExactCompletionCannotMeanSent() {
        val id = "a".repeat(24)
        for (reply in listOf(
            JSONObject(),
            JSONObject().put("file", JSONObject().put("id", "b".repeat(24)).put("size", 5)),
            JSONObject().put("file", JSONObject().put("id", id).put("size", 4)),
            JSONObject().put("file", JSONObject().put("id", id).put("size", "5")),
            JSONObject().put("file", JSONObject().put("id", id).put("size", 5.5)),
        )) {
            assertThrows(IOException::class.java) { requireConfirmedFile(reply, id, 5) }
        }
    }
}
