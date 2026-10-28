// libyara's "hash" module needs a digest library. On macOS that's CommonCrypto (Package.swift turns
// on HASH_MODULE there); other platforms, used only for tests, build without the module.
#if defined(HASH_MODULE)
#include "libyara/modules/hash/hash.c"
#endif
