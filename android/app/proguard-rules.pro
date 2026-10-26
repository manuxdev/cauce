# The Rust core reaches the certificate verifier over JNI only, so shrinking must leave it whole.
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
