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
