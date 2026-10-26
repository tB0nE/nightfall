//! Opt-in sequential benchmark of the production model implementations.
//! METEOR_BENCH_DIR must contain 1280x720 RGB24 frames.rgb. No user state changes.
use super::*;
use serde_json::{Value, json};

fn stats(mut samples: Vec<f64>) -> Value {
    samples.sort_by(f64::total_cmp);
    let n = samples.len();
    let median = (samples[(n - 1) / 2] + samples[n / 2]) * 0.5;
    json!({"samples":n,"median_ms":median,"p95_ms":samples[(n*95).div_ceil(100)-1],"max_ms":samples[n-1],"inference_ceiling_hz":1000./median})
}
fn validate(output: &[f32], size: (usize, usize)) {
    assert_eq!(output.len(), size.0 * size.1);
    assert!(output.iter().all(|v| v.is_finite()));
    assert!(
        output.iter().copied().fold(f32::NEG_INFINITY, f32::max)
            > output.iter().copied().fold(f32::INFINITY, f32::min)
    );
}

#[test]
#[ignore = "full hardware benchmark; requires installed models, GPUs and game fixture"]
fn all_hardware_models() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dir = PathBuf::from(std::env::var_os("METEOR_BENCH_DIR").expect("METEOR_BENCH_DIR"));
    ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
    crate::tensorrt::configure(None);
    // TensorRT may build a missing cache in Meteor's own child executable.
    unsafe {
        std::env::set_var(
            "METEOR_BUILDER",
            root.join("target/release/nightfall-meteor"),
        );
    }
    let models = crate::config::default_models_dir();
    let frames = std::fs::read(dir.join("frames.rgb")).unwrap();
    let source_size = vda::DECODE_SIZE;
    let stride = source_size.0 * source_size.1 * 3;
    assert!(frames.len() >= stride * 16 && frames.len() % stride == 0);
    let source: Vec<_> = frames.chunks_exact(stride).collect();
    let mut configurations = Vec::new();
    let gpus = ncnn::gpu_names();
    let has_nvidia = gpus.iter().any(|gpu| gpu.to_lowercase().contains("nvidia"));
    for gpu in gpus.into_iter().map(Some).chain([None]) {
        for id in [
            "zipdepth_edgepad_256",
            "zipdepth_edgepad_384",
            "zipdepth_wide_512x288",
            "zipdepth_wide_672x384",
        ] {
            configurations.push((
                format!("{id}.ncnn.param"),
                gpu.clone(),
                if gpu.is_some() {
                    Backend::Cuda
                } else {
                    Backend::Cpu
                },
            ));
        }
        if gpu.is_some() {
            for id in [vda_vulkan::FULL, vda_vulkan::FAST] {
                configurations.push((id.into(), gpu.clone(), Backend::Cuda));
            }
        }
    }
    if has_nvidia {
        configurations.push((vda::ID.into(), None, Backend::TensorRt));
    }
    let expected = configurations.len();
    let mut results = Vec::new();
    for (id, gpu, backend) in configurations {
        let device = gpu.clone().unwrap_or_else(|| {
            if backend == Backend::Cpu {
                "CPU".into()
            } else {
                "NVIDIA TensorRT".into()
            }
        });
        eprintln!("BENCH START {device} {id}");
        let start = Instant::now();
        let loaded = Engine::load(
            &models,
            &id,
            backend,
            &crate::config::cache_dir().join("tensorrt"),
            gpu.as_deref(),
        );
        let mut engine = match loaded {
            Ok(model) => model,
            Err(error) => {
                results.push(json!({"model":id,"device":device,"error":error}));
                std::fs::write(
                    dir.join("results.json"),
                    serde_json::to_vec_pretty(&results).unwrap(),
                )
                .unwrap();
                eprintln!("BENCH FAILED {device} {id}: {error}");
                continue;
            }
        };
        let load_ms = start.elapsed().as_secs_f64() * 1000.;
        let size = engine.output_size();
        // Cache model inputs outside the inference timer. Production resize code.
        let rgb: Vec<Vec<u8>> = source
            .iter()
            .map(|src| {
                if is_vda(&id) {
                    return src.to_vec();
                }
                let mut out = Vec::new();
                resize_rgb(src, source_size.0, source_size.1, size.0, size.1, &mut out);
                out
            })
            .collect();
        let normalized: Vec<Vec<f32>> = if is_vda(&id) {
            source
                .iter()
                .map(|src| {
                    let plane = source_size.0 * source_size.1;
                    let mut planar = vec![0.; plane * 3];
                    for (i, p) in src.chunks_exact(3).enumerate() {
                        for c in 0..3 {
                            planar[c * plane + i] = f32::from(p[c]) / 255.;
                        }
                    }
                    vda::resize_normalize_size(
                        &planar,
                        source_size.0,
                        source_size.1,
                        size.0,
                        size.1,
                    )
                })
                .collect()
        } else {
            Vec::new()
        };
        let mut times = Vec::new();
        let mut graph_times = Vec::new();
        for i in 0..96 {
            let k = i % source.len();
            let start = Instant::now();
            let output = match &mut engine {
                Engine::Ncnn(m) => m.infer(&rgb[k]).unwrap(),
                Engine::VdaVulkan(m) => m.infer_normalized(&normalized[k], i == 0).unwrap(),
                Engine::Vda(m) => {
                    let (out, report) = m.infer_normalized(&normalized[k], i == 0).unwrap();
                    if i >= 16 {
                        graph_times.push(report.model.as_secs_f64() * 1000.);
                    }
                    out
                }
                _ => unreachable!(),
            };
            let ms = start.elapsed().as_secs_f64() * 1000.;
            validate(&output, size);
            if i >= 16 {
                times.push(ms);
            }
        }
        // Separate, explicitly host-RGB reference path: production preparation,
        // default VDA softening, normalization and CPU alignment/contour cleanup.
        // Excludes decode, networking, CUDA decoder handoff and GPU refinement.
        let mut final_times = Vec::new();
        let mut model_times = Vec::new();
        let mut post_times = Vec::new();
        let mut post = PostProcessor::default();
        if is_vda(&id) {
            post.depth_tau = 0.;
        }
        match &mut engine {
            Engine::VdaVulkan(m) => m.reset(),
            Engine::Vda(m) => m.reset("benchmark RGB path"),
            _ => {}
        }
        let base = Instant::now();
        for i in 0..48 {
            let k = i % source.len();
            let now = base + Duration::from_millis(i as u64 * 50);
            let start = Instant::now();
            let raw = match &mut engine {
                Engine::Ncnn(m) => m.infer(&rgb[k]).unwrap(),
                Engine::VdaVulkan(m) => m
                    .infer_rgb(
                        source[k],
                        source_size,
                        now,
                        vda::SOFTENING[vda::DEFAULT_SOFTENING].1,
                    )
                    .unwrap(),
                Engine::Vda(m) => {
                    let report = m.infer_rgb(source[k], source_size).unwrap();
                    m.download_depth(report.depth).unwrap()
                }
                _ => unreachable!(),
            };
            let model_end = Instant::now();
            let data = post.process(&raw, now);
            let guide = if is_vda(&id) { source[k] } else { &rgb[k] };
            let guide_size = if is_vda(&id) { source_size } else { size };
            let data = crate::refinement::process(&data, size, guide, guide_size, true);
            let end = Instant::now();
            assert_eq!(data.len(), size.0 * size.1);
            if i >= 8 {
                final_times.push((end - start).as_secs_f64() * 1000.);
                model_times.push((model_end - start).as_secs_f64() * 1000.);
                post_times.push((end - model_end).as_secs_f64() * 1000.);
            }
        }
        let result = json!({"model":id,"device":device,"description":engine.describe(),"width":size.0,"height":size.1,"load_ms":load_ms,
            "inference":stats(times),"tensorrt_graph":if graph_times.is_empty(){Value::Null}else{stats(graph_times)},
            "host_rgb_model_with_preparation":stats(model_times),"host_cpu_postprocess":stats(post_times),"host_rgb_final":stats(final_times)});
        eprintln!("BENCH RESULT {result}");
        results.push(result);
        std::fs::write(
            dir.join("results.json"),
            serde_json::to_vec_pretty(&results).unwrap(),
        )
        .unwrap();
    }
    assert_eq!(results.len(), expected);
    assert!(
        results.iter().all(|r| r.get("error").is_none()),
        "Some configurations failed; inspect results.json"
    );
}
