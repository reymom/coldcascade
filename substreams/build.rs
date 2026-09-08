// The proto is compiled twice from the same file, on purpose: `substreams pack` parses it to put
// the descriptor in the .spkg, and this puts the matching Rust types in the module. One source,
// so the wire format the endpoint advertises and the one the module writes cannot drift apart.
fn main() {
    println!("cargo:rerun-if-changed=proto/desk.proto");
    let mut cfg = prost_build::Config::new();
    cfg.out_dir("src/pb");
    cfg.compile_protos(&["proto/desk.proto"], &["proto"])
        .expect("compiling proto/desk.proto — is protoc on PATH?");
}
