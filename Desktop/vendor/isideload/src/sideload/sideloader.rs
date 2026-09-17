use crate::{
    dev::{
        app_groups::AppGroupsApi,
        app_ids::{AppId, AppIdsApi},
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{
        TeamSelection,
        application::{Application, SpecialApp},
        builder::MaxCertsBehavior,
        cert_identity::CertificateIdentity,
        sign,
    },
    util::{device::IdeviceInfo, storage::SideloadingStorage},
};

use std::path::PathBuf;

use idevice::provider::IdeviceProvider;
use rootcause::{option_ext::OptionExt, prelude::*};
use tracing::info;

pub struct Sideloader {
    team_selection: TeamSelection,
    storage: Box<dyn SideloadingStorage>,
    dev_session: DeveloperSession,
    machine_name: String,
    apple_email: String,
    max_certs_behavior: MaxCertsBehavior,
    //extensions_behavior: ExtensionsBehavior,
    delete_app_after_install: bool,
    team: Option<DeveloperTeam>,
}

impl Sideloader {
    /// Construct a new `Sideloader` instance with the provided configuration
    ///
    /// See [`crate::sideload::SideloaderBuilder`] for more details and a more convenient way to construct a `Sideloader`.
    pub fn new(
        dev_session: DeveloperSession,
        apple_email: String,
        team_selection: TeamSelection,
        max_certs_behavior: MaxCertsBehavior,
        machine_name: String,
        storage: Box<dyn SideloadingStorage>,
        //extensions_behavior: ExtensionsBehavior,
        delete_app_after_install: bool,
    ) -> Self {
        Sideloader {
            team_selection,
            storage,
            dev_session,
            machine_name,
            apple_email,
            max_certs_behavior,
            //extensions_behavior,
            delete_app_after_install,
            team: None,
        }
    }

    /// Sign the app at the provided path and return the path to the signed app bundle (in a temp dir). To sign and install, see [`Self::install_app`].
    pub async fn sign_app<F, Fut>(
        &mut self,
        app_path: PathBuf,
        team: Option<DeveloperTeam>,
        // this will be replaced with proper entitlement handling later
        increased_memory_limit: bool,
        progress_callback: Option<F>,
    ) -> Result<(PathBuf, Option<SpecialApp>), Report>
    where
        F: Fn(f32) -> Fut,
        Fut: Future<Output = ()>,
    {
        let team = match team {
            Some(t) => t,
            None => self.get_team().await?,
        };
        let cert_identity = {
            let _phase = crate::util::timing::Phase::start("  signing certificate");
            CertificateIdentity::retrieve(
                &self.machine_name,
                &self.apple_email,
                &mut self.dev_session,
                &team,
                self.storage.as_ref(),
                &self.max_certs_behavior,
            )
            .await
            .context("Failed to retrieve certificate identity")?
        };

        if let Some(callback) = &progress_callback {
            callback(0.1).await;
        }

        let mut app = Application::new(app_path)?;
        let special = app.get_special_app();

        let main_bundle_id = app.main_bundle_id()?;
        let main_app_name = app.main_app_name()?;
        // A bundle that has been through this once already carries the team
        // suffix. Re-signing the installed copy (renewal on the phone) must
        // keep the identifier it has, or the result installs as a second app
        // and the extensions end up with the team named twice.
        let team_suffix = format!(".{}", team.team_id);
        let main_app_id_str = if main_bundle_id.ends_with(&team_suffix) {
            main_bundle_id.clone()
        } else {
            format!("{}.{}", main_bundle_id, team.team_id)
        };
        app.update_bundle_id(&main_bundle_id, &main_app_id_str)?;
        let mut app_ids = {
            let _phase = crate::util::timing::Phase::start("  register app IDs");
            app.register_app_ids(
                /*&self.extensions_behavior, */ &mut self.dev_session,
                &team,
            )
            .await?
        };
        let main_app_id = match app_ids
            .iter()
            .find(|app_id| app_id.identifier == main_app_id_str)
        {
            Some(id) => id,
            None => {
                bail!(
                    "Main app ID {} not found in registered app IDs",
                    main_app_id_str
                );
            }
        }
        .clone();

        let group_identifier = format!(
            "group.{}",
            if Some(SpecialApp::SideStoreLc) == special {
                format!("com.SideStore.SideStore.{}", team.team_id)
            } else {
                main_app_id_str.clone()
            }
        );

        let app_group = {
            let _phase = crate::util::timing::Phase::start("  app group");
            self.dev_session
                .ensure_app_group(&team, &main_app_name, &group_identifier, None)
                .await?
        };

        {
            let _phase = crate::util::timing::Phase::start("  assign app groups");
            // Each app ID's work names only that app ID. `ensure_group_feature`
            // updates its own appIdId, `assign_app_group` posts its own appIdId
            // with the group that already exists, neither returns anything the
            // other needs, and nothing after this loop reads one app ID's result
            // to build another's. So they run together instead of one at a time.
            //
            // The order *within* one app ID still holds, because a group cannot
            // be assigned to an app ID whose group feature is still off.
            //
            // Bounded rather than all at once: Apple answers 429 to bursts, and
            // unlike the grandslam path these developer endpoints have no
            // backoff of their own to absorb it.
            const AT_ONCE: usize = 4;

            // Warm the shared anisette generator once so the clones below
            // inherit the cached headers instead of each fetching its own set
            // from the helper.
            self.dev_session
                .get_headers()
                .await
                .context("Failed to prepare developer request headers")?;

            for start in (0..app_ids.len()).step_by(AT_ONCE) {
                let end = (start + AT_ONCE).min(app_ids.len());
                let mut handles = Vec::with_capacity(end - start);

                for index in start..end {
                    let mut session = self.dev_session.clone();
                    let mut app_id = app_ids[index].clone();
                    let team = team.clone();
                    let group = app_group.clone();
                    handles.push(tokio::spawn(async move {
                        app_id
                            .ensure_group_feature(&mut session, &team)
                            .await
                            .map_err(|error| error.to_string())?;

                        session
                            .assign_app_group(&team, &group, &app_id, None)
                            .await
                            .map_err(|error| error.to_string())?;

                        if increased_memory_limit {
                            session
                                .add_increased_memory_limit(&team, &app_id)
                                .await
                                .map_err(|error| error.to_string())?;
                        }

                        Ok::<(usize, AppId), String>((index, app_id))
                    }));
                }

                for handle in handles {
                    match handle.await {
                        Ok(Ok((index, app_id))) => app_ids[index] = app_id,
                        Ok(Err(message)) => bail!("{}", message),
                        Err(error) => bail!("App ID task did not finish: {}", error),
                    }
                }
            }
        }

        if let Some(callback) = &progress_callback {
            callback(0.15).await;
        }

        info!("App IDs configured");

        app.apply_special_app_behavior(&special, &group_identifier, &cert_identity)
            .await
            .context("Failed to modify app bundle")?;

        let provisioning_profile = {
            let _phase = crate::util::timing::Phase::start("  provisioning profile");
            self.dev_session
                .download_team_provisioning_profile(&team, &main_app_id, None)
                .await?
        };

        if let Some(callback) = &progress_callback {
            callback(0.2).await;
        }

        info!("Acquired provisioning profile");

        app.bundle.write_info()?;
        for ext in app.bundle.app_extensions_mut() {
            ext.write_info()?;
        }
        for ext in app.bundle.frameworks_mut() {
            ext.write_info()?;
        }

        isideload_vfs::fs::write(
            app.bundle.bundle_dir.join("embedded.mobileprovision"),
            provisioning_profile.encoded_profile.as_ref(),
        )?;

        if let Some(callback) = &progress_callback {
            callback(0.3).await;
        }

        {
            let _phase = crate::util::timing::Phase::start("  code signing");
            sign::sign(
                &mut app,
                &cert_identity,
                &provisioning_profile,
                &special,
                &team,
                progress_callback,
            )
            .await
            .context("Failed to sign app")?;
        }

        info!("App signed!");

        Ok((app.bundle.bundle_dir.clone(), special))
    }

    #[cfg(feature = "install")]
    /// Sign and install an app to a device.
    pub async fn install_app<F, Fut>(
        &mut self,
        device_provider: &impl IdeviceProvider,
        app_path: PathBuf,
        // this is gross but will be replaced with proper entitlement handling later
        increased_memory_limit: bool,
        progress_callback: Option<F>,
    ) -> Result<Option<SpecialApp>, Report>
    where
        F: Fn(f32) -> Fut,
        Fut: Future<Output = ()>,
    {
        let device_info = IdeviceInfo::from_device(device_provider).await?;

        let team = self.get_team().await?;
        self.dev_session
            .ensure_device_registered(&team, &device_info.name, &device_info.udid, None)
            .await?;

        let (signed_app_path, special_app) = self
            .sign_app(
                app_path,
                Some(team),
                increased_memory_limit,
                progress_callback,
            )
            .await?;

        info!("Transferring App...");

        crate::sideload::install::install_app(device_provider, &signed_app_path, |progress| {
            info!("Installing: {}%", progress);
        })
        .await
        .context("Failed to install app on device")?;

        if self.delete_app_after_install
            && let Err(e) = isideload_vfs::fs::remove_dir_all(signed_app_path)
        {
            tracing::warn!("Failed to remove temporary signed app file: {}", e);
        }

        Ok(special_app)
    }

    /// Get the developer team according to the configured team selection behavior
    pub async fn get_team(&mut self) -> Result<DeveloperTeam, Report> {
        if let Some(team) = &self.team {
            return Ok(team.clone());
        }
        let teams = self.dev_session.list_teams().await?;
        let team = match teams.len() {
            0 => {
                bail!("No developer teams available")
            }
            1 => teams.into_iter().next().ok_or_report()?,
            _ => {
                info!(
                    "Multiple developer teams found, {} as per configuration",
                    self.team_selection
                );
                match &self.team_selection {
                    TeamSelection::First => teams.into_iter().next().ok_or_report()?,
                    TeamSelection::PromptOnce(prompt_fn)
                    | TeamSelection::PromptAlways(prompt_fn) => {
                        let selection =
                            prompt_fn(&teams).ok_or_else(|| report!("No team selected"))?;
                        teams
                            .into_iter()
                            .find(|t| t.team_id == selection)
                            .ok_or_else(|| report!("No team found with ID {}", selection))?
                    }
                }
            }
        };
        if !matches!(&self.team_selection, TeamSelection::PromptAlways(_)) {
            self.team = Some(team.clone());
        }
        Ok(team)
    }

    pub fn get_dev_session(&mut self) -> &mut DeveloperSession {
        &mut self.dev_session
    }

    pub fn get_email(&self) -> &str {
        &self.apple_email
    }
}
