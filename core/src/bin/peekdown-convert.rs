// Usage: peekdown-convert input.md [-o output.textpack | output.textbundle]
// 마크다운과 로컬 이미지를 TextBundle/TextPack으로 내보낸다. 자세한 규칙은 peekdown_core::convert 참고.

use std::path::Path;
use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        println!("Usage: peekdown-convert <input.md> [-o output.textpack | output.textbundle]");
        println!();
        println!("Packs a Markdown file and its local images into a TextBundle (http://textbundle.org).");
        println!("Writes a .textpack (zipped bundle) unless the output ends in .textbundle.");
        println!("If -o is not specified, writes <input name>.textpack next to the input.");
        println!("Remote images (http, https) are kept as links.");
        exit(1);
    }
    let output = (args.len() >= 4 && args[2] == "-o").then(|| Path::new(&args[3]));
    match peekdown_core::convert::convert(Path::new(&args[1]), output) {
        Ok(report) => {
            for path in report.skipped {
                eprintln!("Warning: Skipped image (not a readable local image file): {path}");
            }
            println!("Created: {}", report.output.display());
        }
        Err(message) => {
            eprintln!("Error: {message}");
            exit(1);
        }
    }
}
