pub mod api;
mod frb_generated;

/// Hands the app's Java VM and context to what needs them on Android: the platform certificate
/// verifier, without which every https request panics, and `ndk-context`, which cpal reads to
/// open the audio output. `MainActivity` calls it once, as Flutter starts.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_dev_manuxdev_cauce_MainActivity_initAndroid<'caller>(
    mut env: jni::EnvUnowned<'caller>,
    _this: jni::objects::JObject<'caller>,
    context: jni::objects::JObject<'caller>,
) {
    let _ = env.with_env(|env| -> Result<(), jni::errors::Error> {
        let vm = env.get_java_vm()?.get_raw();
        // Never released: ndk-context keeps it for the life of the process.
        let app = env.new_global_ref(&context)?.into_raw();
        // SAFETY: a live VM and a global reference to the app context, set once.
        unsafe { ndk_context::initialize_android_context(vm.cast(), app.cast()) };
        rustls_platform_verifier::android::init_with_env(env, context)
    });
}
