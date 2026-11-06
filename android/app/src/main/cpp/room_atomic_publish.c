#include <jni.h>
#include <stddef.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* renameat2 is a Linux kernel operation available before Android API26. The libc
 * named wrapper is API30; use the NDK's architecture-provided syscall number so
 * the app keeps its API26 floor. There is deliberately no replacing fallback.
 * Flag1 is RENAME_NOREPLACE from the Linux UAPI, not a Java move option. */
JNIEXPORT jint JNICALL
Java_com_stickdeath_studio_RoomAtomicPublish_renameNoReplace(
        JNIEnv *env, jclass type, jstring source, jstring destination) {
    (void) type;
    if (source == NULL || destination == NULL) return EINVAL;
    const char *from = (*env)->GetStringUTFChars(env, source, NULL);
    if (from == NULL) return ENOMEM; /* Pending JVM exception is preserved. */
    const char *to = (*env)->GetStringUTFChars(env, destination, NULL);
    if (to == NULL) {
        (*env)->ReleaseStringUTFChars(env, source, from);
        return ENOMEM;
    }
    int result;
#if defined(__NR_renameat2)
    result = syscall(__NR_renameat2, AT_FDCWD, from, AT_FDCWD, to, 1U) == 0 ? 0 : errno;
#else
    result = ENOSYS;
#endif
    (*env)->ReleaseStringUTFChars(env, destination, to);
    (*env)->ReleaseStringUTFChars(env, source, from);
    return result;
}
