//! Handing the phone's pairing record to Cloak.
//!
//! This is what makes the phone-side setup disappear. The computer already
//! has a pairing record for this iPhone — that is what everything else here
//! runs on — so rather than making the user pair the phone with itself using
//! a six digit code, the installer writes that record straight into Cloak's
//! own Documents folder. Cloak finds it on first launch and is simply ready.

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    house_arrest::HouseArrestClient,
    provider::IdeviceProvider,
    IdeviceService,
};

/// The name Cloak looks for.
pub const PAIRING_FILE: &str = "cloak-pairing.plist";

pub async fn send_pairing_record(
    provider: &dyn IdeviceProvider,
    bundle_id: &str,
) -> Result<(), String> {
    let pairing = provider
        .get_pairing_file()
        .await
        .map_err(|e| format!("Could not read this computer's pairing record: {e}"))?;

    let bytes = pairing
        .serialize()
        .map_err(|e| format!("Could not package the pairing record: {e}"))?;

    let house_arrest = HouseArrestClient::connect(provider)
        .await
        .map_err(|e| format!("Could not open Cloak's folder on the iPhone: {e}"))?;

    // Documents is the narrow door and the one that usually opens. If the
    // phone refuses it, the whole container is the wide one, and the file
    // still lands in the same place from Cloak's point of view.
    let (mut afc, path): (AfcClient, String) = match house_arrest.vend_documents(bundle_id).await {
        Ok(afc) => (afc, format!("/{PAIRING_FILE}")),
        Err(first) => {
            let house_arrest = HouseArrestClient::connect(provider)
                .await
                .map_err(|e| format!("Could not open Cloak's folder on the iPhone: {e}"))?;
            let afc = house_arrest.vend_container(bundle_id).await.map_err(|e| {
                format!("The iPhone would not open Cloak's folder: {first}, then {e}")
            })?;
            (afc, format!("/Documents/{PAIRING_FILE}"))
        }
    };

    let mut file = afc
        .open(path, AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("Could not create the pairing file: {e}"))?;

    file.write_entire(&bytes)
        .await
        .map_err(|e| format!("Could not write the pairing file: {e}"))?;

    Ok(())
}

/// Reads the UUID out of the provisioning profile inside a signed app.
///
/// The profile is a CMS envelope with a plain XML plist inside it, so the
/// plist can be lifted out without doing any crypto.
pub fn profile_uuid(signed_app: &std::path::Path) -> Option<String> {
    let bytes = std::fs::read(signed_app.join("embedded.mobileprovision")).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let start = text.find("<plist")?;
    let end = text[start..].find("</plist>")? + start + "</plist>".len();
    let value: plist::Value = plist::from_bytes(text[start..end].as_bytes()).ok()?;
    value
        .as_dictionary()?
        .get("UUID")?
        .as_string()
        .map(str::to_owned)
}

/// Tells iOS to trust the certificate this app was signed with.
///
/// Without this, the first launch is met with "Untrusted Developer" and the
/// user has to go hunting through Settings, General, VPN & Device Management
/// for a row that is not obviously the one they want. iOS exposes the same
/// action to a connected computer, so the installer just does it.
pub async fn trust_signer(
    provider: &dyn IdeviceProvider,
    profile_uuid: &str,
) -> Result<bool, String> {
    use idevice::amfi::AmfiClient;

    let mut amfi = AmfiClient::connect(provider)
        .await
        .map_err(|e| format!("Could not reach the security service on the iPhone: {e}"))?;

    amfi.trust_app_signer(profile_uuid)
        .await
        .map_err(|e| format!("The iPhone would not trust the signature: {e}"))
}

/// Puts the pairing record inside the app itself, before it is signed.
///
/// The old route pushed the file over AFC once the app was on the phone, and
/// iOS refused it with a permission error on every install. Nothing about that
/// is recoverable from the outside: the folder either opens or it does not, and
/// when it does not the app has no pairing record and falls back to pairing
/// with itself, which only works on iOS 27.
///
/// A file placed in the bundle before signing has none of those problems. It is
/// covered by the signature like everything else, it arrives with the app, and
/// there is no version of iOS where it fails to be there.
pub fn bundle_pairing_record(
    ipa: &std::path::Path,
    record: &[u8],
    destination: &std::path::Path,
) -> Result<(), String> {
    use std::io::Write;

    let source = std::fs::File::open(ipa).map_err(|e| format!("Could not open the app: {e}"))?;
    let mut archive =
        zip::ZipArchive::new(source).map_err(|e| format!("Could not read the app: {e}"))?;

    // The bundle is Payload/<something>.app, and the name is not fixed.
    let app_dir = archive
        .file_names()
        .find(|name| name.starts_with("Payload/") && name.ends_with(".app/Info.plist"))
        .map(|name| name.trim_end_matches("Info.plist").to_string())
        .ok_or_else(|| "That does not look like an iPhone app.".to_string())?;

    let output =
        std::fs::File::create(destination).map_err(|e| format!("Could not write the app: {e}"))?;
    let mut writer = zip::ZipWriter::new(output);

    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|e| format!("Could not read the app: {e}"))?;
        // Copied without recompressing: this runs on every install and there is
        // nothing to gain by rebuilding several megabytes of it.
        writer
            .raw_copy_file(entry)
            .map_err(|e| format!("Could not rebuild the app: {e}"))?;
    }

    writer
        .start_file(
            format!("{app_dir}{PAIRING_FILE}"),
            zip::write::SimpleFileOptions::default(),
        )
        .map_err(|e| format!("Could not add the pairing record: {e}"))?;
    writer
        .write_all(record)
        .map_err(|e| format!("Could not add the pairing record: {e}"))?;

    writer
        .finish()
        .map_err(|e| format!("Could not finish the app: {e}"))?;

    Ok(())
}

/// This computer's pairing record for the phone, as bytes.
pub async fn pairing_record(provider: &dyn IdeviceProvider) -> Result<Vec<u8>, String> {
    provider
        .get_pairing_file()
        .await
        .map_err(|e| format!("Could not read this computer's pairing record: {e}"))?
        .serialize()
        .map_err(|e| format!("Could not package the pairing record: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Proves the record really lands next to Info.plist and that the rest of
    /// the app survives the rebuild. This is the one step between a phone
    /// below iOS 27 working and not working, so it is worth knowing it holds
    /// without having a phone in hand.
    #[test]
    fn record_lands_in_the_bundle() {
        let dir = std::env::temp_dir().join("cloak-handoff-test");
        let _ = std::fs::create_dir_all(&dir);
        let source = dir.join("in.ipa");
        let output = dir.join("out.ipa");

        {
            use std::io::Write;
            let file = std::fs::File::create(&source).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();
            writer
                .start_file("Payload/Cloak.app/Info.plist", options)
                .unwrap();
            writer.write_all(b"<plist/>").unwrap();
            writer
                .start_file("Payload/Cloak.app/Cloak", options)
                .unwrap();
            writer.write_all(b"binary").unwrap();
            writer.finish().unwrap();
        }

        bundle_pairing_record(&source, b"the-record", &output).unwrap();

        let mut archive = zip::ZipArchive::new(std::fs::File::open(&output).unwrap()).unwrap();
        let names: Vec<String> = archive.file_names().map(str::to_owned).collect();
        assert!(names.contains(&format!("Payload/Cloak.app/{PAIRING_FILE}")));
        assert!(names.contains(&"Payload/Cloak.app/Cloak".to_string()));

        use std::io::Read;
        let mut entry = archive
            .by_name(&format!("Payload/Cloak.app/{PAIRING_FILE}"))
            .unwrap();
        let mut body = Vec::new();
        entry.read_to_end(&mut body).unwrap();
        assert_eq!(body, b"the-record");
    }
}
