package com.stickdeath.studio.connect

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The session encrypted with a non-exportable AES-256-GCM key in the Android Keystore, stored in
 * app-private no-backup storage (the manifest also disables backup). Uninstall deletes both the key
 * and the file, so a reinstall never inherits an earlier session. Unreadable records are discarded,
 * which only means signing in again: no project data lives here. */
class KeystoreSessionVault(context: Context) : SessionVault {
    private val file = File(context.noBackupFilesDir, "account-session.bin")

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return generator.generateKey()
    }

    @Synchronized override fun read(): String? {
        if (!file.isFile) return null
        return runCatching {
            val raw = Base64.decode(file.readText(), Base64.NO_WRAP)
            require(raw.size > 12)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
            String(cipher.doFinal(raw.copyOfRange(12, raw.size)), Charsets.UTF_8)
        }.getOrNull()
    }

    @Synchronized override fun write(value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val staging = File(file.parentFile, file.name + ".tmp")
        staging.writeText(Base64.encodeToString(sealed, Base64.NO_WRAP))
        if (!staging.renameTo(file)) { staging.delete(); error("The session could not be saved.") }
    }

    @Synchronized override fun clear() { file.delete() }

    private companion object {
        const val ALIAS = "sdi-account-session"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
