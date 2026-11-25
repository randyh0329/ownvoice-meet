// On macOS, the Apple Translation helper (apple-translate/main.swift) is compiled first, for both
// architectures, into binaries/ under the names Tauri's sidecar bundling expects
// (tauri.macos.conf.json, externalBin): one per target triple and a universal one. tauri_build
// checks those files exist, so this comes before it. Other platforms skip it.

use std::path::{Path, PathBuf};
use std::process::Command;

const HELPER: &str = "ownvoice-apple-translate";
/// The helper only runs on macOS 26 or later (the app checks first); 15 is where its APIs begin.
const HELPER_MIN_MACOS: &str = "15.0";

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") && cfg!(target_os = "macos") {
        build_apple_helper();
    }
    tauri_build::build()
}

fn build_apple_helper() {
    println!("cargo:rerun-if-changed=apple-translate/main.swift");
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let source = manifest.join("apple-translate/main.swift");
    let bins = manifest.join("binaries");
    std::fs::create_dir_all(&bins).expect("binaries/");
    let sdk = run(Command::new("xcrun").args(["--sdk", "macosx", "--show-sdk-path"]));
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let mut slices = Vec::new();
    for (swift_arch, rust_arch) in [("arm64", "aarch64"), ("x86_64", "x86_64")] {
        let out = out_dir.join(format!("{HELPER}-{swift_arch}"));
        compile(&source, &sdk, swift_arch, &out);
        let named = bins.join(format!("{HELPER}-{rust_arch}-apple-darwin"));
        std::fs::copy(&out, &named).expect("copy helper");
        slices.push(out);
    }
    let universal = bins.join(format!("{HELPER}-universal-apple-darwin"));
    let mut lipo = Command::new("lipo");
    lipo.arg("-create").args(&slices).arg("-output").arg(&universal);
    run(&mut lipo);
}

fn compile(source: &Path, sdk: &str, arch: &str, out: &Path) {
    let mut cmd = Command::new("xcrun");
    cmd.args(["--sdk", "macosx", "swiftc", "-swift-version", "5", "-O"])
        .args(["-target", &format!("{arch}-apple-macos{HELPER_MIN_MACOS}")])
        .args(["-sdk", sdk])
        .arg(source)
        .arg("-o")
        .arg(out);
    run(&mut cmd);
}

fn run(cmd: &mut Command) -> String {
    let output = cmd.output().unwrap_or_else(|e| panic!("could not run {cmd:?}: {e} (install the Xcode Command Line Tools)"));
    if !output.status.success() {
        panic!("{cmd:?} failed:\n{}\n{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    }
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}
