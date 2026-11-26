// On macOS, the Apple Translation helper (apple-translate/main.swift) is compiled first, for both
// architectures, into binaries/ under the names Tauri's sidecar bundling expects
// (tauri.macos.conf.json, externalBin): one per target triple and a universal one. tauri_build
// checks those files exist, so this comes before it. Other platforms skip it.

use std::path::{Path, PathBuf};
use std::process::Command;

const HELPER: &str = "ownvoice-apple-translate";
/// The helper only translates on macOS 26 or later (apple_translate.rs checks the version before
/// starting it, and tells an older Mac so); 15 is where its APIs begin.
const HELPER_MIN_MACOS: &str = "15.0";

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") && cfg!(target_os = "macos") {
        build_apple_helper();
    }
    // llama.cpp (local translation) needs clang's compiler-rt on every macOS build.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        link_compiler_rt();
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

/// llama.cpp's Metal code checks the macOS version with `@available`, which clang turns into calls
/// to `__isPlatformVersionAtLeast` when the app targets an older macOS (ours: 11). That function
/// lives in clang's compiler-rt (`libclang_rt.osx.a`), which rustc does not link, so the release
/// build failed with an undefined symbol. Link it from the clang that Xcode provides.
fn link_compiler_rt() {
    let out = Command::new("xcrun")
        .args(["clang", "--print-resource-dir"])
        .output();
    let dir = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => {
            println!("cargo:warning=could not ask clang for its resource dir; not linking compiler-rt");
            return;
        }
    };
    let lib_dir = std::path::Path::new(&dir).join("lib").join("darwin");
    if !lib_dir.join("libclang_rt.osx.a").is_file() {
        println!(
            "cargo:warning=no libclang_rt.osx.a in {}; not linking compiler-rt",
            lib_dir.display()
        );
        return;
    }
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");
}
