fn main() {
    let updater = std::env::var_os("CARGO_FEATURE_UPDATER").is_some();
    let server = std::env::var_os("CARGO_FEATURE_SERVER").is_some();
    // The player setup embeds the updater (built first as the `updater` flavor, see BuildInstallers.ps1).
    if !updater && !server {
        let exe = std::path::Path::new("payload").join("WSCoopUpdater.exe");
        println!("cargo:rerun-if-changed=payload/WSCoopUpdater.exe");
        if !exe.exists() {
            panic!(
                "\n\npayload\\WSCoopUpdater.exe is missing: the client setup embeds the updater.\n\
                 Build it first:  $env:CARGO_TARGET_DIR='target-updater'; cargo build --release --no-default-features --features updater\n\
                 then copy target-updater\\release\\wscoop-installer.exe to payload\\WSCoopUpdater.exe (BuildInstallers.ps1 does both).\n\n"
            );
        }
    }
    println!("cargo:rerun-if-env-changed=WSCOOP_AS_INVOKER");
    // Installers need administrator rights (firewall rules, background service, Program Files). The updater
    // runs as the player (it is started by the game) and asks for rights only when the game folder needs them.
    // WSCOOP_AS_INVOKER=1 builds a setup that runs without elevation (automated tests only).
    let level = if updater || std::env::var_os("WSCOOP_AS_INVOKER").is_some() { "asInvoker" } else { "requireAdministrator" };
    let manifest = format!(
        r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/></dependentAssembly></dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="{level}" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/>
  </application></compatibility>
</assembly>"#
    );
    let attrs = tauri_build::Attributes::new().windows_attributes(tauri_build::WindowsAttributes::new().app_manifest(manifest));
    tauri_build::try_build(attrs).expect("tauri build");
}
