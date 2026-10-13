package com.stickdeath.studio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** The offline contract names only RPCs that the backend SQL candidates actually define. */
class BackendContractTest {
    private fun sqlDirectory(): File {
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, "backend/sql")
            if (File(candidate, "README.md").isFile) return candidate
            directory = directory.parentFile
        }
        fail("backend/sql was not found above ${File("").absolutePath}; run the JVM tests from the repository checkout."); error("unreachable")
    }

    @Test fun everyContractRpcExistsInItsCandidateFile() {
        val sql = sqlDirectory()
        BackendContract.rpcs.forEach { rpc ->
            val file = File(sql, rpc.sqlFile)
            assertTrue("${rpc.sqlFile} is missing", file.isFile)
            val text = file.readText()
            val defined = Regex("""create\s+(?:or\s+replace\s+)?function\s+public\.${Regex.escape(rpc.name)}\s*\(""", RegexOption.IGNORE_CASE).containsMatchIn(text)
            assertTrue("${rpc.name} is not defined in ${rpc.sqlFile}", defined)
        }
    }

    @Test fun contractIsWellFormed() {
        assertEquals(BackendContract.rpcs.size, BackendContract.rpcs.map { it.name }.toSet().size)
        BackendContract.rpcs.forEach { assertTrue(it.name, it.name.startsWith("sdi_")); assertTrue(it.summary.isNotBlank()) }
        assertTrue(BackendContract.rpcs.none { it.access == BackendAccess.Service || it.access == BackendAccess.Admin })
        // The no-messaging contract: no chat, call or direct-message RPC is described.
        BackendContract.rpcs.forEach { rpc -> listOf("chat", "message", "call", "voice", "video_call").forEach { word -> assertTrue(rpc.name, !rpc.name.contains(word)) } }
        assertTrue(BackendContract.rpcs(BackendArea.Rooms).isNotEmpty() && BackendContract.rpcs(BackendArea.WarRoom).isNotEmpty())
    }

    @Test fun androidSessionIsHonestlyNotConfigured() {
        val state = AndroidIdentity.currentState()
        assertTrue(state is SessionState.NotConfigured)
        assertTrue(state.summary.startsWith("Not connected"))
        assertTrue(AndroidIdentity.configuredProviders.isEmpty())
        assertEquals(SessionState.SignedOut, AndroidIdentity.currentState(setOf(IdentityProvider.Google), network = true))
        assertTrue(AndroidIdentity.currentState(emptySet(), network = true) is SessionState.NotConfigured)
        assertEquals(listOf("Apple", "Google", "GitHub", "Microsoft"), IdentityProvider.entries.map { it.label })
    }
}
