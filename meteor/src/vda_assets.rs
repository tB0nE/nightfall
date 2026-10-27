//! Pinned public Vulkan exports. Network data never chooses a path or checksum.
use serde::Deserialize;
use std::{collections::BTreeMap, path::Path, sync::OnceLock};

#[derive(Deserialize)]
pub struct Catalog { pub schema: u32, pub base_url: String, pub models: BTreeMap<String, Model> }
#[derive(Deserialize)]
pub struct Model { pub width: usize, pub height: usize, pub files: Vec<File> }
#[derive(Deserialize)]
pub struct File { pub name: String, pub asset: String, pub bytes: u64, pub sha256: String }
pub fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| serde_json::from_str(include_str!("../models/vda-vulkan-downloads.json")).expect("Invalid compiled VDA download catalog"))
}
pub fn model(id: &str) -> Result<&'static Model, String> {
    let model=catalog().models.get(id).ok_or("Unknown Vulkan VDA model")?;
    if catalog().schema != 1 || !crate::vda_vulkan::is_model(id) || (model.width,model.height)!=crate::vda_vulkan::size(id) {
        return Err("Invalid compiled VDA download metadata".into());
    }
    Ok(model)
}
pub fn bytes(id: &str) -> Result<u64,String> { Ok(model(id)?.files.iter().map(|file|file.bytes).sum()) }
pub fn installed(root: &Path, id: &str) -> bool { crate::vda_vulkan::present(root,id) }

#[cfg(test)] mod tests {
    #[test] fn pinned_assets_are_complete_and_cannot_escape_the_model_directory() {
        for id in [crate::vda_vulkan::FULL,crate::vda_vulkan::FAST] {
            let model=super::model(id).unwrap();
            assert_eq!(model.files.len(),6);
            for name in ["manifest.json","LICENSE","cold.ncnn.param","cold.ncnn.bin","step.ncnn.param","step.ncnn.bin"] {
                assert!(model.files.iter().any(|file|file.name==name));
            }
            for file in &model.files {
                assert!(!file.name.contains('/') && !file.name.contains(".."));
                assert_eq!(file.asset,format!("{id}-{}",file.name));
                assert_eq!(file.sha256.len(),64);
                assert!(file.sha256.bytes().all(|b|b.is_ascii_hexdigit()));
                assert!(file.bytes>0);
            }
            assert!(super::bytes(id).unwrap()>200_000_000);
        }
        assert!(super::model("../../invalid").is_err());
    }
}
