//! Android's AAC decoder fed straight from the ciphertext, decrypting against a [`Cdm`]'s session.
//!
//! Android hands no decrypted compressed samples back to an app, so the CENC samples go into a
//! `MediaCodec` opened with a `MediaCrypto` on the session the license went into, each one with
//! its IV and subsample layout, and what comes out is PCM. Audio decoders are not secure, so the
//! PCM is readable, and the cleartext of the compressed samples never exists outside the
//! platform's own process.
//!
//! This uses the NDK's C API, `libmediandk`, rather than the Java classes over JNI: the same
//! objects without a VM call and a local reference for every buffer.

use std::ffi::{c_char, c_void};
use std::ptr::{self, NonNull};
use std::time::Duration;

use anyhow::{Result, bail};

use crate::cenc::{self, Audio};
use crate::{Cdm, SYSTEM_ID};

#[repr(C)]
struct AMediaCodec {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AMediaCrypto {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AMediaFormat {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AMediaCodecCryptoInfo {
    _opaque: [u8; 0],
}

#[repr(C)]
#[derive(Default)]
struct BufferInfo {
    offset: i32,
    size: i32,
    presentation_us: i64,
    flags: u32,
}

/// `media_status_t`, where zero is `AMEDIA_OK`.
type Status = i32;

/// `AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM`.
const END_OF_STREAM: u32 = 4;
/// `AMEDIACODEC_INFO_TRY_AGAIN_LATER`, `_OUTPUT_FORMAT_CHANGED` and `_OUTPUT_BUFFERS_CHANGED`.
const TRY_AGAIN: isize = -1;
const FORMAT_CHANGED: isize = -2;
const BUFFERS_CHANGED: isize = -3;
/// `AMEDIACODECRYPTOINFO_MODE_AES_CTR`, the `cenc` scheme.
const AES_CTR: u32 = 1;
/// `AudioFormat.ENCODING_PCM_16BIT`, what an AAC decoder puts out unless asked otherwise.
const PCM_16BIT: i32 = 2;

#[link(name = "mediandk")]
unsafe extern "C" {
    fn AMediaCodec_createDecoderByType(mime: *const c_char) -> *mut AMediaCodec;
    fn AMediaCodec_configure(
        codec: *mut AMediaCodec,
        format: *const AMediaFormat,
        surface: *mut c_void,
        crypto: *mut AMediaCrypto,
        flags: u32,
    ) -> Status;
    fn AMediaCodec_start(codec: *mut AMediaCodec) -> Status;
    fn AMediaCodec_stop(codec: *mut AMediaCodec) -> Status;
    fn AMediaCodec_delete(codec: *mut AMediaCodec) -> Status;
    fn AMediaCodec_dequeueInputBuffer(codec: *mut AMediaCodec, timeout_us: i64) -> isize;
    fn AMediaCodec_getInputBuffer(
        codec: *mut AMediaCodec,
        index: usize,
        size: *mut usize,
    ) -> *mut u8;
    fn AMediaCodec_queueInputBuffer(
        codec: *mut AMediaCodec,
        index: usize,
        offset: libc::off_t,
        size: usize,
        time_us: u64,
        flags: u32,
    ) -> Status;
    fn AMediaCodec_queueSecureInputBuffer(
        codec: *mut AMediaCodec,
        index: usize,
        offset: libc::off_t,
        info: *mut AMediaCodecCryptoInfo,
        time_us: u64,
        flags: u32,
    ) -> Status;
    fn AMediaCodec_dequeueOutputBuffer(
        codec: *mut AMediaCodec,
        info: *mut BufferInfo,
        timeout_us: i64,
    ) -> isize;
    fn AMediaCodec_getOutputBuffer(
        codec: *mut AMediaCodec,
        index: usize,
        size: *mut usize,
    ) -> *mut u8;
    fn AMediaCodec_releaseOutputBuffer(
        codec: *mut AMediaCodec,
        index: usize,
        render: bool,
    ) -> Status;
    fn AMediaCodec_getOutputFormat(codec: *mut AMediaCodec) -> *mut AMediaFormat;

    fn AMediaFormat_new() -> *mut AMediaFormat;
    fn AMediaFormat_delete(format: *mut AMediaFormat) -> Status;
    fn AMediaFormat_setString(format: *mut AMediaFormat, name: *const c_char, value: *const c_char);
    fn AMediaFormat_setInt32(format: *mut AMediaFormat, name: *const c_char, value: i32);
    fn AMediaFormat_setBuffer(
        format: *mut AMediaFormat,
        name: *const c_char,
        data: *const c_void,
        size: usize,
    );
    fn AMediaFormat_getInt32(format: *mut AMediaFormat, name: *const c_char, out: *mut i32)
    -> bool;

    fn AMediaCrypto_new(uuid: *const u8, init: *const c_void, size: usize) -> *mut AMediaCrypto;
    fn AMediaCrypto_delete(crypto: *mut AMediaCrypto);

    fn AMediaCodecCryptoInfo_new(
        subsamples: i32,
        key: *mut u8,
        iv: *mut u8,
        mode: u32,
        clear: *mut usize,
        encrypted: *mut usize,
    ) -> *mut AMediaCodecCryptoInfo;
    fn AMediaCodecCryptoInfo_delete(info: *mut AMediaCodecCryptoInfo) -> Status;
}

/// One encrypted sample on its way into the decoder.
pub struct Input<'a> {
    pub data: &'a [u8],
    pub iv: &'a [u8; 16],
    /// `(clear, encrypted)` byte runs. Empty means the whole sample is encrypted.
    pub subs: &'a [(u32, u32)],
    pub pts_us: u64,
}

/// What one look at the decoder's output found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Taken {
    /// Audio was appended, or the decoder had nothing ready yet.
    Pcm,
    /// The end of the stream came out. Whatever was appended with it is the last of it.
    End,
}

/// An AAC `MediaCodec` decrypting against one session.
pub struct Decoder {
    codec: NonNull<AMediaCodec>,
    crypto: NonNull<AMediaCrypto>,
    key: [u8; 16],
    rate: u32,
    channels: u16,
    /// Holds the session the crypto decrypts against open for as long as the codec runs.
    _cdm: Cdm,
}

// SAFETY: a codec in synchronous mode may be driven from any thread as long as only one does
// at a time, which `&mut self` on every call guarantees.
unsafe impl Send for Decoder {}

impl Decoder {
    /// Opens and starts an AAC decoder for `audio`, decrypting with the content key `key_id`
    /// that `cdm` holds a license for.
    pub fn open(cdm: &Cdm, key_id: &[u8], audio: &Audio) -> Result<Self> {
        let Ok(key) = <[u8; 16]>::try_from(key_id) else {
            bail!("a cenc key id is 16 bytes, not {}", key_id.len());
        };
        let session = cdm.session()?;
        // SAFETY: the uuid is 16 bytes and the session id outlives the call, which copies it.
        let crypto =
            unsafe { AMediaCrypto_new(SYSTEM_ID.as_ptr(), session.as_ptr().cast(), session.len()) };
        let Some(crypto) = NonNull::new(crypto) else {
            bail!("cannot open a media crypto on the widevine session");
        };
        // SAFETY: a constant, nul-terminated mime type.
        let codec = unsafe { AMediaCodec_createDecoderByType(c"audio/mp4a-latm".as_ptr()) };
        let Some(codec) = NonNull::new(codec) else {
            // SAFETY: made above and owned by nothing else.
            unsafe { AMediaCrypto_delete(crypto.as_ptr()) };
            bail!("this device has no aac decoder");
        };
        let decoder = Self {
            codec,
            crypto,
            key,
            rate: audio.rate,
            channels: audio.channels,
            _cdm: cdm.clone(),
        };
        // SAFETY: the format is made, filled, used and deleted here; every string is a nul-
        // terminated constant and the config outlives the call that copies it.
        let configured = unsafe {
            let format = AMediaFormat_new();
            AMediaFormat_setString(format, c"mime".as_ptr(), c"audio/mp4a-latm".as_ptr());
            AMediaFormat_setInt32(format, c"sample-rate".as_ptr(), audio.rate as i32);
            AMediaFormat_setInt32(format, c"channel-count".as_ptr(), i32::from(audio.channels));
            AMediaFormat_setBuffer(
                format,
                c"csd-0".as_ptr(),
                audio.config.as_ptr().cast(),
                audio.config.len(),
            );
            let configured =
                AMediaCodec_configure(codec.as_ptr(), format, ptr::null_mut(), crypto.as_ptr(), 0);
            AMediaFormat_delete(format);
            configured
        };
        check(configured, "configure the aac decoder")?;
        // SAFETY: a configured codec.
        check(
            unsafe { AMediaCodec_start(codec.as_ptr()) },
            "start the aac decoder",
        )?;
        log::info!(
            "widevine: android aac decoder started, {} Hz, {} channel(s) declared",
            audio.rate,
            audio.channels
        );
        Ok(decoder)
    }

    /// The rate of the audio coming out, which the decoder settles once it has seen the stream.
    pub fn rate(&self) -> u32 {
        self.rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Queues one sample, or with `None` the end of the stream. False when the decoder has no
    /// input buffer free, which leaves the sample to the caller to offer again.
    pub fn queue(&mut self, input: Option<Input>) -> Result<bool> {
        let codec = self.codec.as_ptr();
        // SAFETY: a started codec, polled without waiting.
        let index = unsafe { AMediaCodec_dequeueInputBuffer(codec, 0) };
        if index == TRY_AGAIN {
            return Ok(false);
        }
        let Ok(index) = usize::try_from(index) else {
            bail!("the aac decoder refused input with {index}");
        };
        let Some(input) = input else {
            // SAFETY: a buffer the codec just handed over, queued empty.
            let queued =
                unsafe { AMediaCodec_queueInputBuffer(codec, index, 0, 0, 0, END_OF_STREAM) };
            return check(queued, "end the aac stream").map(|()| true);
        };
        let mut room = 0usize;
        // SAFETY: the buffer the codec just handed over, `room` bytes long.
        let buffer = unsafe { AMediaCodec_getInputBuffer(codec, index, &mut room) };
        if buffer.is_null() || room < input.data.len() {
            bail!(
                "a sample of {} bytes does not fit the decoder's buffer",
                input.data.len()
            );
        }
        // SAFETY: checked to fit above, and the codec's buffer cannot overlap the sample.
        unsafe { ptr::copy_nonoverlapping(input.data.as_ptr(), buffer, input.data.len()) };
        let (mut clear, mut encrypted) = cenc::subsamples(input.data.len(), input.subs);
        let mut iv = *input.iv;
        // SAFETY: every pointer is valid for the call, which copies all of them, and the two
        // run lists are the same length.
        let queued = unsafe {
            let info = AMediaCodecCryptoInfo_new(
                clear.len() as i32,
                self.key.as_mut_ptr(),
                iv.as_mut_ptr(),
                AES_CTR,
                clear.as_mut_ptr(),
                encrypted.as_mut_ptr(),
            );
            if info.is_null() {
                bail!("cannot describe a sample's encryption to the decoder");
            }
            let queued = AMediaCodec_queueSecureInputBuffer(codec, index, 0, info, input.pts_us, 0);
            AMediaCodecCryptoInfo_delete(info);
            queued
        };
        check(queued, "queue an encrypted sample").map(|()| true)
    }

    /// Waits up to `wait` for decoded audio and appends it to `out`, interleaved, as `f32`.
    pub fn take(&mut self, wait: Duration, out: &mut Vec<f32>) -> Result<Taken> {
        let codec = self.codec.as_ptr();
        let mut info = BufferInfo::default();
        let wait = i64::try_from(wait.as_micros()).unwrap_or(i64::MAX);
        // SAFETY: a started codec and an info it fills.
        let index = unsafe { AMediaCodec_dequeueOutputBuffer(codec, &mut info, wait) };
        match index {
            TRY_AGAIN | BUFFERS_CHANGED => return Ok(Taken::Pcm),
            FORMAT_CHANGED => {
                self.format()?;
                return Ok(Taken::Pcm);
            }
            _ => {}
        }
        let Ok(index) = usize::try_from(index) else {
            bail!("the aac decoder failed with {index}");
        };
        let mut size = 0usize;
        // SAFETY: the buffer the codec just handed over, `size` bytes long; what is read from
        // it is the range the info names, checked to lie inside it.
        unsafe {
            let buffer = AMediaCodec_getOutputBuffer(codec, index, &mut size);
            let (start, len) = (info.offset.max(0) as usize, info.size.max(0) as usize);
            if !buffer.is_null() && start + len <= size {
                let pcm = std::slice::from_raw_parts(buffer.add(start), len);
                out.extend(
                    pcm.chunks_exact(2)
                        .map(|pair| f32::from(i16::from_ne_bytes([pair[0], pair[1]])) / 32768.0),
                );
            }
            AMediaCodec_releaseOutputBuffer(codec, index, false);
        }
        Ok(match info.flags & END_OF_STREAM {
            0 => Taken::Pcm,
            _ => Taken::End,
        })
    }

    /// Reads the output format the decoder settled on.
    fn format(&mut self) -> Result<()> {
        let (mut rate, mut channels, mut encoding) = (0, 0, PCM_16BIT);
        // SAFETY: the format is the codec's copy, read and deleted here.
        unsafe {
            let format = AMediaCodec_getOutputFormat(self.codec.as_ptr());
            if format.is_null() {
                return Ok(());
            }
            AMediaFormat_getInt32(format, c"sample-rate".as_ptr(), &mut rate);
            AMediaFormat_getInt32(format, c"channel-count".as_ptr(), &mut channels);
            AMediaFormat_getInt32(format, c"pcm-encoding".as_ptr(), &mut encoding);
            AMediaFormat_delete(format);
        }
        if encoding != PCM_16BIT {
            bail!("the aac decoder puts out pcm encoding {encoding}, not 16-bit");
        }
        if let (Ok(rate @ 1..), Ok(channels @ 1..)) = (u32::try_from(rate), u16::try_from(channels))
        {
            self.rate = rate;
            self.channels = channels;
        }
        log::info!(
            "widevine: android aac decoder puts out {} Hz, {} channel(s)",
            self.rate,
            self.channels
        );
        Ok(())
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: both are owned here alone, and the codec goes before the crypto it uses.
        unsafe {
            AMediaCodec_stop(self.codec.as_ptr());
            AMediaCodec_delete(self.codec.as_ptr());
            AMediaCrypto_delete(self.crypto.as_ptr());
        }
    }
}

fn check(status: Status, doing: &str) -> Result<()> {
    match status {
        0 => Ok(()),
        status => bail!("cannot {doing}: media status {status}"),
    }
}
