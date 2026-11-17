// tests/run.sh가 쓰는 Rust 쪽 테스트 하네스.
//   harness spec <cases.json> <out.json>   스펙 예제를 렌더링해 저장(비교는 tests/spec/spec.py)
//   harness bundle <path>                  TextBundle/TextPack을 열어 제목과 이미지 인라인 결과를 출력

use peekdown_core::{page_for_textbundle, render};
use regex_lite::Regex;
use std::path::Path;
use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("spec") if args.len() == 4 => spec(&args[2], &args[3]),
        Some("bundle") if args.len() == 3 => bundle(&args[2]),
        _ => {
            eprintln!("usage: harness spec <cases.json> <out.json> | bundle <path>");
            exit(2);
        }
    }
}

fn spec(cases_path: &str, out_path: &str) {
    let cases: Vec<serde_json::Value> = serde_json::from_slice(&std::fs::read(cases_path).unwrap()).unwrap();
    let rendered: Vec<String> = cases.iter().map(|c| render(c["markdown"].as_str().unwrap())).collect();
    std::fs::write(out_path, serde_json::to_vec(&rendered).unwrap()).unwrap();
}

fn bundle(path: &str) {
    let Some(html) = page_for_textbundle(Path::new(path)) else {
        println!("nil");
        return;
    };
    let title = Regex::new("<h1>([^<]*)</h1>").unwrap().captures(&html).map_or("-".to_string(), |c| c[1].to_string());
    let images: Vec<String> = Regex::new(r#"<img src="([^"]{0,20})[^"]*" alt="([^"]*)""#)
        .unwrap()
        .captures_iter(&html)
        .map(|c| format!("{}={}", &c[2], if c[1].starts_with("data:image/png") { "OK" } else { "FAIL" }))
        .collect();
    println!("title={title} images={}", images.join(","));
}
