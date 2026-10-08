//! Meteor's key and the encryption of its side channels (microphone and
//! depth maps).
//!
//! Meteor keeps one X25519 key pair in its data folder (`meteor.key`), made
//! on first run, and publishes the public key in discovery. The headset
//! remembers it per host the first time it sees it, so a different Meteor
//! answering for that PC later is noticed. For each microphone session or
//! depth connection the headset makes a fresh key pair and sends its public
//! key; both sides derive an AES-256-GCM key with HKDF-SHA256 (salt: the
//! headset's public key then Meteor's; info: one string per channel). Only
//! the Meteor holding the private key can derive it.

use std::path::Path;

pub const KEY_BYTES: usize = 32;
pub const TAG_BYTES: usize = 16;
/// Discovery's name for this scheme.
pub const ENCRYPTION: &str = "x25519-hkdf-sha256-aes256gcm";

pub struct MeteorKey {
    secret: x25519_dalek::StaticSecret,
    pub public: [u8; KEY_BYTES],
}

impl MeteorKey {
    /// Reads the key from `path`, or makes one and saves it there (readable
    /// only by this user on Unix).
    pub fn load_or_create(path: &Path) -> Result<MeteorKey, String> {
        if let Ok(bytes) = std::fs::read(path) {
            let seed: [u8; KEY_BYTES] =
                bytes.try_into().map_err(|_| format!("{} isn't a {KEY_BYTES}-byte key", path.display()))?;
            return Ok(MeteorKey::from_seed(seed));
        }
        let mut seed = [0u8; KEY_BYTES];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut seed)
            .map_err(|_| "no system randomness for Meteor's key".to_string())?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        write_private(path, &seed).map_err(|e| format!("{}: {e}", path.display()))?;
        log::info!("Made Meteor's key ({})", path.display());
        Ok(MeteorKey::from_seed(seed))
    }

    pub fn from_seed(seed: [u8; KEY_BYTES]) -> MeteorKey {
        let secret = x25519_dalek::StaticSecret::from(seed);
        let public = x25519_dalek::PublicKey::from(&secret).to_bytes();
        MeteorKey { secret, public }
    }

    pub fn public_hex(&self) -> String {
        self.public.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The AES-256-GCM key for a headset session. None for a public key that
    /// yields no shared secret.
    pub fn session_key(&self, theirs: &[u8; KEY_BYTES], info: &[u8]) -> Option<ring::aead::LessSafeKey> {
        let shared = self.secret.diffie_hellman(&x25519_dalek::PublicKey::from(*theirs));
        if !shared.was_contributory() {
            return None;
        }
        Some(derive(shared.as_bytes(), theirs, &self.public, info))
    }
}

/// HKDF-SHA256 over the shared secret, salted with the headset's public key
/// then Meteor's.
pub fn derive(shared: &[u8], headset: &[u8; KEY_BYTES], meteor: &[u8; KEY_BYTES], info: &[u8]) -> ring::aead::LessSafeKey {
    let mut salt = [0u8; KEY_BYTES * 2];
    salt[..KEY_BYTES].copy_from_slice(headset);
    salt[KEY_BYTES..].copy_from_slice(meteor);
    let prk = ring::hkdf::Salt::new(ring::hkdf::HKDF_SHA256, &salt).extract(shared);
    let info = [info];
    let okm = prk.expand(&info, &ring::aead::AES_256_GCM).expect("HKDF output is one AES-256 key");
    ring::aead::LessSafeKey::new(ring::aead::UnboundKey::from(okm))
}

/// A message counter as a nonce: little-endian, then zeros. Unique as long
/// as the counter never repeats under one session key.
pub fn nonce(counter: u64) -> ring::aead::Nonce {
    let mut bytes = [0u8; 12];
    bytes[..8].copy_from_slice(&counter.to_le_bytes());
    ring::aead::Nonce::assume_unique_for_key(bytes)
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?.write_all(bytes)
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_its_key() {
        let dir = std::env::temp_dir().join(format!("meteor-key-test-{}", std::process::id()));
        let path = dir.join("meteor.key");
        let first = MeteorKey::load_or_create(&path).unwrap();
        let again = MeteorKey::load_or_create(&path).unwrap();
        assert_eq!(first.public, again.public);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn both_sides_agree() {
        let meteor = MeteorKey::from_seed([7; KEY_BYTES]);
        let headset = x25519_dalek::StaticSecret::from([9; KEY_BYTES]);
        let headset_public = x25519_dalek::PublicKey::from(&headset).to_bytes();
        let ours = meteor.session_key(&headset_public, b"test").unwrap();
        let shared = headset.diffie_hellman(&x25519_dalek::PublicKey::from(meteor.public));
        let theirs = derive(shared.as_bytes(), &headset_public, &meteor.public, b"test");
        let mut message = b"hello".to_vec();
        theirs.seal_in_place_append_tag(nonce(3), ring::aead::Aad::empty(), &mut message).unwrap();
        assert_eq!(ours.open_in_place(nonce(3), ring::aead::Aad::empty(), &mut message).unwrap(), b"hello");
        // A low-order public key gives no shared secret.
        assert!(meteor.session_key(&[0; KEY_BYTES], b"test").is_none());
    }
}
